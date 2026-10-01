import SapthamCore
import SwiftUI
import UIKit

@main
@MainActor
struct SapthamPhoneApp: App {
    @State private var services: PhoneAppServices
    @State private var liveActivity: LiveActivityController

    /// `--preview-captions`: scripted captions and sample transcripts, no
    /// microphone or real data (screenshots, demos).
    private static let isPreviewMode = ProcessInfo.processInfo.arguments.contains("--preview-captions")

    init() {
        let services = Self.isPreviewMode ? PhoneCaptionEngine.makePreviewServices() : PhoneCaptionEngine.makeServices()
        _services = State(initialValue: services)
        let liveActivity = LiveActivityController(captions: services.captions, alerts: services.alerts)
        _liveActivity = State(initialValue: liveActivity)
        if !Self.isPreviewMode {
            services.alerts.start()
            services.direction.start()
            liveActivity.start()
        }
        // Diagnostics: `--start` begins captioning at launch.
        if ProcessInfo.processInfo.arguments.contains("--start"), let source = services.captions.sources.first {
            services.captions.start(source.id)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .preferredColorScheme(.dark)
        }
    }
}

/// The two places the app can be — live, or earlier conversations — with
/// the reading band as the anchor between them. No tabs: the band's chips
/// move between them, and alerts cover both.
struct RootView: View {
    let services: PhoneAppServices

    private enum Screen { case live, earlier }

    @State private var screen = Screen.live
    @State private var showsSettings = false
    /// Posture is the main control: raised to read, flat to share, face
    /// down to stop captions while sound alerts stay on.
    @State private var posture = PostureWatcher()
    @State private var faceDown: (since: Date, wasCaptioning: Bool)?
    @State private var missed: [SoundAlert] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceNoteProblem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            MonsoonBackdrop()
            current
            if let alert = services.alerts.current {
                alertView(alert)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .foregroundStyle(Monsoon.ink)
        .animation(.easeInOut(duration: 0.25), value: services.alerts.current?.id)
        .sheet(isPresented: $showsSettings) {
            SettingsPanel(services: services)
                .presentationBackground(.clear)
        }
        .animation(.easeInOut(duration: 0.4), value: posture.posture)
        .onChange(of: posture.posture) { old, new in postureChanged(from: old, to: new) }
        // Motion is only watched while Saptham is on screen.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { posture.start() } else { posture.stop() }
        }
        // Captions are read, not glanced at: keep the screen on while listening.
        .onChange(of: services.captions.activeSourceID) { old, active in
            UIApplication.shared.isIdleTimerDisabled = active != nil
            if old == nil, active != nil { services.battery.captioningStarted() }
            if old != nil, active == nil { services.battery.captioningStopped() }
        }
        // A sound file shared to Saptham (a chat app's voice message).
        .onOpenURL { url in
            guard url.isFileURL else { return }
            do {
                try services.voiceNotes.transcribe(url)
                go(.earlier)
            } catch {
                voiceNoteProblem = error.localizedDescription
            }
        }
        .alert("Could not open that file", isPresented: Binding(get: { voiceNoteProblem != nil },
                                                               set: { if !$0 { voiceNoteProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voiceNoteProblem ?? "")
        }
    }

    /// What fills the screen, by priority: what was missed while face down,
    /// the shared view while flat, otherwise the chosen screen.
    private enum Shown { case missed, shared, live, earlier }

    private var shown: Shown {
        if screen == .earlier { return .earlier }
        if !missed.isEmpty { return .missed }
        if posture.posture == .flat && services.captions.activeSourceID != nil { return .shared }
        return .live
    }

    @ViewBuilder
    private var current: some View {
        switch shown {
        case .missed:
            MissedView(alerts: missed, onDone: { withAnimation { missed = [] } })
                .transition(.opacity)
        case .shared:
            SharedFlatView(captions: services.captions)
                .transition(.opacity)
        case .live:
            LiveBandView(captions: services.captions,
                         direction: services.direction,
                         onEarlier: { go(.earlier) },
                         onSettings: { showsSettings = true })
                .transition(.move(edge: .top).combined(with: .opacity))
        case .earlier:
            ReplayView(services: services,
                       onBack: { go(.live) },
                       onOpenSettings: { showsSettings = true })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func alertView(_ alert: SoundAlert) -> some View {
        AlertBandView(alert: alert,
                      heardLine: services.captions.feed.lines.last?.text,
                      onDismiss: { services.alerts.dismiss() },
                      onShow: showCaptionsAfterAlert)
    }

    private func showCaptionsAfterAlert() {
        services.alerts.dismiss()
        go(.live)
        if services.captions.activeSourceID == nil, let source = services.captions.sources.first {
            services.captions.start(source.id)
        }
    }

    private func postureChanged(from old: Posture, to new: Posture) {
        let captions = services.captions
        if new == .faceDown {
            faceDown = (Date(), captions.activeSourceID != nil)
            captions.stop()
        } else if old == .faceDown, let put = faceDown {
            faceDown = nil
            missed = services.alerts.recent.filter { $0.time >= put.since }
            if put.wasCaptioning, let source = captions.sources.first { captions.start(source.id) }
        }
    }

    private func go(_ next: Screen) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.88)) {
            screen = next
        }
    }
}
