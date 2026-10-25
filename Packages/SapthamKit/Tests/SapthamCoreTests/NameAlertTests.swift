import AVFoundation
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

    @Test func findsATamilNameWithItsLastLetterDropped() {
        let suresh = NameSpotter(list: "Suresh, சுரேஷ்")
        #expect(suresh.firstName(in: "சுரே இங்க வா") == "சுரேஷ்")
        #expect(suresh.firstName(in: "சுரேஷ கமிய") == "சுரேஷ்")
        #expect(suresh.firstName(in: "சுரேந்திரன் வந்தாச்சு") == nil)    // another name, not a cut one
        #expect(spotter.firstName(in: "ரமே வா") == "ரமேஷ்")
        #expect(spotter.firstName(in: "பிரி பிரியா") == "பிரியா")
        #expect(NameSpotter(list: "பிரியா").firstName(in: "இதை பிரி") == nil)   // vowel endings are never cut
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

        alerts.hear("Priya!", from: "microphone", at: start.addingTimeInterval(16))   // called again
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

@MainActor
struct NameListenerTests {
    /// A microphone that stays open until stopped.
    final class OpenSource: AudioSource {
        private(set) var stopped = false
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = continuation
            return stream
        }
        func stop() { stopped = true; continuation?.finish() }
    }

    /// Says one line in its language, then waits for the audio to end.
    final class OneLine: SpeechTranscribing {
        let text: String
        init(_ text: String) { self.text = text }
        func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
            let text = text
            return AsyncThrowingStream { continuation in
                continuation.yield(.final(text))
                Task {
                    for await _ in audio {}
                    continuation.finish()
                }
            }
        }
    }

    final class Inputs {
        var wanted = true
        var covered = false
        var language = "en"
        var sources: [OpenSource] = []
        var heard: [String] = []
    }

    private func makeListener(_ inputs: Inputs) -> NameListener {
        NameListener(
            makeSource: { let source = OpenSource(); inputs.sources.append(source); return source },
            makeTranscriber: { OneLine($0 == "ta" ? "சுரேஷ் வா" : "Suresh, come") },
            languageID: { inputs.language },
            isWanted: { inputs.wanted },
            isCoveredElsewhere: { inputs.covered },
            heard: { inputs.heard.append($0) })
    }

    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func listensOnlyWhileWantedAndNotCovered() async throws {
        let inputs = Inputs()
        inputs.wanted = false
        let listener = makeListener(inputs)
        listener.start()
        #expect(inputs.sources.isEmpty)

        inputs.wanted = true
        listener.follow()
        try await settle()
        #expect(inputs.sources.count == 1)
        #expect(inputs.heard == ["Suresh, come"])

        inputs.covered = true          // Conversation captions took over
        listener.follow()
        #expect(inputs.sources[0].stopped)

        inputs.covered = false
        listener.follow()
        #expect(inputs.sources.count == 2)
        listener.stop()
        #expect(inputs.sources[1].stopped)
    }

    @Test func restartsInANewLanguageAndIgnoresRepeats() async throws {
        let inputs = Inputs()
        let listener = makeListener(inputs)
        listener.start()
        listener.follow()
        #expect(inputs.sources.count == 1)    // nothing changed: no restart

        inputs.language = "ta"
        listener.follow()
        try await settle()
        #expect(inputs.sources.count == 2)
        #expect(inputs.sources[0].stopped)
        #expect(inputs.heard.last == "சுரேஷ் வா")
        listener.stop()
    }
}
