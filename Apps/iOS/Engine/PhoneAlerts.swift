import Foundation
import Observation
import SapthamCore
import UIKit
import UserNotifications

/// Sound alerts and name alerts on iPhone: listens for the sounds chosen in
/// Settings, and shows every alert — on screen with a strong vibration when
/// Saptham is open, as a notification when it is not.
///
/// Follows the settings by itself: turning alerts or a sound on or off
/// takes effect at once. Listens through the shared microphone, so it runs
/// alongside captions rather than competing with them.
@MainActor
@Observable
final class PhoneAlerts {
    /// The alert on screen now, until dismissed.
    private(set) var current: SoundAlert?
    /// Newest first; the last 20.
    private(set) var recent: [SoundAlert] = []
    private(set) var isListening = false
    /// Why listening could not start (usually microphone permission).
    private(set) var problem: String?

    @ObservationIgnored private let microphone: SharedMicrophone
    @ObservationIgnored private var running: (source: AudioSource, task: Task<Void, Never>, kinds: Set<String>)?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(microphone: SharedMicrophone) {
        self.microphone = microphone
    }

    func start() {
        follow()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    /// Shows an alert: on screen and felt when Saptham is open, otherwise
    /// as a notification (which vibrates and lights the screen).
    func present(_ alert: SoundAlert) {
        recent.insert(alert, at: 0)
        if recent.count > 20 { recent.removeLast() }
        if UIApplication.shared.applicationState == .active {
            current = alert
            Self.vibrate()
        } else {
            Self.notify(alert)
        }
    }

    func dismiss() {
        current = nil
    }

    /// Shows an alert without any sound, so the user can see and feel one.
    func showTest() {
        guard let kind = SoundAlertKind.all.first else { return }
        present(SoundAlert(kind: kind, confidence: 1))
    }

    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// Three firm taps: unmistakable in a pocket, unlike a notification's one.
    private static func vibrate() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        Task { @MainActor in
            for _ in 0..<3 {
                generator.notificationOccurred(.warning)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private static func notify(_ alert: SoundAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.kind.title
        content.body = "Heard \(alert.time.formatted(date: .omitted, time: .shortened))"
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Starts, stops or restarts listening to match the settings. Called on
    /// every settings change (any key), so it does nothing when ours did not change.
    private func follow() {
        let wanted = SapthamSettings.soundAlertsValue ? SapthamSettings.soundAlertKindsValue : []
        guard wanted != running?.kinds ?? [] else { return }
        stopListening()
        guard !wanted.isEmpty else { return }

        let kinds = SoundAlertKind.all.filter { wanted.contains($0.id) }
        let source = microphone.makeSource()
        let task = Task { @MainActor [weak self] in
            do {
                let audio = try await source.start()
                Diagnostics.engine.info("sound alerts: listening for \(kinds.map(\.id).joined(separator: ","), privacy: .public)")
                self?.isListening = true
                self?.problem = nil
                for await alert in SoundAlertDetector(kinds: kinds).alerts(in: audio) {
                    self?.present(alert)
                }
            } catch {
                Diagnostics.engine.error("sound alerts could not start: \(String(describing: error), privacy: .public)")
                self?.problem = error.localizedDescription
            }
            self?.isListening = false
        }
        running = (source, task, wanted)
    }

    private func stopListening() {
        guard let running else { return }
        self.running = nil
        running.source.stop()
        running.task.cancel()
        isListening = false
    }
}
