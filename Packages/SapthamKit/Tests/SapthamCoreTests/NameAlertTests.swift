import Foundation
import Testing
@testable import SapthamCore

struct NameSpotterTests {
    private let spotter = NameSpotter(list: "Priya, பிரியா, Anand Kumar, ரமேஷ்")

    @Test func findsAnEnglishNameAsAWholeWord() {
        #expect(spotter.firstName(in: "PRIYA, can you come here?") == "Priya")
        #expect(spotter.firstName(in: "Priyanka is here") == nil)
    }

    @Test func findsANameOfSeveralWords() {
        #expect(spotter.firstName(in: "Is anand kumar home?") == "Anand Kumar")
        #expect(spotter.firstName(in: "Anand is home, Kumar is not") == nil)
    }

    @Test func findsATamilNameWithACaseEnding() {
        #expect(spotter.firstName(in: "பிரியா எங்கே") == "பிரியா")
        #expect(spotter.firstName(in: "ரமேஷ் வந்தாச்சு") == "ரமேஷ்")
        #expect(spotter.firstName(in: "ரமேஷை கூப்பிடு") == "ரமேஷ்")       // accusative: the ending replaces the pulli
        #expect(spotter.firstName(in: "ரமேஷுக்கு போன் பண்ணு") == "ரமேஷ்")
        #expect(spotter.firstName(in: "ரமணி வந்தாள்") == nil)
    }

    @Test func noNamesFindNothing() {
        let empty = NameSpotter(list: " , ")
        #expect(empty.isEmpty)
        #expect(empty.firstName(in: "anything") == nil)
    }
}

@MainActor
struct NameAlertsTests {
    @Test func alertsOnlyForWatchedSourcesAndOncePerMention() {
        let alerts = NameAlerts(sourceIDs: ["microphone"], names: { "Priya" })
        var raised: [SoundAlert] = []
        alerts.onAlert = { raised.append($0) }
        let start = Date()

        alerts.hear("Priya, come", from: "system", at: start)                       // a video: ignored
        alerts.hear("Priya, come", from: "microphone", at: start)                   // partial
        alerts.hear("Priya, come here.", from: "microphone", at: start.addingTimeInterval(1))   // same sentence, settled
        #expect(raised.map(\.kind.id) == ["name"])

        alerts.hear("Priya!", from: "microphone", at: start.addingTimeInterval(25))
        #expect(raised.count == 2)
    }
}

@MainActor
struct CaptionSessionLineHeardTests {
    @Test func watchersGetEachCaptionAsShownWithItsSource() async throws {
        var heard: [String] = []
        let fix = TextCorrector(rules: [CorrectionRule(heard: "Pria", replacement: "Priya")])
        let session = CaptionSession(
            sources: [CaptionSourceOption(id: "microphone", title: "Conversation", detail: "", systemImage: "mic")],
            languages: [CaptionLanguageOption(id: "en", title: "English", nativeTitle: "English")],
            makeSource: { _ in CaptionSessionTranscriptTests.SilentSource() },
            makeTranscriber: { _ in CaptionSessionTranscriptTests.ScriptedTranscriber([.volatile("Pria"), .final("Pria, come here.")]) },
            correctText: fix.apply(to:),
            lineHeard: { text, source in heard.append("\(source): \(text)") })

        session.start("microphone")
        for _ in 0..<50 where session.activeSourceID != nil { try await Task.sleep(for: .milliseconds(20)) }

        #expect(heard == ["microphone: Priya", "microphone: Priya, come here."])
    }
}
