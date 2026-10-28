import Foundation
import SapthamCore

/// Everything the iPhone UI may use, built once at launch. The UI receives
/// these objects and nothing else; it never sees audio sources or recognisers.
@MainActor
struct PhoneAppServices {
    let captions: any CaptionControlling
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let voiceNotes: VoiceNotes
    let alerts: PhoneAlerts
    /// Questions and summaries about saved conversations (on-device model).
    let assistant: ConversationAssistant
    /// Battery used per captioning session.
    let battery: BatteryMeter
    /// Which side voices come from (experimental; see PhoneSettings).
    let direction: SoundDirection
    /// Sign-language dictionary packs (ADR 0003); hidden while none is installed.
    let signs: SignDictionary
}

/// Composition root for the iPhone app: the only place that knows which
/// audio sources, which recognisers and which folders exist.
@MainActor
enum PhoneCaptionEngine {
    enum SourceID {
        /// People talking near the iPhone. iOS gives apps no access to
        /// cellular call audio, so this is the only source.
        static let conversation = "microphone"
    }

    /// Application Support/Saptham, on this iPhone only. Kept out of iCloud
    /// backups: transcripts hold other people's words and never leave the
    /// device (see excludeFromBackup).
    static let dataFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Saptham", isDirectory: true)

    static func makeServices() -> PhoneAppServices {
        excludeFromBackup(dataFolder)
        let transcripts = TranscriptLibrary(
            transcriptsFolder: dataFolder.appendingPathComponent("Transcripts", isDirectory: true),
            recordingsFolder: dataFolder.appendingPathComponent("Recordings", isDirectory: true))
        let corrections = CorrectionBook(fileURL: dataFolder.appendingPathComponent("corrections.json"))
        deleteExpired(from: transcripts)

        let microphone = SharedMicrophone()
        let alerts = PhoneAlerts(microphone: microphone)
        let nameAlerts = NameAlerts(sourceIDs: [SourceID.conversation], names: { SapthamSettings.alertNamesValue })
        nameAlerts.onAlert = { alerts.present($0) }

        let captions = CaptionSession(
            sources: [
                CaptionSourceOption(id: SourceID.conversation, title: "Conversation",
                                    detail: "People talking near this iPhone", systemImage: "person.2.wave.2.fill"),
            ],
            languages: CaptionRecognisers.languages,
            languageID: SapthamSettings.captionLanguageValue,
            makeSource: { id in id == SourceID.conversation ? microphone.makeSource() : nil },
            makeTranscriber: CaptionRecognisers.makeTranscriber,
            languageChanged: { UserDefaults.standard.set($0, forKey: SapthamSettings.captionLanguage) },
            transcripts: transcripts,
            correctText: { corrections.apply(to: $0) },
            makeSceneDetector: { SoundSceneDetector() },
            lineHeard: { nameAlerts.hear($0, from: $1) })
        // Voice notes use whichever caption language is chosen when they arrive.
        let voiceNotes = VoiceNotes(recordingsFolder: transcripts.recordingsFolder, transcripts: transcripts,
                                    languageID: { captions.activeLanguageID },
                                    makeTranscriber: CaptionRecognisers.makeTranscriber)
        return PhoneAppServices(captions: captions, transcripts: transcripts, corrections: corrections,
                                voiceNotes: voiceNotes, alerts: alerts, assistant: ConversationAssistant(),
                                battery: BatteryMeter(), direction: SoundDirection(microphone: microphone),
                                signs: SignDictionary(dataFolder: dataFolder, downloader: AppleHostedSignPackDownloader()))
    }

    /// Applies the "keep transcripts for" setting.
    static func deleteExpired(from transcripts: TranscriptLibrary) {
        let days = SapthamSettings.keepDaysValue
        guard days > 0 else { return }
        let removed = transcripts.deleteSessions(endedBefore: Date(timeIntervalSinceNow: -Double(days) * 86_400))
        if removed > 0 { Diagnostics.engine.info("deleted \(removed, privacy: .public) expired transcripts") }
    }

    private static func excludeFromBackup(_ folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Diagnostics.engine.error("could not keep transcripts out of backups: \(String(describing: error), privacy: .public)")
        }
    }
}

extension PhoneCaptionEngine {
    /// Scripted captions plus sample transcripts and corrections in a
    /// throwaway folder, for `--preview-captions`, SwiftUI previews and
    /// screenshots. Touches no real data, audio or permissions.
    static func makePreviewServices() -> PhoneAppServices {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SapthamPreview-\(UUID().uuidString)", isDirectory: true)
        let transcripts = TranscriptLibrary(
            transcriptsFolder: folder.appendingPathComponent("Transcripts", isDirectory: true),
            recordingsFolder: folder.appendingPathComponent("Recordings", isDirectory: true))
        let corrections = CorrectionBook(fileURL: folder.appendingPathComponent("corrections.json"))
        corrections.add(heard: "Sabtham", replacement: "Saptham")

        let samples: [(minutesAgo: Double, source: String, title: String, language: String, lines: [String])] = [
            (20, SourceID.conversation, "Conversation", CaptionRecognisers.LanguageID.tamilAndEnglish,
             ["Hello, is this Suresh?",
              "வணக்கம் சுரேஷ், எப்படி இருக்கீங்க?",
              "I'm good. The meeting moved to Thursday.",
              "சரி, நாளைக்கு காலை பதினொரு மணிக்கு டாக்டர் அப்பாயின்ட்மென்ட் இருக்கு.",
              "Please bring your processor and the charger."]),
            (110, VoiceNotes.sourceID, "Voice note: Amma", CaptionRecognisers.LanguageID.tamil,
             ["சாப்பிட்டியா? மதியம் வீட்டுக்கு வா."]),
            (1_500, SourceID.conversation, "Conversation", CaptionRecognisers.LanguageID.english,
             ["The bank has sent your new debit card to the Chennai branch.",
              "You can collect it any time after Monday."]),
        ]
        for sample in samples {
            let start = Date(timeIntervalSinceNow: -sample.minutesAgo * 60)
            let id = transcripts.beginSession(sourceID: sample.source, sourceTitle: sample.title,
                                              languageID: sample.language, recordingFile: nil, at: start)
            for (index, line) in sample.lines.enumerated() {
                transcripts.appendLine(line, audio: AudioSpan(start: Double(index) * 5, end: Double(index) * 5 + 4),
                                       at: start.addingTimeInterval(Double(index) * 6), to: id)
            }
            transcripts.endSession(id, at: start.addingTimeInterval(Double(sample.lines.count) * 6))
        }
        let voiceNotes = VoiceNotes(recordingsFolder: transcripts.recordingsFolder, transcripts: transcripts,
                                    languageID: { CaptionRecognisers.LanguageID.tamilAndEnglish },
                                    makeTranscriber: CaptionRecognisers.makeTranscriber)
        let captions = PreviewCaptionController(sources: [
            CaptionSourceOption(id: SourceID.conversation, title: "Conversation",
                                detail: "People talking near this iPhone", systemImage: "person.2.wave.2.fill"),
        ])
        let microphone = SharedMicrophone()
        return PhoneAppServices(captions: captions, transcripts: transcripts, corrections: corrections,
                                voiceNotes: voiceNotes, alerts: PhoneAlerts(microphone: microphone),
                                assistant: ConversationAssistant(), battery: BatteryMeter(),
                                direction: SoundDirection(microphone: microphone),
                                signs: SignDictionary(dataFolder: FileManager.default.temporaryDirectory))
    }
}
