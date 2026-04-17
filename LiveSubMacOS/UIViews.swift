import SwiftUI
import Combine

@MainActor
final class UIState: ObservableObject {
    @Published var isRecording = false
    @Published var stableLines: [String] = []
    @Published var pendingText = ""
    @Published var isModelReady = false
    @Published var statusMessage = "Loading speech model..."

    private let audioManager = AudioStreamManager()

    var displayText: String {
        (stableLines + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    init() {
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
    }

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
                Text(uiState.isRecording ? "Listening..." : "Tap to start")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center) // ÉP CĂN GIỮA
            } else {
                Text(uiState.displayText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading) // ÉP GÓC TRÊN BÊN TRÁI
            }
        }
    }

    // --- EXPANDED SETTINGS VIEW ---
    private var settingsContent: some View {
        VStack(spacing: 14) {
            // Hàng 1: Language
            settingsRow(label: "Language") {
                Picker("", selection: $selectedLanguage) {
                    ForEach(LanguageOption.available) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Hàng 2: Model
            settingsRow(label: "Model") {
                Picker("", selection: $selectedModel) {
                    Text("Tiny").tag("tiny")
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Turbo").tag("turbo")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Hàng 3: License (Cân đối hoàn hảo với Picker)
            settingsRow(label: "License") {
                HStack(spacing: 8) {
                    TextField("Enter key...", text: $licenseKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                    
                    Button {
                        print("Activating: \(licenseKey)")
                    } label: {
                        Text("Activate")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isActivateHovered ? Color.blue : Color.blue.opacity(0.7))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .onHover { isActivateHovered = $0 }
                }
            }
        }
    }

    // --- HELPER VIEW: ÉP LAYOUT CHUẨN MỰC ---
    @ViewBuilder
    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: labelWidth, alignment: .leading) // Label luôn cố định 90
            
            Spacer(minLength: 0)
            
            content()
                .frame(width: controlWidth) // Control luôn cố định 240
        }
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
