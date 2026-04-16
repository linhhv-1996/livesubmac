import SwiftUI
import ScreenCaptureKit

@main
struct LiveSubMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("App Settings", id: "main-settings") {
            SettingsView()
        }
        .defaultSize(width: 460, height: 400)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("licenseKey") private var licenseKey = ""
    @AppStorage("selectedLanguage") private var selectedLanguage = "en-US"
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    private let languages: [LanguageOption] = LanguageOption.available

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MacSub Settings")
                    .font(.title2.weight(.semibold))
                Text("Configure access, license, and subtitle language.")
                    .foregroundStyle(.secondary)
            }

            permissionSection

            Form {
                Section("License") {
                    TextField("License Key", text: $licenseKey, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                        .textFieldStyle(.roundedBorder)

                    Text("System audio transcription stays disabled until screen recording access is granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Subtitle Language") {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(languages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)

            Spacer()

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .tint(.red)

                Spacer()

                Button("Refresh Permission") {
                    refreshPermission()
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 400)
        .onAppear {
            refreshPermission()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(hasPermission ? "Screen Recording access granted" : "Screen Recording access required")
            } icon: {
                Image(systemName: hasPermission ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasPermission ? .green : .orange)
            }

            Text("macOS requires Screen Recording permission for system audio capture through ScreenCaptureKit.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !hasPermission {
                HStack {
                    Button("Grant Access") {
                        CGRequestScreenCaptureAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func refreshPermission() {
        hasPermission = CGPreflightScreenCaptureAccess()
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String

    static let available: [LanguageOption] = {
        let preferredIdentifiers = [
            "en-US", "en-GB", "vi-VN", "ja-JP", "ko-KR", "zh-Hans", "zh-Hant",
            "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"
        ]

        let options = preferredIdentifiers.compactMap { identifier -> LanguageOption? in
            let locale = Locale(identifier: identifier)
            guard let name = Locale.current.localizedString(forIdentifier: identifier) else { return nil }
            return LanguageOption(id: locale.identifier, name: name.capitalized)
        }

        return options.sorted { $0.name < $1.name }
    }()
}

