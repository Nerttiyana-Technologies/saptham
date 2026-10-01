import ActivityKit
import Foundation

/// What the Lock Screen and Dynamic Island show while Saptham captions:
/// the newest settled line and the words still forming. Compiled into the
/// app (which starts and updates the activity, see LiveActivityController)
/// and into the widget extension (which draws it): the two only ever meet
/// through this type, so its shape is their contract.
struct CaptionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The newest settled sentence, as shown in the app.
        var line: String
        /// Words still being spoken; may be empty.
        var partial: String
        /// SpeechTone raw value of `line`: "whisper", "normal", "raised", "shout".
        var tone: String
        /// "ta+en", "ta" or "en".
        var languageID: String
        /// A sound or name alert to show, or nil: its title and SF Symbol.
        var alertTitle: String?
        var alertSymbol: String?
        /// Recent loudness 0 … 1, for a small sound meter.
        var level: Double
    }

    var startedAt: Date
}
