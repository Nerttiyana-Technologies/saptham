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
    /// The app sets `onAlert` once it can show alerts.
    let nameAlerts: NameAlerts
    /// Hears the room for name alerts in every caption mode; nil in demo mode,
    /// which never opens the microphone. The app calls `start()`.
    var nameListener: NameListener? = nil
}

/// Composition root for the Mac app: the only place that knows which audio
/// sources, which recogniser, and which folders exist.
@MainActor
enum MacCaptionEngine {
    enum SourceID {
        static let calls = "calls"
        static let microphone = "microphone"
        static let everything = "system"
        /// Not a caption source: NameListener's room microphone, as told to NameAlerts.
        static let nameListener = "nameListener"
    }

    typealias LanguageID = CaptionRecognisers.LanguageID

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
        // People in the room (Conversation captions, or the name listener
        // in every other mode) and callers; not "Everything playing", where
        // films and videos say common names (ADR 0001).
        let nameAlerts = NameAlerts(sourceIDs: [SourceID.microphone, SourceID.calls, SourceID.nameListener],
                                    names: { SapthamSettings.alertNamesValue })

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
            languages: CaptionRecognisers.languages,
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
            makeSceneDetector: { SoundSceneDetector() },
            // Hidden coupling with NameListener below: it stands down in
            // Conversation mode because these lines reach NameAlerts. Stop
            // passing them and names go unheard in Conversation mode.
            lineHeard: { nameAlerts.hear($0, from: $1) })
        let nameListener = NameListener(
            makeSource: { MicrophoneSource() },
            makeTranscriber: makeTranscriber,
            languageID: { captions.activeLanguageID },
            isWanted: { !NameSpotter(list: SapthamSettings.alertNamesValue).isEmpty },
            isCoveredElsewhere: { captions.activeSourceID == SourceID.microphone },
            heard: { nameAlerts.hear(corrections.apply(to: $0), from: SourceID.nameListener) })
        // Voice notes use whichever caption language is chosen when they arrive.
        let voiceNotes = VoiceNotes(recordingsFolder: transcripts.recordingsFolder, transcripts: transcripts,
                                    languageID: { captions.activeLanguageID },
                                    makeTranscriber: makeTranscriber)
        return MacAppServices(captions: captions, transcripts: transcripts, corrections: corrections,
                              voiceNotes: voiceNotes, nameAlerts: nameAlerts, nameListener: nameListener)
    }

    nonisolated static func makeTranscriber(_ language: CaptionLanguageOption.ID) -> SpeechTranscribing {
        CaptionRecognisers.makeTranscriber(language)
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
                              voiceNotes: voiceNotes, nameAlerts: NameAlerts(sourceIDs: [], names: { "" }))
    }
}
