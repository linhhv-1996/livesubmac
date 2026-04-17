import SwiftUI
import Combine
import CoreGraphics // Cần thiết để gọi hàm check quyền màn hình
import AppKit // Để gọi NSWorkspace mở Settings

@MainActor
final class UIState: ObservableObject {
    @Published var isRecording = false
    @Published var stableLines: [String] = []
    @Published var pendingText = ""
    @Published var isModelReady = false
    @Published var statusMessage = "Loading speech model..."
    
    @Published var hasScreenRecordPermission = false

    private let audioManager = AudioStreamManager()

    var displayText: String {
        (stableLines + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    init() {
        checkPermission() // Check quyền ngay khi khởi tạo
        
        Task {
            await audioManager.setCallbacks(
                onModelReady: { [weak self] in
                    guard let self else { return }
                    self.isModelReady = true
                    self.statusMessage = "Tap the panel to start transcription."
                },
                onStatusChanged: { [weak self] status in
                    guard let self else { return }
                    self.statusMessage = status
                },
                onSubtitleSnapshot: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.updateSubtitle(snapshot)
                    }
                }
            )
        }
        
        // Lắng nghe khi user từ System Settings quay lại app để check quyền lại
        Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in notifications {
                guard let self else { break }
                self.checkPermission()
                self.updateStatusBasedOnPermission()
            }
        }
    }
    
    
    // MARK: - Permission Logic
    func checkPermission() {
        // Hàm này không hiện popup, chỉ trả về true/false xem đã có quyền chưa
        hasScreenRecordPermission = CGPreflightScreenCaptureAccess()
    }
    
    func requestPermission() {
        // Hàm này sẽ trigger popup của macOS nếu chưa xin bao giờ
        let granted = CGRequestScreenCaptureAccess()
        hasScreenRecordPermission = granted
        
        if !granted {
            // Mở thẳng trang Cài đặt -> Quyền riêng tư -> Ghi màn hình
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            statusMessage = "Please allow Screen Recording in Settings."
        }
    }
    
    private func updateStatusBasedOnPermission() {
        guard isModelReady else { return }
        if hasScreenRecordPermission {
            statusMessage = "Tap the panel to start transcription."
        } else {
            statusMessage = "Missing Screen Recording permission."
        }
    }

    // MARK: - Actions
    private func updateSubtitle(_ snapshot: SubtitleSnapshot) {
        // TỐI ƯU HUỶ DIỆT "NHẢY CHỮ": 
        // Subtitle đã được bọc thành khối 2 dòng hoàn hảo bởi AudioStreamManager.
        // Chỉ cần snap dòng cập nhật không dùng animation.
        stableLines = snapshot.stableLines
        pendingText = snapshot.pendingText
    }

    func toggleRecording() {
        guard isModelReady else { return }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        statusMessage = "Starting capture..."

        Task {
            let didStart = await audioManager.startCapture()
            if !didStart {
                await MainActor.run {
                    self.isRecording = false
                    self.statusMessage = "Unable to start capture. Check screen recording permission."
                }
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        stableLines = []
        pendingText = ""
        statusMessage = "Tap the panel to start transcription."
        Task {
            await audioManager.stopCapture()
        }
    }
}

struct DynamicIslandView: View {
    @ObservedObject var uiState: UIState
    
    @State private var isSettingsMode = false
    @State private var isSettingsHovered = false
    @State private var isQuitHovered = false
    @State private var isActivateHovered = false
    
    @AppStorage("selectedLanguage") private var selectedLanguage = "en-US"
    @AppStorage("selectedModel") private var selectedModel = "turbo"
    @AppStorage("licenseKey") private var licenseKey = ""

    // Kích thước cố định để gióng hàng cột Setting bên dưới
    private let labelWidth: CGFloat = 90
    private let controlWidth: CGFloat = 240

    var body: some View {
        // VStack tổng: Tự động tính toán chiều cao dựa trên content bên trong
        VStack(spacing: 0) {
            
            // 1. PHẦN SUBTITLE CHÍNH (Luôn hiển thị)
            mainSubtitleContent
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isSettingsMode { uiState.toggleRecording() }
                }
            
            // 2. PHẦN SETTING (Nở ra khi click vào nút Gear)
            if isSettingsMode {
                Divider()
                    .background(.white.opacity(0.15))
                    .padding(.horizontal, 20)
                
                settingsContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    // Hiệu ứng trượt từ trên xuống khi bung ra
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Background và Viền áp dụng cho TOÀN BỘ VStack tổng
        .background(
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.1, blue: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 6)
        // Animation sẽ làm panel co giãn mượt mà khi isSettingsMode thay đổi
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSettingsMode)
        // Đặt max size thay vì fix cứng frame, đẩy view lên trên cùng của NSPanel
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // --- MAIN SUBTITLE VIEW ---
    private var mainSubtitleContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statusIndicator
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiState.isRecording ? "LIVE SUBTITLE" : "READY")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(uiState.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Nút Gear giờ sẽ đóng/mở panel thay vì chuyển cảnh
                CircleButton(icon: isSettingsMode ? "chevron.up" : "gearshape.fill", isHovered: $isSettingsHovered) {
                    isSettingsMode.toggle()
                }
                
                CircleButton(icon: "xmark", isHovered: $isQuitHovered, activeColor: .red.opacity(0.7)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            
            // Khối hiển thị chữ (Fix minHeight để nó không bị lép khi không có chữ)
            if uiState.displayText.isEmpty {
                
                if !uiState.hasScreenRecordPermission {
                    // Cảnh báo nổi bật nếu thiếu quyền
                    Text("Grant Permission to Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                } else {
                    Text(uiState.isRecording ? "Listening..." : "Tap to start")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                }
            } else {
                Text(uiState.displayText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading) // ÉP GÓC TRÊN BÊN TRÁI
            }
        }
    }

    // --- BẢN CHỐT: TỰ CODE VỎ 100%, KHÔNG DÙNG MẶC ĐỊNH ---
    private var settingsContent: some View {
        VStack(spacing: 12) {
            
            // Hàng 1: Language
            settingsRow(label: "Language") {
                CustomDropdown(text: LanguageOption.available.first(where: { $0.id == selectedLanguage })?.name ?? "Select") {
                    ForEach(LanguageOption.available) { lang in
                        Button(lang.name) { selectedLanguage = lang.id }
                    }
                }
            }

            // Hàng 2: Model
            settingsRow(label: "Model") {
                CustomDropdown(text: selectedModel.capitalized) {
                    Button("Tiny") { selectedModel = "tiny" }
                    Button("Small") { selectedModel = "small" }
                    Button("Medium") { selectedModel = "medium" }
                    Button("Turbo") { selectedModel = "turbo" }
                }
            }

            // Hàng 3: License
            settingsRow(label: "License") {
                HStack(spacing: 6) {
                    // Nửa 1: Input Field
                    TextField("Enter key...", text: $licenseKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30) // Fixed height 30
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                    
                    // Nửa 2: Button
                    Button {
                        print("Activating: \(licenseKey)")
                    } label: {
                        Text("Activate")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(isActivateHovered ? Color.blue : Color.blue.opacity(0.8))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 75, height: 30) // Fixed height 30
                    .onHover { isActivateHovered = $0 }
                }
            }
        }
    }

    // --- COMPONENT TỰ CODE (BẢN CHUẨN MƯỢT MÀ) ---
    @ViewBuilder
    private func CustomDropdown<Content: View>(text: String, @ViewBuilder items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            HStack {
                Text(text)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Spacer(minLength: 0)
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            // BÍ QUYẾT 1: Kích hoạt click cho toàn bộ khối (kể cả chỗ trống của Spacer)
            .contentShape(Rectangle())
            .background(Color.white.opacity(0.08))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        // BÍ QUYẾT 2: Ép Menu dùng style "Plain" để diệt gọn cái mũi tên "v" mặc định của macOS
        .buttonStyle(.plain)
    }

    // --- HELPER VIEWS CẬP NHẬT ---
    // 1. Dàn lề Label và Content
    @ViewBuilder
    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 70, alignment: .leading) // Label fix cứng 70px
            
            content()
                .frame(maxWidth: .infinity) // Content bên phải tự giãn hết cỡ để bằng mép nhau
        }
    }
    
    // 2. Cái "Hộp" thần thánh để đồng bộ mọi UI
    @ViewBuilder
    private func CustomControlBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 30) // CHIỀU CAO CỐ ĐỊNH 30PX CHUẨN MỰC
        .background(Color.white.opacity(0.08)) // Màu nền xám mờ
        .cornerRadius(6)
        .overlay( // Thêm cái viền mỏng 0.5px tạo cảm giác nổi khối 3D nhẹ
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
    
    // --- NÚT BẤM DÙNG CHUNG ---
    @ViewBuilder
    private func CircleButton(icon: String, isHovered: Binding<Bool>, activeColor: Color = .white.opacity(0.15), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered.wrappedValue ? .white : .white.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(isHovered.wrappedValue ? activeColor : Color.white.opacity(0.05))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered.wrappedValue = $0 }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(uiState.isRecording ? Color.red : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}
