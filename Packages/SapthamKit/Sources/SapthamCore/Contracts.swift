@preconcurrency import AVFoundation

// The engine's seams. Sources and transcribers never know about each other;
// CaptionSession joins them, and the UI only ever sees CaptionFeed and
// CaptionControlling.

/// Something that produces audio: a microphone, call audio, an app's output.
public protocol AudioSource: AnyObject {
    /// Starts capturing. The stream finishes when `stop()` is called.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stop()
}

/// Turns a stream of audio into caption updates.
public protocol SpeechTranscribing: AnyObject {
    /// The stream finishes after the audio stream finishes and the last
    /// words have been settled.
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error>
}

public enum TranscriptUpdate: Equatable, Sendable {
    /// Provisional words for the sentence in progress; replaced by the next update.
    case volatile(String)
    /// A settled sentence, with where it lies in the audio stream and how
    /// sure the recogniser is of it, when known.
    case final(String, audio: AudioSpan? = nil, score: LineScore? = nil)
}

/// How sure a recogniser is of one settled line. Saved with transcript
/// lines, so how captions were chosen can be examined after a call.
public struct LineScore: Codable, Equatable, Sendable {
    /// 0 … 1, on the recogniser's own scale: two recognisers' values are
    /// only comparable after measuring both on the same speech.
    public var confidence: Double
    /// Which recogniser wrote the line, when several competed for it.
    public var recogniser: String?
    /// How sure the competing recogniser was of the same stretch of audio,
    /// when there was one and it produced anything.
    public var rivalConfidence: Double?

    public init(confidence: Double, recogniser: String? = nil, rivalConfidence: Double? = nil) {
        self.confidence = confidence
        self.recogniser = recogniser
        self.rivalConfidence = rivalConfidence
    }
}

/// A stretch of audio, in seconds from the first sample the recogniser was
/// given. A recording of the same stream uses the same clock.
public struct AudioSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// A choice the user can make about what to caption. The app defines the
/// list; the UI only displays and selects them.
public struct CaptionSourceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let systemImage: String

    public init(id: String, title: String, detail: String, systemImage: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

/// A language the user can caption in. The app defines the list; the UI only
/// displays and selects them.
public struct CaptionLanguageOption: Identifiable, Hashable, Sendable {
    public let id: String
    /// In English, e.g. "Tamil".
    public let title: String
    /// In the language itself, e.g. "தமிழ்".
    public let nativeTitle: String

    public init(id: String, title: String, nativeTitle: String) {
        self.id = id
        self.title = title
        self.nativeTitle = nativeTitle
    }
}

/// Everything the UI may ask of the engine.
@MainActor
public protocol CaptionControlling: AnyObject, Observable {
    var feed: CaptionFeed { get }
    var sources: [CaptionSourceOption] { get }
    /// The source being captioned, or nil when stopped.
    var activeSourceID: CaptionSourceOption.ID? { get }
    var languages: [CaptionLanguageOption] { get }
    var activeLanguageID: CaptionLanguageOption.ID { get }
    func start(_ sourceID: CaptionSourceOption.ID)
    func stop()
    /// Captions from now on are in this language. A source that is running
    /// restarts with the new recogniser, which ends its current transcript.
    func setLanguage(_ languageID: CaptionLanguageOption.ID)
    /// Removes every caption line from the screen (nothing is stored elsewhere).
    func clear()
}

public struct SapthamError: LocalizedError, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}
