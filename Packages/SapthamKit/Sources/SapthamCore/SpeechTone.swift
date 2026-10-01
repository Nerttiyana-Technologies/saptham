@preconcurrency import AVFoundation
import Foundation

/// How a sentence was said, as far as loudness can tell. A deaf reader
/// gets the words but not the voice; the caption's type carries this.
public enum SpeechTone: String, Codable, Sendable {
    case whisper
    case normal
    case raised
    case shout
}

/// Remembers how loud the captured audio was, moment by moment, and judges
/// a stretch of it against the room's usual speaking level. Fed from the
/// audio thread, asked from the main thread; pure logic over levels.
///
/// Shares its clock with AudioSpan by agreement: `add` must be given every
/// buffer the recogniser is given, in order, from the first. CaptionSession
/// feeds both from the same tee.
public final class LoudnessTracker: @unchecked Sendable {
    public struct Thresholds: Sendable {
        /// Below this (dBFS) a block is silence, not speech.
        public var speechFloor = -50.0
        /// Relative to the usual level, in dB.
        public var whisper = -9.0
        public var raised = 6.0
        public var shout = 11.0
        /// A shout must also be loud in absolute terms.
        public var shoutFloor = -16.0
        /// Seconds of speech needed before anything but `.normal` is judged.
        public var minimumHistory = 3.0
        /// Seconds of history that make up "usual".
        public var memory = 90.0
        public init() {}
    }

    public var thresholds = Thresholds()

    private struct Block {
        let start: Double
        let end: Double
        let decibels: Double
    }

    private let lock = NSLock()
    private var blocks: [Block] = []
    private var position = 0.0

    public init() {}

    /// Records one block of audio of `seconds` length at `rms` (0 … 1).
    public func add(rms: Float, seconds: Double) {
        let decibels = rms > 0 ? 20 * log10(Double(rms)) : -120
        lock.withLock {
            blocks.append(Block(start: position, end: position + seconds, decibels: decibels))
            position += seconds
            let cutoff = position - thresholds.memory
            if let first = blocks.first, first.end < cutoff {
                blocks.removeAll { $0.end < cutoff }
            }
        }
    }

    public func add(_ buffer: AVAudioPCMBuffer) {
        add(rms: buffer.rmsLevel, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
    }

    /// How the speech in `span` was said, compared with the speech before it.
    public func tone(for span: AudioSpan) -> SpeechTone {
        let t = thresholds
        return lock.withLock {
            let speech = blocks.filter { $0.decibels > t.speechFloor }
            let history = speech.reduce(0) { $0 + ($1.end - $1.start) }
            guard history >= t.minimumHistory else { return .normal }
            let inSpan = speech.filter { $0.end > span.start && $0.start < span.end }.map(\.decibels)
            guard !inSpan.isEmpty else { return .normal }
            let usual = Self.median(speech.map(\.decibels))
            // The louder half of the sentence: pauses between words do not
            // make a shout sound quiet.
            let level = Self.median(Array(inSpan.sorted().suffix(max(1, inSpan.count / 2))))
            let difference = level - usual
            if difference >= t.shout, level >= t.shoutFloor { return .shout }
            if difference >= t.raised { return .raised }
            if difference <= t.whisper { return .whisper }
            return .normal
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return -120 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

extension AVAudioPCMBuffer {
    /// Root-mean-square level of the first channel, 0 … 1.
    public var rmsLevel: Float {
        guard let samples = floatChannelData?[0], frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(frameLength) { sum += samples[index] * samples[index] }
        return (sum / Float(frameLength)).squareRoot()
    }
}
