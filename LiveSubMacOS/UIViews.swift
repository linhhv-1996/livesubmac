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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(uiState.isRecording ? Color.red : Color.gray.opacity(0.6))
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .stroke(uiState.isRecording ? Color.red.opacity(0.35) : .clear, lineWidth: 8)
                                .scaleEffect(uiState.isRecording ? 1.15 : 1.0)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: uiState.isRecording)
                        }

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

                    Button {
                        openWindow(id: "main-settings")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                subtitleBlock
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(minHeight: 100, maxHeight: .infinity, alignment: .top)
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
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                uiState.toggleRecording()
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var subtitleBlock: some View {
        VStack(spacing: 8) {
            if uiState.displayText.isEmpty {
                Text(uiState.isRecording ? "Listening for system audio..." : "Tap anywhere here to start.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text(uiState.displayText)
                    .font(.system(size: 18, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1.5, x: 1, y: 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .contentTransition(.identity) 
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(minHeight: 64, alignment: .bottomLeading)
    }
}
