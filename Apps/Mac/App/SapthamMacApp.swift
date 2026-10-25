import AppKit
import SapthamCore
import SwiftUI

@main
@MainActor
struct SapthamMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: SapthamAppDelegate
    @State private var services: MacAppServices
    @State private var captionWindow = CaptionWindowController()
    @State private var navigation: TranscriptNavigation
    @State private var soundAlerts: SoundAlertListener
    @State private var alertPresenter: SoundAlertPresenter
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
        let navigation = TranscriptNavigation(voiceNotes: services.voiceNotes)
        _navigation = State(initialValue: navigation)
        let alertPresenter = SoundAlertPresenter()
        let soundAlerts = SoundAlertListener(present: alertPresenter.present)
        _alertPresenter = State(initialValue: alertPresenter)
        _soundAlerts = State(initialValue: soundAlerts)
        appDelegate.navigation = navigation
        services.nameAlerts.onAlert = alertPresenter.present
        // Demo mode never opens the microphone.
        if !previewMode { soundAlerts.start() }
        services.nameListener?.start()

        if previewMode, let firstSource = engine.sources.first {
            engine.start(firstSource.id)
            UserDefaults.standard.set(true, forKey: "captionWindowVisible")
        }

        // Diagnostics: `--language <id>` switches the caption language and
        // `--start <source id>` begins captioning at launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count {
            engine.setLanguage(arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--start"), index + 1 < arguments.count {
            engine.start(arguments[index + 1])
        }

        #if DEBUG
        DebugSnapshots.scheduleIfRequested(extraViews: [
            ("Transcripts", CGSize(width: 1000, height: 640),
             AnyView(TranscriptsWindow(transcripts: services.transcripts, corrections: services.corrections,
                                       navigation: navigation))),
            ("Corrections", CGSize(width: 700, height: 420), AnyView(CorrectionsView(corrections: services.corrections))),
            ("SoundAlert", CGSize(width: 1280, height: 800),
             AnyView(SoundAlertOverlay(alert: SoundAlert(kind: SoundAlertKind.all[0], confidence: 1)))),
            ("Settings", CGSize(width: 560, height: 900),
             AnyView(SapthamSettingsView(transcripts: services.transcripts, soundAlerts: soundAlerts))),
            ("MenuBarPanel", CGSize(width: 360, height: 760),
             AnyView(MenuBarPanel(controller: services.captions, captionWindow: panel, navigation: navigation,
                                  isCaptionWindowVisible: .constant(true)))),
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
                navigation: navigation,
                isCaptionWindowVisible: $captionWindowVisible
            )
        }
        .menuBarExtraStyle(.window)

        Window("Transcripts", id: "transcripts") {
            TranscriptsWindow(transcripts: services.transcripts, corrections: services.corrections,
                              navigation: navigation)
                #if DEBUG
                .background(DemoSettingsOpener())
                #endif
        }
        .defaultSize(width: 960, height: 680)
        // Coupled to SapthamAppDelegate by this URL: opening it is the only
        // way AppKit code can bring a SwiftUI Window scene up. Matching
        // anything wider (e.g. "*") makes SwiftUI hand this window the first
        // sound file of a batch and the delegate only the rest.
        .handlesExternalEvents(matching: [SapthamAppDelegate.showTranscriptsURL.absoluteString])
        // Demo mode opens the review window at launch for screenshots.
        .defaultLaunchBehavior(Self.isPreviewMode ? .presented : .suppressed)
        .commands { TranscriptCommands() }

        Window("Corrections", id: "corrections") {
            CorrectionsView(corrections: services.corrections)
        }
        .defaultSize(width: 700, height: 480)
        // A scene with no rule takes any URL the app is sent, so without
        // this saptham://transcripts would open Corrections as well.
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(Self.isPreviewMode ? .presented : .suppressed)

        Settings {
            SapthamSettingsView(transcripts: services.transcripts, soundAlerts: soundAlerts,
                                nameListener: services.nameListener,
                                alertsTurnedOn: alertPresenter.requestNotificationPermission)
        }
    }

    private var menuBarSymbol: String {
        if controller.feed.isAudioStalled { return "mic.slash" }
        return switch controller.feed.state {
        case .failed:
            "exclamationmark.bubble.fill"
        case .listening:
            "captions.bubble.fill"
        case .idle, .preparing:
            "captions.bubble"
        }
    }
}

/// Receives sound files opened with Saptham (Finder's Open With, or files
/// dropped on the app icon), all of them in one call.
@MainActor
final class SapthamAppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the Transcripts window. Coupled by agreement to that scene's
    /// `handlesExternalEvents` in SapthamMacApp and to CFBundleURLTypes in
    /// Info.plist; change all three together or files are transcribed
    /// with no window shown.
    static let showTranscriptsURL = URL(string: "saptham://transcripts")!

    var navigation: TranscriptNavigation?

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard let navigation, !files.isEmpty else { return }
        Diagnostics.engine.info("opened with Saptham: \(files.count, privacy: .public) files")
        for file in files { navigation.openVoiceNote(file) }
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(Self.showTranscriptsURL)
    }
}
