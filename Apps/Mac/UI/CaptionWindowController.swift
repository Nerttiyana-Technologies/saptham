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
        // provide a non-activating panel that stays above full-screen apps.
        //
        // A titled panel with a hidden, transparent title bar (not a borderless
        // one): only titled windows get the system's resize edges, rounded
        // corners, and a draggable strip along the top.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 300),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 340, height: 170)

        // Real Liquid Glass is a window-level material: the caption view sits
        // inside the system glass view rather than drawing its own blur.
        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.contentView = DraggableHostingView(rootView: CaptionWindowView(controller: controller) { [weak self] in
            self?.hide()
        })
        panel.contentView = glass

        panel.setFrameAutosaveName("SapthamCaptionPanel")
        if !panel.setFrameUsingName("SapthamCaptionPanel"), let screen = NSScreen.main?.visibleFrame {
            // First launch: centred near the bottom of the screen, like subtitles.
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 80))
        }
        return panel
    }
}

/// SwiftUI's hosting view refuses window drags by default; captions are read,
/// not clicked, so dragging anywhere on them should move the window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
