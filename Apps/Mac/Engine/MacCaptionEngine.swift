import SapthamCore
import SapthamMacAudio

/// Composition root for the Mac app: the only place that knows which audio
/// sources and which recogniser exist. The UI receives a CaptionControlling
/// and nothing else.
@MainActor
enum MacCaptionEngine {
    enum SourceID {
        static let calls = "calls"
        static let microphone = "microphone"
        static let everything = "system"
    }

    static func makeController() -> CaptionControlling {
        CaptionSession(
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
            makeTranscriber: { AppleSpeechTranscriber() }   // English (India), on device
        )
    }
}
