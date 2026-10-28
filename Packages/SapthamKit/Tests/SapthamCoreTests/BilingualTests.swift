@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SapthamCore

struct BilingualArbiterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func line(_ text: String, _ from: Double, _ to: Double, _ confidence: Double) -> TranscriptUpdate {
        .final(text, audio: AudioSpan(start: from, end: to), score: LineScore(confidence: confidence))
    }

    private func texts(_ updates: [TranscriptUpdate]) -> [String] {
        updates.compactMap { if case .final(let text, _, _) = $0 { text } else { nil } }
    }

    // Figures below are from the 2026-10-01 measurement (see BilingualArbiter).

    @Test func sureEnglishReplacesTamilScript() {
        var arbiter = BilingualArbiter()
        // Sure, whole English sentences are shown as they arrive; the
        // Tamil-script guess for the same audio is then dropped.
        var shown = arbiter.add(line("Can you send me the invoice?", 0, 3, 0.99), from: .secondary, at: at(4))
        shown += arbiter.add(line("யூ ஸேண்ட் மீ தே இன் வோஈஸ்", 0.28, 4.56, 0.87), from: .primary, at: at(6))
        shown += arbiter.add(line("I need it for the audit.", 3.06, 4.86, 0.98), from: .secondary, at: at(6))
        shown += arbiter.tick(at: at(8.1))
        #expect(texts(shown) == ["Can you send me the invoice?", "I need it for the audit."])
        #expect(arbiter.showing == .secondary)
    }

    @Test func sureEnglishSentenceIsShownAtOnce() {
        var arbiter = BilingualArbiter()
        let shown = arbiter.add(line("Hi, how are you?", 0, 1.2, 0.97), from: .secondary, at: at(1.4))
        #expect(texts(shown) == ["Hi, how are you?"])
        #expect(arbiter.showing == .secondary)
        // The Tamil model's version of the same words, arriving later, is not shown.
        #expect(texts(arbiter.add(line("ஹாய் ஹவ் ஆர் யூ", 0.05, 1.25, 0.88), from: .primary, at: at(2))).isEmpty)
        #expect(texts(arbiter.tick(at: at(5))).isEmpty)
    }

    @Test func shortSureEnglishStillWaits() {
        var arbiter = BilingualArbiter()
        #expect(arbiter.add(line("Thank you.", 0, 0.8, 0.98), from: .secondary, at: at(1)).isEmpty)
        #expect(texts(arbiter.tick(at: at(3.1))) == ["Thank you."])
    }

    @Test func tamilStaysWhenEnglishIsUnsure() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("Naalaiku, kalai ila pattu", 5.76, 9.24, 0.34), from: .secondary, at: at(10))
        _ = arbiter.add(line("நாளைக்கு காலையில பத்து மணிக்கு", 5.88, 8.84, 0.91), from: .primary, at: at(10.3))
        #expect(texts(arbiter.tick(at: at(12.4))) == ["நாளைக்கு காலையில பத்து மணிக்கு"])
        #expect(arbiter.showing == .primary)
    }

    @Test func tamilSentenceWithEnglishWordsStaysTamil() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("Innaikku meeting, cancel", 22.02, 25.98, 0.46), from: .secondary, at: at(27))
        _ = arbiter.add(line("இன்னைக்கு மீட்டிங் கேன்சல் ஆயிடுச்சு", 22.12, 25.64, 0.96), from: .primary, at: at(27))
        #expect(texts(arbiter.finish()) == ["இன்னைக்கு மீட்டிங் கேன்சல் ஆயிடுச்சு"])
    }

    @Test func waitsUntilBothHaveMovedOnOrTimeRunsOut() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("வணக்கம்", 0, 1, 0.95), from: .primary, at: at(1))
        #expect(arbiter.tick(at: at(2.5)).isEmpty)
        // Both recognisers have settled lines beyond it: decided at once.
        _ = arbiter.add(line("Hello there", 3, 4, 0.99), from: .secondary, at: at(2.6))
        let shown = arbiter.add(line("ஹலோ தேர்", 3, 4, 0.9), from: .primary, at: at(2.7))
        #expect(texts(shown) == ["வணக்கம்"])
    }

    @Test func oneSureEnglishWordDoesNotReplaceATamilSentence() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("meeting", 1.0, 1.5, 0.95), from: .secondary, at: at(5))
        _ = arbiter.add(line("இன்னைக்கு மீட்டிங் இல்ல", 0, 4, 0.93), from: .primary, at: at(5))
        #expect(texts(arbiter.finish()) == ["இன்னைக்கு மீட்டிங் இல்ல"])
    }

    @Test func unsureEnglishAloneIsDroppedButSureEnglishAloneIsShown() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("Murray, pay you", 0, 2, 0.25), from: .secondary, at: at(2))
        #expect(texts(arbiter.tick(at: at(4.5))).isEmpty)
        let shown = arbiter.add(line("Thank you so much.", 5, 6, 0.97), from: .secondary, at: at(7))
        #expect(texts(shown + arbiter.tick(at: at(9.5))) == ["Thank you so much."])
    }

    @Test func aLateLineInsideDecidedAudioIsNotShownTwice() {
        var arbiter = BilingualArbiter()
        let shown = arbiter.add(line("Please call the doctor.", 0, 3, 0.99), from: .secondary, at: at(3))
        #expect(texts(shown + arbiter.tick(at: at(5.5))) == ["Please call the doctor."])
        _ = arbiter.add(line("ப்ளீஸ் கால் த டாக்டர்", 0.1, 2.9, 0.84), from: .primary, at: at(6))
        #expect(texts(arbiter.finish()).isEmpty)
    }

    @Test func winnersCarryTheirRecogniserAndTheRivalsConfidence() {
        var configuration = BilingualArbiter.Configuration()
        configuration.primaryName = "Tamil"
        configuration.secondaryName = "English"
        var arbiter = BilingualArbiter(configuration: configuration)
        var shown = arbiter.add(line("Thank you.", 0, 1, 0.98), from: .secondary, at: at(1))
        shown += arbiter.add(line("தேங்க் யூ", 0, 1, 0.86), from: .primary, at: at(1))
        shown += arbiter.add(line("Vanakkam", 2, 3, 0.30), from: .secondary, at: at(3))
        shown += arbiter.add(line("வணக்கம்", 2, 3, 0.95), from: .primary, at: at(3))
        shown += arbiter.finish()
        let scores = shown.compactMap { if case .final(_, _, let score) = $0 { score } else { nil } }
        #expect(scores == [LineScore(confidence: 0.98, recogniser: "English", rivalConfidence: 0.86),
                           LineScore(confidence: 0.95, recogniser: "Tamil", rivalConfidence: 0.30)])
    }

    @Test func provisionalWordsFollowTheLatestWinner() {
        var arbiter = BilingualArbiter()
        #expect(arbiter.add(.volatile("வணக்"), from: .primary, at: at(0)) == [.volatile("வணக்")])
        #expect(arbiter.add(.volatile("Hello"), from: .secondary, at: at(0)).isEmpty)
        _ = arbiter.add(line("Hello everyone.", 0, 2, 0.98), from: .secondary, at: at(2))
        _ = arbiter.finish()
        #expect(arbiter.add(.volatile("How are"), from: .secondary, at: at(3)) == [.volatile("How are")])
        #expect(arbiter.add(.volatile("ஹவ் ஆர்"), from: .primary, at: at(3)).isEmpty)
    }

    // Seen on iPhone 2026-10-28, in conversation: while a settled line waited
    // to be decided, its words were neither provisional nor shown, so text
    // vanished for up to `settleAfter` and came back as a line.

    @Test func aWaitingLineStaysOnScreenAsProvisionalWords() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(.volatile("வணக்கம் எப்படி"), from: .primary, at: at(0.5))
        // The Tamil decoder settles the first word; the arbiter holds it.
        let held = arbiter.add(line("வணக்கம்", 0, 1, 0.9), from: .primary, at: at(1))
        #expect(texts(held).isEmpty)
        #expect(held.last == .volatile("வணக்கம்"))
        // She keeps talking: the held words stay in front of the new ones.
        #expect(arbiter.add(.volatile("எப்படி இருக்கீங்க"), from: .primary, at: at(1.3))
                == [.volatile("வணக்கம் எப்படி இருக்கீங்க")])
    }

    @Test func decidingALineKeepsTheWordsStillBeingSaid() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("வணக்கம்", 0, 1, 0.9), from: .primary, at: at(1))
        _ = arbiter.add(.volatile("எப்படி இருக்கீங்க"), from: .primary, at: at(1.3))
        // The line is decided while speech goes on: the provisional words
        // are re-sent after it, so showing the line does not wipe them.
        let decided = arbiter.tick(at: at(3.1))
        #expect(texts(decided) == ["வணக்கம்"])
        #expect(decided.last == .volatile("எப்படி இருக்கீங்க"))
        // Nothing new: nothing re-sent.
        #expect(arbiter.tick(at: at(3.4)).isEmpty)
    }
}

struct BilingualTranscriberTests {
    final class Scripted: SpeechTranscribing {
        let updates: [TranscriptUpdate]
        let failure: Error?
        init(_ updates: [TranscriptUpdate], failing failure: Error? = nil) {
            self.updates = updates
            self.failure = failure
        }
        func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
            AsyncThrowingStream { continuation in
                for update in updates { continuation.yield(update) }
                continuation.finish(throwing: failure)
            }
        }
    }

    private func run(_ transcriber: BilingualTranscriber) async throws -> [String] {
        var shown: [String] = []
        for try await update in transcriber.transcribe(AsyncStream { $0.finish() }) {
            if case .final(let text, _, _) = update { shown.append(text) }
        }
        return shown
    }

    @Test func picksPerStretch() async throws {
        let transcriber = BilingualTranscriber(
            primary: Scripted([.final("வணக்கம்", audio: AudioSpan(start: 0, end: 1), score: LineScore(confidence: 0.95)),
                               .final("ஹவ் ஆர் யூ", audio: AudioSpan(start: 2, end: 3), score: LineScore(confidence: 0.88))]),
            secondary: Scripted([.final("Vanakkam", audio: AudioSpan(start: 0, end: 1), score: LineScore(confidence: 0.3)),
                                 .final("How are you?", audio: AudioSpan(start: 2, end: 3), score: LineScore(confidence: 0.98))]))
        #expect(try await run(transcriber) == ["வணக்கம்", "How are you?"])
    }

    @Test func carriesOnWithThePrimaryWhenTheSecondaryFails() async throws {
        let transcriber = BilingualTranscriber(
            primary: Scripted([.final("வணக்கம்", audio: AudioSpan(start: 0, end: 1), score: LineScore(confidence: 0.95))]),
            secondary: Scripted([], failing: SapthamError("English is not installed")))
        #expect(try await run(transcriber) == ["வணக்கம்"])
    }

    @Test func failsWhenThePrimaryFails() async {
        let transcriber = BilingualTranscriber(
            primary: Scripted([], failing: SapthamError("no Tamil model")),
            secondary: Scripted([]))
        await #expect(throws: SapthamError.self) { try await run(transcriber) }
    }
}

struct TranscriptLineScoreTests {
    @Test func linesSavedBeforeScoresExistedStillLoad() throws {
        let json = #"{"id":"0B7C4A1E-6E0C-4D7A-9C1B-2F0D3C4B5A69","heard":"Hello","time":0}"#
        let line = try JSONDecoder().decode(TranscriptLine.self, from: Data(json.utf8))
        #expect(line.heard == "Hello")
        #expect(line.score == nil)
    }

    @Test func scoresAreSavedWithTheLine() throws {
        let line = TranscriptLine(heard: "Hello", time: Date(timeIntervalSinceReferenceDate: 0), audio: nil,
                                  score: LineScore(confidence: 0.97, recogniser: "English", rivalConfidence: 0.88))
        let decoded = try JSONDecoder().decode(TranscriptLine.self, from: JSONEncoder().encode(line))
        #expect(decoded.score == line.score)
    }
}
