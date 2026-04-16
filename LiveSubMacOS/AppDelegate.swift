import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandPanel: DynamicIslandPanel?
    private let uiState = UIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupIsland()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupIsland() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 156
        let initialRect = NSRect(
            x: screen.visibleFrame.midX - (windowWidth / 2),
            y: screen.visibleFrame.maxY - windowHeight - 8,
            width: windowWidth,
            height: windowHeight
        )

        let panel = DynamicIslandPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DynamicIslandView(uiState: uiState))
        panel.orderFrontRegardless()

        islandPanel = panel
    }
}

final class DynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

