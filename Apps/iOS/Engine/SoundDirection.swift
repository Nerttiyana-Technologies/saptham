@preconcurrency import AVFoundation
import Foundation
import Observation
import SapthamCore

/// Experimental: which side a voice comes from, from the level difference
/// between the left and right channels of the iPhone's stereo microphone.
/// Only runs while PhoneSettings.soundDirection is on (it asks
/// SharedMicrophone to capture in stereo); otherwise `balance` is nil.
///
/// Coupled to SharedMicrophone's stereo setup by channel order: channel 0
/// is the user's left with the iPhone upright in portrait, because the
/// microphone sets its preferred input orientation to portrait. If that
/// setup changes, left and right here swap.
@MainActor
@Observable
final class SoundDirection {
    /// -1 (left) … 0 (ahead) … +1 (right) while someone is speaking; nil
    /// when off, quiet, or the microphone is not in stereo.
    private(set) var balance: Double?
    /// Whether this iPhone's built-in microphone offers stereo at all.
    let isAvailable: Bool

    @ObservationIgnored private let microphone: SharedMicrophone
    @ObservationIgnored private var running: (source: AudioSource, task: Task<Void, Never>)?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(microphone: SharedMicrophone) {
        self.microphone = microphone
        isAvailable = SharedMicrophone.supportsStereo
    }

    /// Starts or stops with the setting; call once at launch.
    func start() {
        follow()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    private func follow() {
        let wanted = PhoneSettings.soundDirectionValue && isAvailable
        guard wanted != (running != nil) else { return }
        microphone.setStereo(wanted)
        if wanted {
            let source = microphone.makeSource()
            let task = Task { @MainActor [weak self] in
                guard let audio = try? await source.start() else { return }
                var smoothed = 0.0
                for await buffer in audio {
                    guard let self else { break }
                    guard let reading = Self.leftRight(buffer) else { balance = nil; continue }
                    // Only judge while something audible is heard.
                    guard max(reading.left, reading.right) > 0.004 else { balance = nil; continue }
                    let decibels = 20 * log10(Double(reading.right) / Double(max(reading.left, 1e-6)))
                    let target = max(-1, min(1, decibels / 6))
                    smoothed = smoothed * 0.8 + target * 0.2
                    balance = smoothed
                }
            }
            running = (source, task)
        } else if let running {
            running.source.stop()
            running.task.cancel()
            self.running = nil
            balance = nil
        }
    }

    private nonisolated static func leftRight(_ buffer: AVAudioPCMBuffer) -> (left: Float, right: Float)? {
        guard buffer.format.channelCount >= 2, let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        func rms(_ samples: UnsafeMutablePointer<Float>) -> Float {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            return (sum / Float(buffer.frameLength)).squareRoot()
        }
        return (rms(channels[0]), rms(channels[1]))
    }
}
