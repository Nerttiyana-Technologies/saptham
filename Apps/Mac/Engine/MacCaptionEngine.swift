import Foundation
import SapthamCore
import SapthamMacAudio

/// Everything the Mac UI may use, built once at launch. The UI receives these
/// objects and nothing else; it never sees audio sources or recognisers.
@MainActor
struct MacAppServices {
    let captions: any CaptionControlling
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let voiceNotes: VoiceNotes
}

/// Composition root for the Mac app: the only place that knows which audio
/// sources, which recogniser, and which folders exist.
@MainActor
enum MacCaptionEngine {
    enum SourceID {
        static let calls = "calls"
        static let microphone = "microphone"
        static let everything = "system"
    }

    enum LanguageID {
        static let english = "en"
        static let tamil = "ta"
        /// Tamil conversations that move in and out of English. Also the
        /// default in SapthamSettings.captionLanguageDefault, by agreement;
        /// rename both together. Listed first, so an unknown saved id falls
        /// back to it too.
        static let tamilAndEnglish = "ta+en"
    }

    /// ~/Library/Application Support/Saptham — outside any repository, on
    /// this Mac only (protected at rest by FileVault).
    static let dataFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Saptham", isDirectory: true)

    static func makeServices() -> MacAppServices {
        let transcripts = TranscriptLibrary(
            transcriptsFolder: dataFolder.appendingPathComponent("Transcripts", isDirectory: true),
            recordingsFolder: dataFolder.appendingPathComponent("Recordings", isDirectory: true))
        let corrections = CorrectionBook(fileURL: dataFolder.appendingPathComponent("corrections.json"))
        deleteExpired(from: transcripts)

        let captions = CaptionSession(
            sources: [
                CaptionSourceOption(id: SourceID.calls, title: "Phone calls",
                                    detail: "Calls from iPhone and FaceTime answered on this Mac",
                                    systemImage: "phone.fill"),
                CaptionSourceOption(id: SourceID.microphone, title: "Conversation",
                                    detail: "People talking near this Mac",
                                    systemImage: "person.2.wave.2.fill"),
                CaptionSourceOption(id: SourceID.everything, title: "Everything playing",
                                    detail: "Meetings, videos and any app's sound",
                                    systemImage: "speaker.wave.2.fill"),
            ],
            languages: [
                CaptionLanguageOption(id: LanguageID.tamilAndEnglish, title: "Tamil + English", nativeTitle: "தமிழ் + English"),
                CaptionLanguageOption(id: LanguageID.tamil, title: "Tamil", nativeTitle: "தமிழ்"),
                CaptionLanguageOption(id: LanguageID.english, title: "English", nativeTitle: "English"),
            ],
            languageID: SapthamSettings.captionLanguageValue,
            makeSource: { id in
                switch id {
                case SourceID.calls:
                    ProcessTapSource(target: .processes(matching: ProcessTapSource.callProcessNames))
                case SourceID.microphone:
                    MicrophoneSource()
                case SourceID.everything:
                    ProcessTapSource(target: .everything)
                default:
                    nil
                }
            },
            makeTranscriber: makeTranscriber,
            languageChanged: { UserDefaults.standard.set($0, forKey: SapthamSettings.captionLanguage) },
            transcripts: transcripts,
            correctText: { corrections.apply(to: $0) },
            makeRecorder: { id in
                // Only call audio is recorded, and only when the user has
                // turned recording on in Settings.
                guard id == SourceID.calls, SapthamSettings.recordCallsValue else { return nil }
                return FileAudioRecorder(folder: transcripts.recordingsFolder,
                                         fileName: "call-\(fileStamp.string(from: Date())).m4a")
            },
            // Every source: songs reach calls (hold music) and the
            // microphone as well as "Everything playing".
            makeSceneDetector: { SoundSceneDetector() })
        // Voice notes use whichever caption language is chosen when they arrive.
        let voiceNotes = VoiceNotes(recordingsFolder: transcripts.recordingsFolder, transcripts: transcripts,
                                    languageID: { captions.activeLanguageID },
                                    makeTranscriber: makeTranscriber)
        return MacAppServices(captions: captions, transcripts: transcripts, corrections: corrections,
                              voiceNotes: voiceNotes)
    }

    /// A fresh recogniser for a caption language: live captions and voice
    /// notes both build theirs here.
    nonisolated static func makeTranscriber(_ language: CaptionLanguageOption.ID) -> SpeechTranscribing {
        switch language {
        case LanguageID.tamil:
            WindowedCTCTranscriber { try loadTamilModel() }
        case LanguageID.tamilAndEnglish:
            // Tamil script by default; English where Apple's
            // English recogniser is sure it heard English.
            BilingualTranscriber(primary: WindowedCTCTranscriber { try loadTamilModel() },
                                 secondary: AppleSpeechTranscriber(),
                                 configuration: bilingualConfiguration)
        default:
            AppleSpeechTranscriber()   // English (India)
        }
    }

    nonisolated private static let bilingualConfiguration: BilingualArbiter.Configuration = {
        var configuration = BilingualArbiter.Configuration()
        configuration.primaryName = "Tamil"
        configuration.secondaryName = "English"
        return configuration
    }()

    /// AI4Bharat's IndicConformer, converted by Tools/ModelBuild and bundled
    /// by the Xcode project. Runs on this Mac's GPU; nothing leaves the device.
    nonisolated static func loadTamilModel() throws -> CTCWindowModel {
        guard let model = Bundle.main.url(forResource: "TamilSpeech", withExtension: "mlmodelc"),
              let description = Bundle.main.url(forResource: "TamilSpeech", withExtension: "json") else {
            throw SapthamError("Tamil captions are not included in this copy of Saptham.")
        }
        return try CoreMLCTCModel(compiledModel: model, description: description)
    }

    /// Applies the "keep transcripts for" setting.
    static func deleteExpired(from transcripts: TranscriptLibrary) {
        let days = SapthamSettings.keepDaysValue
        guard days > 0 else { return }
        let removed = transcripts.deleteSessions(endedBefore: Date(timeIntervalSinceNow: -Double(days) * 86_400))
        if removed > 0 { Diagnostics.engine.info("deleted \(removed, privacy: .public) expired transcripts") }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

extension MacCaptionEngine {
    /// Scripted captions plus sample transcripts and corrections in a
    /// throwaway folder, for `--preview-captions`, SwiftUI previews and
    /// screenshots. Touches no real data, audio or permissions.
    static func makePreviewServices() -> MacAppServices {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SapthamPreview-\(UUID().uuidString)", isDirectory: true)
        let transcripts = TranscriptLibrary(
            transcriptsFolder: folder.appendingPathComponent("Transcripts", isDirectory: true),
            recordingsFolder: folder.appendingPathComponent("Recordings", isDirectory: true))
        let corrections = CorrectionBook(fileURL: folder.appendingPathComponent("corrections.json"))
        corrections.add(heard: "Sabtham", replacement: "Saptham")
        corrections.add(heard: "butt theories", replacement: "batteries")

        let calls: [(minutesAgo: Double, lines: [String])] = [
            (95, ["Hello, am I speaking to Mr. Suresh?",
                  "This is Priya calling from the hospital.",
                  "Your appointment with the audiologist is confirmed for Tuesday at 11:30 in the morning.",
                  "Please bring your processor, the spare butt theories and the charge with you.",
                  "Okay, thank you, sir. Have a good day."]),
            (1_500, ["Hi, this is the bank. Your new debit card has been sent to the Chen Li branch.",
                     "You can collect it any time after Monday.",
                     "Sabtham shows live caffeine on the Mac, so I can read what the caller says."]),
        ]
        for call in calls {
            let start = Date(timeIntervalSinceNow: -call.minutesAgo * 60)
            let id = transcripts.beginSession(sourceID: SourceID.calls, sourceTitle: "Phone calls", languageID: LanguageID.english,
                                              recordingFile: nil, at: start)
            for (index, line) in call.lines.enumerated() {
                transcripts.appendLine(line, audio: AudioSpan(start: Double(index) * 5, end: Double(index) * 5 + 4),
                                       at: start.addingTimeInterval(Double(index) * 6), to: id)
            }
            transcripts.endSession(id, at: start.addingTimeInterval(Double(call.lines.count) * 6))
        }
        // Real recognisers on throwaway storage: a note opened in demo mode
        // is transcribed but never touches the user's library.
        let voiceNotes = VoiceNotes(recordingsFolder: transcripts.recordingsFolder, transcripts: transcripts,
                                    languageID: { LanguageID.tamilAndEnglish }, makeTranscriber: makeTranscriber)
        return MacAppServices(captions: PreviewCaptionController(), transcripts: transcripts, corrections: corrections,
                              voiceNotes: voiceNotes)
    }
}
