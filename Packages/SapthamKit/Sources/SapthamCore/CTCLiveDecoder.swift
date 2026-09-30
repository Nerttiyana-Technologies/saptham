import Foundation

/// One frame of a CTC model's output: its best guess and how sure it is.
public struct CTCFrame: Equatable, Sendable {
    public var id: Int
    public var probability: Float

    public init(id: Int, probability: Float) {
        self.id = id
        self.probability = probability
    }
}

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
/// The model guesses words even for clicks, breathing and line noise, but
/// with low confidence. Text whose pieces average below
/// `minimumConfidence` is dropped when it is only a sound or two, and
/// shown as `unclearText` when longer, so the reader still knows someone
/// spoke.
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
        /// Average probability of a line's pieces below which it is not
        /// trusted. Measured 2026-09-30: real speech on a call scored
        /// 0.80–0.98 and noise bursts 0.22–0.66; the weakest 1 % of FLEURS
        /// Tamil sentences scored 0.86.
        public var minimumConfidence: Float = 0.70
        /// Untrusted text with fewer pieces than this is dropped; longer
        /// untrusted text becomes `unclearText`.
        public var unclearMinimumPieces = 4
        public var unclearText = "(unclear)"

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

    /// Latest guess for each frame from `base` onward, and its probability.
    private var frames: [Int] = []
    private var probabilities: [Float] = []
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

    /// Frames whose guesses are all fully confident.
    public mutating func consume(ids: [Int], firstFrame: Int) -> [TranscriptUpdate] {
        consume(frames: ids.map { CTCFrame(id: $0, probability: 1) }, firstFrame: firstFrame)
    }

    /// - Parameters:
    ///   - frames: best vocabulary index (or `blank`) for each frame of the
    ///     window, with the model's probability for it.
    ///   - firstFrame: the stream frame index of `frames[0]`; negative while
    ///     the window still reaches back before the start of the stream.
    public mutating func consume(frames window: [CTCFrame], firstFrame: Int) -> [TranscriptUpdate] {
        store(window, from: firstFrame)
        let end = firstFrame + window.count
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

    private mutating func store(_ window: [CTCFrame], from firstFrame: Int) {
        let start = max(firstFrame, settled)
        guard start < firstFrame + window.count else { return }
        if frames.isEmpty { base = start }
        // Keep only what is unsettled.
        if settled > base {
            let drop = min(settled - base, frames.count)
            frames.removeFirst(drop)
            probabilities.removeFirst(drop)
            base = settled
        }
        let needed = firstFrame + window.count - base
        if frames.count < needed {
            frames += Array(repeating: blank, count: needed - frames.count)
            probabilities += Array(repeating: 1, count: needed - probabilities.count)
        }
        for frame in start..<(firstFrame + window.count) {
            frames[frame - base] = window[frame - firstFrame].id
            probabilities[frame - base] = window[frame - firstFrame].probability
        }
    }

    private func id(at frame: Int) -> Int {
        let index = frame - base
        return frames.indices.contains(index) ? frames[index] : blank
    }

    private func probability(at frame: Int) -> Float {
        let index = frame - base
        return probabilities.indices.contains(index) ? probabilities[index] : 1
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

    /// The pieces spoken in `start..<end` (CTC collapse: repeats merged,
    /// blanks dropped), each with the probability of the frame it begins on.
    private func collapse(from start: Int, to end: Int)
        -> (pieces: [(id: Int, probability: Float)], firstSpoken: Int?, lastSpoken: Int?, lastID: Int) {
        var pieces: [(id: Int, probability: Float)] = []
        var previous = lastSettledID
        var firstSpoken: Int?
        var lastSpoken: Int?
        var frame = max(start, base)
        while frame < end {
            let piece = id(at: frame)
            if piece != blank {
                if piece != previous { pieces.append((piece, probability(at: frame))) }
                firstSpoken = firstSpoken ?? frame
                lastSpoken = frame
            }
            previous = piece
            frame += 1
        }
        return (pieces, firstSpoken, lastSpoken, previous)
    }

    private mutating func settle(upTo cut: Int) -> TranscriptUpdate? {
        guard cut > settled else { return nil }
        let spoken = collapse(from: settled, to: cut)
        settled = cut
        lastSettledID = spoken.lastID
        lastVolatile = ""
        guard let line = caption(spoken.pieces), let first = spoken.firstSpoken, let last = spoken.lastSpoken else {
            return nil
        }
        let seconds = configuration.frameSeconds
        let confidence = spoken.pieces.map { Double($0.probability) }.reduce(0, +) / Double(spoken.pieces.count)
        return .final(line, audio: AudioSpan(start: Double(first) * seconds, end: Double(last + 1) * seconds),
                      score: LineScore(confidence: confidence))
    }

    private func text(from start: Int, to end: Int) -> String {
        caption(collapse(from: start, to: end).pieces) ?? ""
    }

    /// What to show for these pieces: their text, `unclearText`, or nothing.
    private func caption(_ pieces: [(id: Int, probability: Float)]) -> String? {
        let line = join(pieces.map(\.id))
        guard !line.isEmpty else { return nil }
        let confidence = pieces.map(\.probability).reduce(0, +) / Float(pieces.count)
        guard confidence < configuration.minimumConfidence else { return line }
        return pieces.count >= configuration.unclearMinimumPieces ? configuration.unclearText : nil
    }

    private func join(_ pieces: [Int]) -> String {
        pieces.compactMap { vocabulary.indices.contains($0) ? vocabulary[$0] : nil }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
