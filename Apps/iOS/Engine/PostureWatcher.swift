import CoreMotion
import Foundation
import Observation

/// How the iPhone is being held, read from gravity. The app treats this as
/// its main control: raised to read, laid flat to share with the person
/// opposite, face down to stop captions (sound alerts stay on).
enum Posture: Equatable, Sendable {
    /// In the hand or propped up: the screen faces the user.
    case raised
    /// Face up on a table: the screen is shared with someone opposite.
    case flat
    /// Face down: the user has put it away.
    case faceDown
}

/// Watches the device's attitude and reports a posture once it has held for
/// a moment, so a wobble in the hand is not a change. Knows nothing about
/// captions; the app decides what each posture means.
@MainActor
@Observable
final class PostureWatcher {
    private(set) var posture = Posture.raised

    /// How long a new posture must hold before it counts.
    @ObservationIgnored var settleTime: TimeInterval = 0.7
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var candidate: (posture: Posture, since: Date)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated { self?.observe(gravityZ: gravity.z) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        candidate = nil
    }

    /// `z` is gravity along the axis out of the screen: about -1 face up,
    /// +1 face down, near 0 upright. The bands overlap the thresholds a
    /// little (hysteresis) so a tilted table or reading posture is stable.
    private func observe(gravityZ z: Double) {
        let seen: Posture
        switch posture {
        case .flat: seen = z < -0.75 ? .flat : (z > 0.85 ? .faceDown : .raised)
        case .faceDown: seen = z > 0.75 ? .faceDown : (z < -0.85 ? .flat : .raised)
        case .raised: seen = z < -0.9 ? .flat : (z > 0.9 ? .faceDown : .raised)
        }
        guard seen != posture else {
            candidate = nil
            return
        }
        if let candidate, candidate.posture == seen {
            if Date().timeIntervalSince(candidate.since) >= settleTime {
                posture = seen
                self.candidate = nil
            }
        } else {
            candidate = (seen, Date())
        }
    }
}
