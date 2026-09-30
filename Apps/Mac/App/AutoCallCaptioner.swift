import Foundation
import SapthamCore

/// Keeps Saptham ready for calls answered on this Mac, so the user never has
/// to pick "Phone calls" by hand:
/// - whenever nothing is being captioned, it arms the call source (which
///   receives audio only while a call is actually playing);
/// - when call audio starts it brings up the caption window;
/// - 30 s after call audio stops it hides the window again, but only if it
///   was the one that showed it.
///
/// Works purely through CaptionControlling and the caption window; the
/// engine does not know it exists.
@MainActor
final class AutoCallCaptioner {
    private let captions: any CaptionControlling
    private let window: CaptionWindowController
    private let callSourceID: String
    private var timer: Timer?
    private var shownAutomatically = false
    private var lastCallAudioAt: Date?
    private var lastArmAttemptAt: Date?
    /// Recording is decided when the call source starts; remember the value
    /// it started with so a change can be picked up between calls.
    private var armedWithRecording: Bool?

    private static let hideAfter: TimeInterval = 30
    /// After a failure (e.g. permission denied), retry this rarely instead of
    /// hammering the audio system twice a second.
    private static let retryAfterFailure: TimeInterval = 60
    private static let windowVisibleKey = "captionWindowVisible"

    init(captions: any CaptionControlling, window: CaptionWindowController, callSourceID: String) {
        self.captions = captions
        self.window = window
        self.callSourceID = callSourceID
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard SapthamSettings.autoCaptionCallsValue else { return }
        guard let active = captions.activeSourceID else {
            arm()
            return
        }
        guard active == callSourceID else { return }

        // The "Record phone calls" setting changed: re-arm between calls so
        // the next call uses it. Never restarts during a call.
        if let armed = armedWithRecording, armed != SapthamSettings.recordCallsValue,
           !captions.feed.isReceivingAudio {
            captions.stop()
            arm()
            return
        }

        let defaults = UserDefaults.standard
        if captions.feed.isReceivingAudio {
            lastCallAudioAt = Date()
            if !defaults.bool(forKey: Self.windowVisibleKey) {
                window.show(controller: captions)
                defaults.set(true, forKey: Self.windowVisibleKey)
                shownAutomatically = true
                Diagnostics.engine.info("call audio started; caption window shown")
            }
        } else if shownAutomatically, let last = lastCallAudioAt,
                  Date().timeIntervalSince(last) > Self.hideAfter {
            window.hide()
            defaults.set(false, forKey: Self.windowVisibleKey)
            shownAutomatically = false
            Diagnostics.engine.info("call audio ended; caption window hidden")
        }
    }

    private func arm() {
        if case .failed = captions.feed.state,
           let last = lastArmAttemptAt, Date().timeIntervalSince(last) < Self.retryAfterFailure {
            return
        }
        lastArmAttemptAt = Date()
        armedWithRecording = SapthamSettings.recordCallsValue
        captions.start(callSourceID)
    }
}
