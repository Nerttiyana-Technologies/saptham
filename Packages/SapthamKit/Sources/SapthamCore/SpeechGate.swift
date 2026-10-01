import Foundation

/// Says whether there may be speech in the audio, cheaply, so recognisers
/// can skip silence: on iPhone, running the speech models through hours of
/// quiet costs most of the battery captions use.
///
/// Loudness against a learned background level: the background follows
/// quiet stretches down at once and drifts up slowly, so a fan or traffic
/// becomes "silence" within seconds while a voice stands out. It opens on
/// the first loud block and stays open `holdOpen` seconds after the last,
/// so the pauses between words and the quiet a recogniser needs to settle
/// a sentence still reach it. Errs towards open: a missed word costs more
/// than a little battery.
///
/// Pure logic over levels, so it can be tested without audio.
public struct SpeechGate: Sendable {
    public struct Configuration: Sendable {
        /// A block this far above the background (dB) may be speech.
        public var aboveBackground = 10.0
        /// Anything quieter than this (dBFS) is silence regardless.
        public var floor = -62.0
        /// Seconds the gate stays open after the last loud block.
        public var holdOpen = 2.0
        /// How fast the background level may rise, dB per second.
        public var backgroundRise = 0.6
        public init() {}
    }

    public let configuration: Configuration
    public private(set) var isOpen = true
    private var background: Double?
    private var quietFor = 0.0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Takes one block of audio `seconds` long at `rms` (0 … 1); returns
    /// whether the gate is open after it.
    @discardableResult
    public mutating func add(rms: Float, seconds: Double) -> Bool {
        let level = rms > 0 ? 20 * log10(Double(rms)) : -120
        let base = background ?? level
        // Down at once, up slowly: the quietest recent level is the room.
        background = level < base ? level : min(level, base + configuration.backgroundRise * seconds)
        let loud = level > configuration.floor && level > (background ?? level) + configuration.aboveBackground
        if loud {
            quietFor = 0
            isOpen = true
        } else {
            quietFor += seconds
            if quietFor >= configuration.holdOpen { isOpen = false }
        }
        return isOpen
    }
}
