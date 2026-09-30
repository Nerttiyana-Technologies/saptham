import AppKit
import SapthamCore
import SwiftUI

/// Owns the non-activating floating panel used for captions.
@MainActor
final class CaptionWindowController {
    private var panel: NSPanel?

    func show(controller: any CaptionControlling) {
        let captionPanel = panel ?? makePanel(controller: controller)
        panel = captionPanel
        captionPanel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: any CaptionControlling) -> NSPanel {
        // AppKit is needed here because SwiftUI windows activate the app and cannot
        // provide a borderless, non-activating panel that stays above full-screen apps.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 300),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.setFrameAutosaveName("SapthamCaptionPanel")
        if !panel.setFrameUsingName("SapthamCaptionPanel"), let screen = NSScreen.main?.visibleFrame {
            // First launch: centred near the bottom of the screen, like subtitles.
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 80))
        }
        panel.contentView = NSHostingView(rootView: CaptionWindowView(controller: controller) { [weak self] in
            self?.hide()
        })
        return panel
    }
}
