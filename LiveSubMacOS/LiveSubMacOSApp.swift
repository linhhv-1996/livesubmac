import SwiftUI
import ScreenCaptureKit

@main
struct LiveSubMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
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

