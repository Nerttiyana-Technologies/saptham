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
    /// A settled sentence.
    case final(String)
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

/// Everything the UI may ask of the engine.
@MainActor
public protocol CaptionControlling: AnyObject, Observable {
    var feed: CaptionFeed { get }
    var sources: [CaptionSourceOption] { get }
    /// The source being captioned, or nil when stopped.
    var activeSourceID: CaptionSourceOption.ID? { get }
    func start(_ sourceID: CaptionSourceOption.ID)
    func stop()
    /// Removes every caption line from the screen (nothing is stored elsewhere).
    func clear()
}

public struct SapthamError: LocalizedError, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}
