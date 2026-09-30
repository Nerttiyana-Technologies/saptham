import AppKit
import SapthamCore
import SwiftUI

@main
@MainActor
struct SapthamMacApp: App {
    @State private var controller: any CaptionControlling
    @State private var captionWindow = CaptionWindowController()
    @AppStorage("captionWindowVisible") private var captionWindowVisible = false

    init() {
        let previewMode = ProcessInfo.processInfo.arguments.contains("--preview-captions")
        let engine: any CaptionControlling = previewMode
            ? PreviewCaptionController()
            : MacCaptionEngine.makeController()
        let panel = CaptionWindowController()
        _controller = State(initialValue: engine)
        _captionWindow = State(initialValue: panel)

        if previewMode, let firstSource = engine.sources.first {
            engine.start(firstSource.id)
            UserDefaults.standard.set(true, forKey: "captionWindowVisible")
        }

        // Diagnostics: `--start <source id>` begins captioning at launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--start"), index + 1 < arguments.count {
            engine.start(arguments[index + 1])
        }

        if UserDefaults.standard.bool(forKey: "captionWindowVisible") {
            Task { @MainActor in
                await Task.yield()
                panel.show(controller: engine)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Saptham", systemImage: menuBarSymbol) {
            MenuBarPanel(
                controller: controller,
                captionWindow: captionWindow,
                isCaptionWindowVisible: $captionWindowVisible
            )
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch controller.feed.state {
        case .failed:
            "exclamationmark.bubble.fill"
        case .listening:
            "captions.bubble.fill"
        case .idle, .preparing:
            "captions.bubble"
        }
    }
}
