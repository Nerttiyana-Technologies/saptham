import Foundation
import Testing
@testable import SapthamCore

struct EditPatternTests {
    private func session(_ edits: [(heard: String, edited: String?)]) -> TranscriptSession {
        TranscriptSession(sourceID: "microphone", sourceTitle: "Conversation", startedAt: Date(),
                          lines: edits.map { TranscriptLine(heard: $0.heard, edited: $0.edited, time: Date(), audio: nil) })
    }

    @Test func findsChangedWordsAndMergesNeighbours() {
        #expect(EditPatterns.fixes(heard: "கேப்ஷன் வண்ட குளோஸ் பண்ணிக்கலாம்", edited: "கேப்ஷன் விண்டோ குளோஸ் பண்ணிக்கலாம்")
                == [EditFix(heard: "வண்ட", replacement: "விண்டோ")])
        #expect(EditPatterns.fixes(heard: "கடலை மட்டல்லாம் வேணாம் ஸ்வீட்", edited: "கடலை மிட்டாய் வேண்டாம் ஸ்வீட்")
                == [EditFix(heard: "மட்டல்லாம் வேணாம்", replacement: "மிட்டாய் வேண்டாம்")])
        #expect(EditPatterns.fixes(heard: "Hello, CAPTION window", edited: "hello caption Window") == [])
    }

    @Test func leavesOutDeletionsAndLongRewrites() {
        // Only words removed: no replacement to make a rule from.
        #expect(EditPatterns.fixes(heard: "தோசா சாப்பிட்டு தோசைற அவங்க தோசா", edited: "தோசா சாப்பிட்டு") == [])
        #expect(EditPatterns.fixes(heard: "one two three four", edited: "five six seven eight") == [])
    }

    @Test func suggestsAFixRepeatedAcrossConversations() {
        let sessions = [session([("ஹெல்லோ", "ஹலோ")]), session([("ஹெல்லோ", "ஹலோ"), ("சரி", nil)]),
                        session([("ஹெல்லோ சார்", "ஹலோ சார்")])]
        let suggestions = EditPatterns.suggestions(in: sessions, rules: [])
        #expect(suggestions.map(\.heard) == ["ஹெல்லோ"])
        #expect(suggestions.first?.replacement == "ஹலோ")
        #expect(suggestions.first?.lineCount == 3)
        #expect(suggestions.first?.sessionIDs.count == 3)
    }

    @Test func holdsBackAFixRepeatedInOneConversationOnly() {
        // Real words both: right in that conversation, wrong as a rule everywhere.
        let one = session([("கொடுக்காது ஸ்வீட்", "கொடுக்காதே ஸ்வீட்"), ("எதுவும் கொடுக்காது", "எதுவும் கொடுக்காதே")])
        #expect(EditPatterns.suggestions(in: [one], rules: []).isEmpty)
    }

    @Test func leavesOutFragmentsRulesAndDeclined() {
        let fragment = [session([("ஷ", "ஷ்")]), session([("ஷ", "ஷ்")])]
        #expect(EditPatterns.suggestions(in: fragment, rules: []).isEmpty)

        let hello = [session([("ஹெல்லோ", "ஹலோ")]), session([("ஹெல்லோ", "ஹலோ")])]
        #expect(EditPatterns.suggestions(in: hello, rules: [CorrectionRule(heard: "ஹெல்லோ", replacement: "ஹலோ")]).isEmpty)
        let suggestion = try! #require(EditPatterns.suggestions(in: hello, rules: []).first)
        #expect(EditPatterns.suggestions(in: hello, rules: [], declined: [suggestion.id]).isEmpty)
        // A rule that says something else is changed, not skipped.
        #expect(EditPatterns.suggestions(in: hello, rules: [CorrectionRule(heard: "ஹெல்லோ", replacement: "Hello")]).count == 1)
    }
}

@MainActor
struct DeclinedSuggestionsTests {
    private func suggestion(lines: Int) -> EditSuggestion {
        EditSuggestion(heard: "ஹெல்லோ", replacement: "ஹலோ", lineCount: lines, sessionIDs: [UUID(), UUID()])
    }

    @Test func declinedPersistsAndCanBeRestored() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        DeclinedSuggestions(fileURL: file).decline(suggestion(lines: 2))
        let reopened = DeclinedSuggestions(fileURL: file)
        #expect(reopened.showing([suggestion(lines: 5)]).isEmpty)
        reopened.restore(suggestion(lines: 2).id)
        #expect(DeclinedSuggestions(fileURL: file).showing([suggestion(lines: 2)]).count == 1)
    }

    @Test func notNowWaitsForOneMoreLine() {
        let store = DeclinedSuggestions(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID()).json"))
        store.postpone(suggestion(lines: 2))
        #expect(store.showing([suggestion(lines: 2)]).isEmpty)
        #expect(store.showing([suggestion(lines: 3)]).count == 1)
    }
}
