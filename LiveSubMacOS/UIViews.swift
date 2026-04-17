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
    
    // Quản lý trạng thái giao diện
    @State private var isSettingsMode = false
    @State private var isSettingsHovered = false
    @State private var isQuitHovered = false
    
    // Đọc trực tiếp ngôn ngữ từ AppStorage để cập nhật realtime
    @AppStorage("selectedLanguage") private var selectedLanguage = "en-US"
    @AppStorage("licenseKey") private var licenseKey = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isSettingsMode {
                    settingsContent
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    mainSubtitleContent
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.08, blue: 0.1),
                        Color.black.opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Khi tap vào vùng trống, nếu đang recording thì toggle, nếu đang settings thì không làm gì hoặc đóng settings
        .onTapGesture {
            if !isSettingsMode {
                uiState.toggleRecording()
            }
        }
    }

    // --- KHỐI GIAO DIỆN CHÍNH (Subtitle) ---
    private var mainSubtitleContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                // Đèn báo hiệu Live
                statusIndicator
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiState.isRecording ? "LIVE SUBTITLE" : "READY")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(uiState.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                // Nút Gear: Chuyển sang Settings mode
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isSettingsMode = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSettingsHovered ? .white : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(isSettingsHovered ? .white.opacity(0.2) : .white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .onHover { isSettingsHovered = $0 }
                
                // Nút X: Thoát app nhanh
                exitButton
            }

            subtitleBlock
        }
    }

    // --- KHỐI GIAO DIỆN CÀI ĐẶT (Settings) ---
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                
                Spacer()
                
                // Nút Done: Quay lại màn hình chính
                Button("Done") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isSettingsMode = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
            }
            
            Divider().background(.white.opacity(0.1))
            
            VStack(spacing: 10) {
                // Chọn ngôn ngữ
                HStack {
                    Text("Language")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Picker("", selection: $selectedLanguage) {
                        ForEach(LanguageOption.available) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                
                // License Key (Nhập trực tiếp)
                HStack {
                    Text("License")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    TextField("XXXX-XXXX", text: $licenseKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: 150)
                }
            }
            
            Spacer(minLength: 0)
            
            Text("Model: Whisper Large-v3 Turbo")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
    
    // MARK: - Sub-Components
    
    private var statusIndicator: some View {
        Circle()
            .fill(uiState.isRecording ? Color.red : Color.gray.opacity(0.6))
            .frame(width: 10, height: 10)
            .overlay {
                if uiState.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 8)
                        .scaleEffect(1.15)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: uiState.isRecording)
                }
            }
    }
    
    private var exitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isQuitHovered ? .white : .white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(isQuitHovered ? Color.red.opacity(0.8) : .white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { isQuitHovered = $0 }
    }

    private var subtitleBlock: some View {
        VStack(spacing: 8) {
            if uiState.displayText.isEmpty {
                Text(uiState.isRecording ? "Listening for system audio..." : "Tap to start transcribing")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text(uiState.displayText)
                    .font(.system(size: 18, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1.5, x: 1, y: 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 64, alignment: .bottomLeading)
    }
}

