import Foundation
import SapthamCore

/// The caption languages both apps offer and the recogniser behind each.
/// Compiled into the Mac and the iPhone app alike, so a language added here
/// appears on both.
enum CaptionRecognisers {
    enum LanguageID {
        static let english = "en"
        static let tamil = "ta"
        /// Tamil conversations that move in and out of English. Also the
        /// default in SapthamSettings.captionLanguageDefault, by agreement;
        /// rename both together. Listed first, so an unknown saved id falls
        /// back to it too.
        static let tamilAndEnglish = "ta+en"
    }

    static let languages = [
        CaptionLanguageOption(id: LanguageID.tamilAndEnglish, title: "Tamil + English", nativeTitle: "தமிழ் + English"),
        CaptionLanguageOption(id: LanguageID.tamil, title: "Tamil", nativeTitle: "தமிழ்"),
        CaptionLanguageOption(id: LanguageID.english, title: "English", nativeTitle: "English"),
    ]

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
    /// by the Xcode project. Runs on this device's GPU; nothing leaves it.
    nonisolated static func loadTamilModel() throws -> CTCWindowModel {
        guard let model = Bundle.main.url(forResource: "TamilSpeech", withExtension: "mlmodelc"),
              let description = Bundle.main.url(forResource: "TamilSpeech", withExtension: "json") else {
            throw SapthamError("Tamil captions are not included in this copy of Saptham.")
        }
        return try CoreMLCTCModel(compiledModel: model, description: description)
    }
}
