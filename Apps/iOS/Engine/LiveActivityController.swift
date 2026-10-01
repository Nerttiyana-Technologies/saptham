import ActivityKit
import Foundation
import SapthamCore

/// Keeps a Live Activity in step with captioning: started when captions
/// start (if the user allows it, see PhoneSettings.liveActivity), updated
/// at most once a second when the words change, ended when they stop.
/// Knows only the caption feed and the alerts; the widget extension draws
/// whatever CaptionActivityAttributes it is sent.
@MainActor
final class LiveActivityController {
    private let captions: any CaptionControlling
    private let alerts: PhoneAlerts
    private var activity: Activity<CaptionActivityAttributes>?
    private var lastState: CaptionActivityAttributes.ContentState?
    private var loop: Task<Void, Never>?

    /// An alert stays on the Lock Screen this long.
    private let alertShownFor: TimeInterval = 12

    init(captions: any CaptionControlling, alerts: PhoneAlerts) {
        self.captions = captions
        self.alerts = alerts
    }

    func start() {
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func step() async {
        let wanted = captions.activeSourceID != nil && PhoneSettings.liveActivityValue
            && ActivityAuthorizationInfo().areActivitiesEnabled
        guard wanted else {
            await end()
            return
        }
        let state = currentState()
        if let activity {
            guard state != lastState else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
            do {
                activity = try Activity.request(attributes: CaptionActivityAttributes(startedAt: Date()),
                                                content: ActivityContent(state: state, staleDate: nil))
            } catch {
                Diagnostics.engine.error("live activity could not start: \(String(describing: error), privacy: .public)")
                return
            }
        }
        lastState = state
    }

    private func end() async {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func currentState() -> CaptionActivityAttributes.ContentState {
        let feed = captions.feed
        let line = feed.lines.last
        let alert = alerts.recent.first.flatMap { Date().timeIntervalSince($0.time) < alertShownFor ? $0 : nil }
        return CaptionActivityAttributes.ContentState(
            line: line?.text ?? "",
            partial: feed.partial,
            tone: (line?.tone ?? .normal).rawValue,
            languageID: captions.activeLanguageID,
            alertTitle: alert?.kind.title,
            alertSymbol: alert?.kind.systemImage,
            // Coarse, so a changing meter alone does not use up updates.
            level: (Double(feed.level) * 4).rounded() / 4)
    }
}
