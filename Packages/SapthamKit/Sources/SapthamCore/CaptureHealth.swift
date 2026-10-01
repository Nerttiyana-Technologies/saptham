import Foundation

/// Notices when a capture that should never go quiet has broken: no audio
/// arriving at all, or only exact digital silence (what macOS delivers when
/// the microphone is blocked). A quiet room is never exact zero, so it does
/// not count. Fed from the audio thread, read from the main thread.
public final class CaptureHealth: @unchecked Sendable {
    /// No buffer for this long means capture has stopped.
    public var noAudioAfter: TimeInterval = 4
    /// Only exact zeros for this long means the input is dead.
    public var zerosAfter: TimeInterval = 8

    private let lock = NSLock()
    private var lastBufferAt: Date
    private var zerosSince: Date?

    public init(startedAt: Date = Date()) {
        lastBufferAt = startedAt
    }

    /// Called for each captured buffer with its peak level.
    public func received(peak: Float, at time: Date = Date()) {
        lock.withLock {
            lastBufferAt = time
            if peak == 0 {
                if zerosSince == nil { zerosSince = time }
            } else {
                zerosSince = nil
            }
        }
    }

    /// When the capture broke, or nil while it is healthy.
    public func stalledSince(now: Date = Date()) -> Date? {
        lock.withLock {
            if now.timeIntervalSince(lastBufferAt) >= noAudioAfter { return lastBufferAt }
            if let zerosSince, now.timeIntervalSince(zerosSince) >= zerosAfter { return zerosSince }
            return nil
        }
    }
}
