@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SapthamCore

struct BilingualArbiterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func line(_ text: String, _ from: Double, _ to: Double, _ confidence: Double) -> TranscriptUpdate {
        .final(text, audio: AudioSpan(start: from, end: to), confidence: confidence)
    }

    private func texts(_ updates: [TranscriptUpdate]) -> [String] {
        updates.compactMap { if case .final(let text, _, _) = $0 { text } else { nil } }
    }

    // Figures below are from the 2026-10-01 measurement (see BilingualArbiter).

    @Test func sureEnglishReplacesTamilScript() {
        var arbiter = BilingualArbiter()
        #expect(arbiter.add(line("Can you send me the invoice?", 0, 3, 0.99), from: .secondary, at: at(4)).isEmpty)
        #expect(arbiter.add(line("யூ ஸேண்ட் மீ தே இன் வோஈஸ்", 0.28, 4.56, 0.87), from: .primary, at: at(6)).isEmpty)
        #expect(arbiter.add(line("I need it for the audit.", 3.06, 4.86, 0.98), from: .secondary, at: at(6)).isEmpty)
        let shown = arbiter.tick(at: at(8.1))
        #expect(texts(shown) == ["Can you send me the invoice?", "I need it for the audit."])
        #expect(arbiter.showing == .secondary)
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
        _ = arbiter.add(line("Thank you so much.", 5, 6, 0.97), from: .secondary, at: at(7))
        #expect(texts(arbiter.tick(at: at(9.5))) == ["Thank you so much."])
    }

    @Test func aLateLineInsideDecidedAudioIsNotShownTwice() {
        var arbiter = BilingualArbiter()
        _ = arbiter.add(line("Please call the doctor.", 0, 3, 0.99), from: .secondary, at: at(3))
        #expect(texts(arbiter.tick(at: at(5.5))) == ["Please call the doctor."])
        _ = arbiter.add(line("ப்ளீஸ் கால் த டாக்டர்", 0.1, 2.9, 0.84), from: .primary, at: at(6))
        #expect(texts(arbiter.finish()).isEmpty)
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
            primary: Scripted([.final("வணக்கம்", audio: AudioSpan(start: 0, end: 1), confidence: 0.95),
                               .final("ஹவ் ஆர் யூ", audio: AudioSpan(start: 2, end: 3), confidence: 0.88)]),
            secondary: Scripted([.final("Vanakkam", audio: AudioSpan(start: 0, end: 1), confidence: 0.3),
                                 .final("How are you?", audio: AudioSpan(start: 2, end: 3), confidence: 0.98)]))
        #expect(try await run(transcriber) == ["வணக்கம்", "How are you?"])
    }

    @Test func carriesOnWithThePrimaryWhenTheSecondaryFails() async throws {
        let transcriber = BilingualTranscriber(
            primary: Scripted([.final("வணக்கம்", audio: AudioSpan(start: 0, end: 1), confidence: 0.95)]),
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
