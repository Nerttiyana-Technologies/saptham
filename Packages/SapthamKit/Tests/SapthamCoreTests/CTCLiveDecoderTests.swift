import Testing
@testable import SapthamCore

struct CTCLiveDecoderTests {
    // Pieces: 0 "▁vanakkam" 1 "▁na" 2 "nri" 3 "▁sir"; 4 is blank.
    private let vocabulary = ["\u{2581}vanakkam", "\u{2581}na", "nri", "\u{2581}sir"]
    private let blank = 4

    private func decoder(maxPending: Int = 1_000) -> CTCLiveDecoder {
        var configuration = CTCLiveDecoder.Configuration()
        configuration.pauseFrames = 5
        configuration.rightGuardFrames = 3
        configuration.maxPendingFrames = maxPending
        configuration.forcedSplitTailFrames = 2
        return CTCLiveDecoder(vocabulary: vocabulary, blank: blank, configuration: configuration)
    }

    private func frames(_ pattern: [(Int, Int)]) -> [Int] {
        pattern.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    private func finals(_ updates: [TranscriptUpdate]) -> [String] {
        updates.compactMap { if case .final(let text, _, _) = $0 { text } else { nil } }
    }

    @Test func speechThenPauseSettlesALineWithItsTiming() {
        var d = decoder()
        let ids = frames([(blank, 2), (0, 2), (blank, 1), (1, 1), (2, 1), (blank, 10)])
        let updates = d.consume(ids: ids, firstFrame: 0)
        #expect(finals(updates) == ["vanakkam nanri"])
        guard case .final(_, let span?, _) = updates.first(where: { if case .final = $0 { true } else { false } }) else {
            Issue.record("no timing")
            return
        }
        #expect(abs(span.start - 0.08) < 1e-9)   // frame 2
        #expect(abs(span.end - 0.28) < 1e-9)     // after frame 6
    }

    @Test func wordsNearTheRightEdgeStayProvisional() {
        var d = decoder()
        // The pause is only complete inside the right guard.
        let ids = frames([(0, 2), (blank, 6)])
        let updates = d.consume(ids: ids, firstFrame: 0)
        #expect(finals(updates) == [])
        #expect(updates.last == .volatile("vanakkam"))
    }

    @Test func laterWindowsReviseUnsettledFrames() {
        var d = decoder()
        _ = d.consume(ids: frames([(0, 2), (blank, 2), (3, 1)]), firstFrame: 0)
        // The next window has heard more: frame 4 was "▁na", not "▁sir".
        let updates = d.consume(ids: frames([(blank, 2), (1, 1), (2, 1), (blank, 10)]), firstFrame: 2)
        #expect(finals(updates) == ["vanakkam nanri"])
    }

    @Test func aPauseInsideAWordIsNotACut() {
        var d = decoder()
        // "▁na" … long gap … "nri" continues the same word.
        let ids = frames([(1, 1), (blank, 6), (2, 1), (blank, 10)])
        let updates = d.consume(ids: ids, firstFrame: 0)
        #expect(finals(updates) == ["nanri"])
    }

    @Test func longSpeechIsSplitAtItsLongestPause() {
        var d = decoder(maxPending: 12)
        // No pause of 5 blanks, but one of 3 before "▁sir".
        let ids = frames([(0, 1), (blank, 1), (1, 1), (2, 1), (blank, 3), (3, 1), (blank, 1), (0, 1), (blank, 1), (1, 1),
                          (blank, 1), (3, 1), (blank, 1), (0, 1)])
        let updates = d.consume(ids: ids, firstFrame: 0)
        #expect(finals(updates).first == "vanakkam nanri")
    }

    private func sure(_ pattern: [(Int, Int)], probability: Float) -> [CTCFrame] {
        frames(pattern).map { CTCFrame(id: $0, probability: $0 == blank ? 0.99 : probability) }
    }

    @Test func dropsAnUnsureSoundOrTwo() {
        var d = decoder()
        // A click the model half-reads as "▁na nri".
        let updates = d.consume(frames: sure([(1, 1), (2, 1), (blank, 12)], probability: 0.4), firstFrame: 0)
        #expect(finals(updates) == [])
        #expect(!updates.contains(.volatile("nanri")))
    }

    @Test func marksLongUnsureSpeechUnclear() {
        var d = decoder()
        let updates = d.consume(frames: sure([(0, 1), (blank, 1), (1, 1), (2, 1), (blank, 1), (3, 1), (blank, 12)],
                                             probability: 0.4), firstFrame: 0)
        #expect(finals(updates) == ["(unclear)"])
    }

    @Test func keepsConfidentSpeech() {
        var d = decoder()
        let updates = d.consume(frames: sure([(1, 1), (2, 1), (blank, 12)], probability: 0.9), firstFrame: 0)
        #expect(finals(updates) == ["nanri"])
    }

    @Test func silenceProducesNothing() {
        var d = decoder()
        #expect(d.consume(ids: frames([(blank, 40)]), firstFrame: -10) == [])
        #expect(d.finish() == [])
    }

    @Test func finishSettlesWhatIsPending() {
        var d = decoder()
        _ = d.consume(ids: frames([(3, 1), (blank, 1)]), firstFrame: 0)
        #expect(finals(d.finish()) == ["sir"])
    }

    @Test func settledFramesAreNeverEmittedTwice() {
        var d = decoder()
        var all: [String] = []
        // A window of 20 frames sliding 4 frames at a time over one sentence and silence.
        let stream = frames([(blank, 20), (0, 2), (blank, 2), (1, 1), (2, 1), (blank, 40)])
        var first = -20
        while first + 20 <= stream.count {
            all += finals(d.consume(ids: Array(stream[max(0, first)..<(first + 20)]).padded(to: 20, with: blank, front: first < 0),
                                    firstFrame: first))
            first += 4
        }
        all += finals(d.finish())
        #expect(all == ["vanakkam nanri"])
    }
}

private extension Array where Element == Int {
    func padded(to count: Int, with value: Int, front: Bool) -> [Int] {
        let fill = [Int](repeating: value, count: Swift.max(0, count - self.count))
        return front ? fill + self : self + fill
    }
}
