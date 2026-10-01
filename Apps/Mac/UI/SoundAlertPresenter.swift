import AppKit
import SapthamCore
import SwiftUI
import UserNotifications

/// Shows a sound alert so it cannot be missed: a glowing frame and a large
/// card on every screen, over full-screen apps too, plus a notification that
/// stays in Notification Center for when the user was away from the Mac.
///
/// The frame lets clicks through, so it never blocks work, and fades after
/// `visibleSeconds`. It pulses slowly (under once a second, well below the
/// three flashes a second that can trigger seizures), and not at all with
/// Reduce Motion on.
@MainActor
final class SoundAlertPresenter {
    var visibleSeconds = 10.0
    private var panels: [NSPanel] = []
    private var hideTask: Task<Void, Never>?

    func present(_ alert: SoundAlert) {
        showOverlay(alert)
        notify(alert)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(alert.kind.title) heard", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Asked when the user turns alerts on, not at launch.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error { Diagnostics.engine.error("notification permission: \(String(describing: error), privacy: .public)") }
            Diagnostics.engine.info("notification permission granted: \(granted, privacy: .public)")
        }
    }

    private func showOverlay(_ alert: SoundAlert) {
        hide()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: SoundAlertOverlay(alert: alert))
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.visibleSeconds ?? 10))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        let fading = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            for panel in fading { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for panel in fading { panel.orderOut(nil) }
        })
    }

    private func hide() {
        hideTask?.cancel()
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    private func notify(_ alert: SoundAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.kind.title
        content.body = "Heard near this Mac at \(alert.time.formatted(date: .omitted, time: .shortened))."
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Diagnostics.engine.error("alert notification failed: \(String(describing: error), privacy: .public)") }
        }
    }
}

/// What a sound alert looks like on one screen.
struct SoundAlertOverlay: View {
    let alert: SoundAlert
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        ZStack {
            Color.orange.opacity(0.10)
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Color.orange, lineWidth: 18)
                .opacity(dimmed ? 0.45 : 1)
            VStack(spacing: 14) {
                Image(systemName: alert.kind.systemImage)
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(alert.kind.title)
                    .font(.system(size: 56, weight: .bold))
                Text("Heard near this Mac · \(alert.time.formatted(date: .omitted, time: .shortened))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            // Two slow pulses of 1.6 s each (about 0.6 a second): well under the seizure-safe limit.
            withAnimation(.easeInOut(duration: 0.8).repeatCount(4, autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement(children: .combine)
    }
}
