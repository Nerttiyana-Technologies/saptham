/// Notices captured audio that is playing but mostly missing: loud sound
/// chopped up by stretches of exact digital silence. Speech in that state
/// cannot be recognised, and without a warning the caption window just
/// stays empty.
///
/// Seen 2026-09-30: video played by Safari to Bluetooth hearing devices
/// reached every capture method as about 93 % exact zeros (2–3 gaps a
/// second), and after a few seconds often as nothing at all, while the same
/// video through the Mac's speakers, or played by another browser to the
/// same hearing devices, had no gaps. Real recordings are never exactly zero
/// for long while sound is playing.
///
/// - A loud block that is mostly exact silence AND broken into many gaps
///   raises the warning. The gap count keeps a single sound followed by
///   silence (a notification) from raising it.
/// - A block with no loud sound changes nothing: a paused video and a
///   capture that has lost the sound entirely look the same.
/// - A loud block that is not broken up clears it.
///
/// Pure logic over samples, so it can be tested without audio hardware.
public struct BrokenAudioDetector {
    /// Seconds of audio judged together.
    public var blockSeconds: Double = 3
    /// A block must contain sound at least this loud (about -40 dBFS).
    public var loudPeak: Float = 0.01
    /// Share of exactly-zero samples above which a loud block may be broken up.
    public var brokenZeroShare: Double = 0.6
    /// Runs of exact zeros at least this long count as a gap.
    public var gapSeconds: Double = 0.005
    /// Gaps a block needs to count as broken up. Safari measured 5–8 per 3 s;
    /// one sound followed by silence makes 1–2.
    public var gapsToReport = 3

    public private(set) var isBrokenUp = false
    /// Measurements of the most recently judged block, for diagnostics.
    public private(set) var lastBlock: (zeroShare: Double, gaps: Int, peak: Float)?

    private var samples = 0
    private var zeros = 0
    private var peak: Float = 0
    private var gaps = 0
    private var zeroRun = 0

    public init() {}

    /// Adds captured samples (any channel layout; exact zeros are what
    /// matter). Returns the new verdict when it changes, otherwise nil.
    public mutating func add(_ buffer: UnsafeBufferPointer<Float>, sampleRate: Double) -> Bool? {
        let minimumGap = max(1, Int(gapSeconds * sampleRate))
        for value in buffer {
            if value == 0 {
                zeros += 1
                zeroRun += 1
                if zeroRun == minimumGap { gaps += 1 }
            } else {
                peak = max(peak, abs(value))
                zeroRun = 0
            }
        }
        samples += buffer.count
        guard Double(samples) >= blockSeconds * sampleRate else { return nil }

        let zeroShare = Double(zeros) / Double(samples)
        lastBlock = (zeroShare, gaps, peak)
        let loud = peak >= loudPeak
        let broken = loud && zeroShare >= brokenZeroShare && gaps >= gapsToReport
        samples = 0
        zeros = 0
        peak = 0
        gaps = 0

        guard loud else { return nil }
        guard broken != isBrokenUp else { return nil }
        isBrokenUp = broken
        return broken
    }
}
