import AppKit
import SapthamCore
import SwiftUI

@main
@MainActor
struct SapthamMacApp: App {
    @State private var services: MacAppServices
    @State private var captionWindow = CaptionWindowController()
    @State private var autoCalls: AutoCallCaptioner?
    @AppStorage("captionWindowVisible") private var captionWindowVisible = false

    private var controller: any CaptionControlling { services.captions }

    private static let isPreviewMode = ProcessInfo.processInfo.arguments.contains("--preview-captions")

    init() {
        let previewMode = Self.isPreviewMode
        let services = previewMode ? MacCaptionEngine.makePreviewServices() : MacCaptionEngine.makeServices()
        let engine = services.captions
        let panel = CaptionWindowController()
        _services = State(initialValue: services)
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

        #if DEBUG
        DebugSnapshots.scheduleIfRequested(extraViews: [
            ("Transcripts", CGSize(width: 1000, height: 640),
             AnyView(TranscriptReviewView(transcripts: services.transcripts, corrections: services.corrections))),
            ("Corrections", CGSize(width: 700, height: 420), AnyView(CorrectionsView(corrections: services.corrections))),
            ("Settings", CGSize(width: 560, height: 360), AnyView(SapthamSettingsView(transcripts: services.transcripts))),
            ("MenuBarPanel", CGSize(width: 360, height: 760),
             AnyView(MenuBarPanel(controller: services.captions, captionWindow: panel, isCaptionWindowVisible: .constant(true)))),
        ])
        #endif

        if !previewMode {
            let autoCalls = AutoCallCaptioner(captions: engine, window: panel,
                                              callSourceID: MacCaptionEngine.SourceID.calls)
            autoCalls.start()
            _autoCalls = State(initialValue: autoCalls)
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

        Window("Transcripts", id: "transcripts") {
            TranscriptReviewView(transcripts: services.transcripts, corrections: services.corrections)
                #if DEBUG
                .background(DemoSettingsOpener())
                #endif
        }
        .defaultSize(width: 960, height: 680)
        // Demo mode opens the review window at launch for screenshots.
        .defaultLaunchBehavior(Self.isPreviewMode ? .presented : .suppressed)
        .commands { TranscriptCommands() }

        Window("Corrections", id: "corrections") {
            CorrectionsView(corrections: services.corrections)
        }
        .defaultSize(width: 700, height: 480)
        .defaultLaunchBehavior(Self.isPreviewMode ? .presented : .suppressed)

        Settings {
            SapthamSettingsView(transcripts: services.transcripts)
        }
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
