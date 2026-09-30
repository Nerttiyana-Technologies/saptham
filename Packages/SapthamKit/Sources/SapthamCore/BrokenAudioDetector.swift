/// Notices captured audio that is playing but mostly missing: loud sound
/// chopped up by stretches of exact digital silence. Speech in that state
/// cannot be recognised, and without a warning the caption window just
/// stays empty.
///
/// Seen 2026-09-30: video played by Safari to Bluetooth hearing devices
/// reached every capture method as about 93 % exact zeros (2–3 gaps a
/// second), while the same video through the Mac's speakers, or played by
/// another browser to the same hearing devices, had none. Real recordings
/// are never exactly zero for long while sound is playing; a paused video or
/// a quiet room has no loud sound and is not flagged.
///
/// Pure logic over samples, so it can be tested without audio hardware.
public struct BrokenAudioDetector {
    /// Seconds of audio judged together.
    public var blockSeconds: Double = 3
    /// A block must contain sound at least this loud (about -40 dBFS).
    public var loudPeak: Float = 0.01
    /// Share of exactly-zero samples above which a loud block is broken up.
    public var brokenZeroShare: Double = 0.6
    /// Consecutive broken blocks before reporting, so a single odd block
    /// (a cut in the video, a noise gate) does not raise a warning.
    public var blocksToReport = 2

    public private(set) var isBrokenUp = false

    private var samples = 0
    private var zeros = 0
    private var peak: Float = 0
    private var brokenBlocks = 0

    public init() {}

    /// Adds captured samples (any channel layout; exact zeros are what
    /// matter). Returns the new verdict when it changes, otherwise nil.
    public mutating func add(_ buffer: UnsafeBufferPointer<Float>, sampleRate: Double) -> Bool? {
        for value in buffer {
            if value == 0 { zeros += 1 } else { peak = max(peak, abs(value)) }
        }
        samples += buffer.count
        guard Double(samples) >= blockSeconds * sampleRate else { return nil }

        let broken = peak >= loudPeak && Double(zeros) / Double(samples) >= brokenZeroShare
        samples = 0
        zeros = 0
        peak = 0
        brokenBlocks = broken ? brokenBlocks + 1 : 0

        let verdict = brokenBlocks >= blocksToReport || (isBrokenUp && broken)
        guard verdict != isBrokenUp else { return nil }
        isBrokenUp = verdict
        return verdict
    }
}
