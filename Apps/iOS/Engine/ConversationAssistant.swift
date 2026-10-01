import Foundation
import FoundationModels
import Observation
import SapthamCore

/// Answers questions about a saved conversation and summarises it, using
/// only Apple's on-device language model (SystemLanguageModel). Never the
/// Private Cloud Compute model: no transcript ever leaves the iPhone.
///
/// The UI asks `readiness(for:)` before offering it, since the model may be
/// off (Apple Intelligence disabled, device not eligible) or may not read
/// the conversation's language (Tamil support is checked on the device).
@MainActor
@Observable
final class ConversationAssistant {
    enum Readiness: Equatable {
        case ready
        /// Works, with a caveat to show (e.g. Tamil lines cannot be read).
        case limited(String)
        case unavailable(String)
    }

    struct Answer: Equatable {
        let text: String
        /// The transcript line the answer came from, when the model named one.
        let sourceLineID: TranscriptLine.ID?
    }

    /// Lines given to the model, newest kept: its context is a few thousand tokens.
    @ObservationIgnored var maximumLines = 120

    private var model: SystemLanguageModel { .default }

    func readiness(for languageID: String?) -> Readiness {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .unavailable(Self.explain(reason))
        }
        let readsTamil = model.supportsLocale(Locale(identifier: "ta_IN"))
        switch languageID {
        case CaptionRecognisers.LanguageID.tamil where !readsTamil:
            return .unavailable("Apple's on-device model on this iPhone does not read Tamil yet.")
        case CaptionRecognisers.LanguageID.tamilAndEnglish where !readsTamil:
            return .limited("Apple's on-device model reads only the English lines of this conversation.")
        default:
            return .ready
        }
    }

    func answer(_ question: String, in session: TranscriptSession, corrector: TextCorrector) async throws -> Answer {
        let (text, lines) = numbered(session, corrector: corrector)
        let modelSession = LanguageModelSession(model: model, instructions: """
            You help a deaf person look back at a conversation that was captioned for them. \
            Answer their question using only the numbered transcript lines. Be brief: one short \
            sentence, giving the exact fact (a time, a place, a name, an amount). If the transcript \
            does not say, answer that it was not mentioned and give line 0.
            """)
        let response = try await modelSession.respond(
            to: "Transcript:\n\(text)\n\nQuestion: \(question)",
            generating: AssistantAnswer.self)
        let line = response.content.line
        let source = (1...lines.count).contains(line) ? lines[line - 1].id : nil
        return Answer(text: response.content.answer, sourceLineID: source)
    }

    func summary(of session: TranscriptSession, corrector: TextCorrector) async throws -> String {
        let (text, _) = numbered(session, corrector: corrector)
        let modelSession = LanguageModelSession(model: model, instructions: """
            Summarise a captioned conversation for the deaf person who took part, in at most three \
            short sentences. Keep every concrete fact: times, dates, places, names, amounts, and \
            anything they were asked to do or bring. Use only what the transcript says.
            """)
        return try await modelSession.respond(to: "Transcript:\n\(text)").content
    }

    // MARK: -

    private func numbered(_ session: TranscriptSession, corrector: TextCorrector) -> (String, [TranscriptLine]) {
        let lines = Array(session.lines.suffix(maximumLines))
        let text = lines.enumerated().map { index, line in
            "[\(index + 1)] \(line.time.formatted(date: .omitted, time: .shortened)) \(line.displayText(using: corrector))"
        }.joined(separator: "\n")
        return (text, lines)
    }

    private static func explain(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This iPhone cannot run Apple's on-device model."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in Settings to ask about conversations."
        case .modelNotReady: "Apple's on-device model is still downloading. Try again later."
        @unknown default: "Apple's on-device model is not available right now."
        }
    }
}

@Generable
struct AssistantAnswer {
    @Guide(description: "The answer, one short sentence")
    var answer: String
    @Guide(description: "The number of the transcript line the answer comes from, or 0")
    var line: Int
}
