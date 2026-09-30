import Foundation

/// Turns the per-frame guesses of a CTC speech model, seen through a window
/// that slides along the audio, into provisional and settled caption text.
///
/// Every call to `consume` gives the best word piece (or blank) for each
/// frame of the latest window. Frames keep being revised while they are in
/// the window; a stretch of them is settled — emitted as a final line and
/// never looked at again — only at a pause between words:
/// - a run of `pauseFrames` blanks after speech settles everything before
///   the middle of that run;
/// - if speech runs on for more than `maxPendingFrames`, the longest pause
///   in the older part is used instead, so a line never has to wait for the
///   speaker to stop.
/// A cut always lands in a blank run that is followed by the start of a
/// word, never inside one. Frames close to the window's right edge have
/// heard little of what follows them, so they are shown but never settled.
///
/// Pure logic with no audio or model, so it can be tested with made-up frames.
public struct CTCLiveDecoder {
    public struct Configuration: Sendable {
        /// Seconds of audio per frame.
        public var frameSeconds: Double = 0.04
        /// Blank frames that count as a pause between lines (0.72 s).
        public var pauseFrames = 18
        /// Newest frames that are shown but not settled (0.48 s).
        public var rightGuardFrames = 12
        /// Pending speech longer than this is split at its longest pause.
        public var maxPendingFrames = 137
        /// A forced split ignores this many newest pending frames (1 s).
        public var forcedSplitTailFrames = 25

        public init() {}

        /// Tuned on FLEURS Tamil (2026-09-30): with an 8 s window these
        /// values gave 29.9 % word errors live against 28.0 % for whole clips.
        public static func forWindow(frames: Int) -> Configuration {
            var configuration = Configuration()
            // Settle before a frame's left context falls out of the window.
            configuration.maxPendingFrames = max(configuration.pauseFrames, frames - 63)
            return configuration
        }
    }

    public let vocabulary: [String]
    public let blank: Int
    public let configuration: Configuration
    private let wordStart: [Bool]

    /// Latest guess for each frame from `base` onward.
    private var frames: [Int] = []
    private var base = 0
    /// Frames before this are settled.
    private var settled = 0
    /// The last settled frame's guess, so a piece split across the cut is
    /// not repeated.
    private var lastSettledID: Int
    private var lastVolatile = ""

    public init(vocabulary: [String], blank: Int, wordStartMarker: String = "\u{2581}",
                configuration: Configuration = Configuration()) {
        self.vocabulary = vocabulary
        self.blank = blank
        self.configuration = configuration
        self.wordStart = vocabulary.map { $0.hasPrefix(wordStartMarker) }
        self.lastSettledID = blank
    }

    /// - Parameters:
    ///   - ids: best vocabulary index (or `blank`) for each frame of the window.
    ///   - firstFrame: the stream frame index of `ids[0]`; negative while the
    ///     window still reaches back before the start of the stream.
    public mutating func consume(ids: [Int], firstFrame: Int) -> [TranscriptUpdate] {
        store(ids, from: firstFrame)
        let end = firstFrame + ids.count
        let settleEnd = end - configuration.rightGuardFrames
        var updates: [TranscriptUpdate] = []

        while let cut = nextCut(from: max(settled, base), to: settleEnd), cut > settled {
            if let line = settle(upTo: cut) { updates.append(line) }
        }
        let volatile = text(from: settled, to: end)
        if volatile != lastVolatile {
            lastVolatile = volatile
            updates.append(.volatile(volatile))
        }
        return updates
    }

    /// Settles whatever is pending, at the end of the stream.
    public mutating func finish() -> [TranscriptUpdate] {
        let end = base + frames.count
        guard let line = settle(upTo: end) else { return [] }
        return [line]
    }

    // MARK: -

    private mutating func store(_ ids: [Int], from firstFrame: Int) {
        let start = max(firstFrame, settled)
        guard start < firstFrame + ids.count else { return }
        if frames.isEmpty { base = start }
        // Keep only what is unsettled.
        if settled > base {
            frames.removeFirst(min(settled - base, frames.count))
            base = settled
        }
        let needed = firstFrame + ids.count - base
        if frames.count < needed { frames += Array(repeating: blank, count: needed - frames.count) }
        for frame in start..<(firstFrame + ids.count) {
            frames[frame - base] = ids[frame - firstFrame]
        }
    }

    private func id(at frame: Int) -> Int {
        let index = frame - base
        return frames.indices.contains(index) ? frames[index] : blank
    }

    /// True when the first piece after `frame` starts a word, or nothing has
    /// been heard after it yet.
    private func wordStarts(after frame: Int, before end: Int) -> Bool {
        var next = frame
        while next < end {
            let piece = id(at: next)
            if piece != blank { return wordStart.indices.contains(piece) ? wordStart[piece] : true }
            next += 1
        }
        return true
    }

    private mutating func nextCut(from start: Int, to end: Int) -> Int? {
        guard start < end else { return nil }
        var run = 0
        var heardSpeech = false
        for frame in start..<end {
            if id(at: frame) == blank {
                run += 1
                if heardSpeech, run >= configuration.pauseFrames, wordStarts(after: frame, before: end) {
                    return frame - run / 2
                }
            } else {
                run = 0
                heardSpeech = true
            }
        }
        if !heardSpeech {
            // Only silence so far: move on without emitting anything, but
            // keep a pause's worth in case a word is just beginning.
            let silentUpTo = end - configuration.pauseFrames
            if silentUpTo > settled { settled = silentUpTo; lastSettledID = blank }
            return nil
        }
        guard end - start > configuration.maxPendingFrames else { return nil }

        var best: Int?
        var bestLength = 0
        var runStart: Int?
        let searchEnd = end - configuration.forcedSplitTailFrames
        var frame = start
        while frame < searchEnd {
            if id(at: frame) == blank {
                let begin = runStart ?? frame
                runStart = begin
                let length = frame - begin + 1
                if length > bestLength, wordStarts(after: frame + 1, before: end) {
                    bestLength = length
                    best = begin + (frame - begin) / 2
                }
            } else {
                runStart = nil
            }
            frame += 1
        }
        if let best, best > start { return best }
        return searchEnd
    }

    private mutating func settle(upTo cut: Int) -> TranscriptUpdate? {
        guard cut > settled else { return nil }
        var pieces: [Int] = []
        var previous = lastSettledID
        var firstSpoken: Int?
        var lastSpoken: Int?
        for frame in settled..<cut {
            let piece = id(at: frame)
            if piece != blank {
                if piece != previous { pieces.append(piece) }
                firstSpoken = firstSpoken ?? frame
                lastSpoken = frame
            }
            previous = piece
        }
        settled = cut
        lastSettledID = previous
        lastVolatile = ""
        let line = join(pieces)
        guard !line.isEmpty, let firstSpoken, let lastSpoken else { return nil }
        let seconds = configuration.frameSeconds
        return .final(line, audio: AudioSpan(start: Double(firstSpoken) * seconds,
                                             end: Double(lastSpoken + 1) * seconds))
    }

    private func text(from start: Int, to end: Int) -> String {
        var pieces: [Int] = []
        var previous = lastSettledID
        var frame = max(start, base)
        while frame < end {
            let piece = id(at: frame)
            if piece != blank, piece != previous { pieces.append(piece) }
            previous = piece
            frame += 1
        }
        return join(pieces)
    }

    private func join(_ pieces: [Int]) -> String {
        pieces.compactMap { vocabulary.indices.contains($0) ? vocabulary[$0] : nil }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
