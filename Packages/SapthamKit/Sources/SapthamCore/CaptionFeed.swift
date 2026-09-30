import Foundation
import Observation

/// One settled caption sentence.
public struct CaptionLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let time: Date

    public init(id: UUID = UUID(), text: String, time: Date = Date()) {
        self.id = id
        self.text = text
        self.time = time
    }
}

public enum CaptionState: Equatable, Sendable {
    case idle
    /// Loading the speech model or waiting for permission.
    case preparing
    /// Capturing. For call audio this includes waiting for a call to start.
    case listening
    case failed(String)
}

/// What the UI observes. Read-only for views; only the engine (or a preview
/// mock) calls the mutating methods.
@MainActor
@Observable
public final class CaptionFeed {
    public private(set) var lines: [CaptionLine] = []
    /// The sentence being spoken right now, still changing.
    public private(set) var partial: String = ""
    public private(set) var state: CaptionState = .idle
    /// Recent loudness of the captured audio, 0 (silent) … 1 (loud).
    public private(set) var level: Float = 0
    /// When the most recent speech arrived; lets the UI fade when quiet.
    public private(set) var lastSpeechAt: Date?
    /// True while audio is arriving (for call audio: a call is playing).
    /// Turns false about `silenceAfter` after the last buffer.
    public private(set) var isReceivingAudio = false
    /// True while the captured sound is playing but mostly missing (see
    /// BrokenAudioDetector); captions cannot work until that changes.
    public private(set) var isAudioBrokenUp = false

    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    private static let silenceAfter: Duration = .milliseconds(1_500)
    /// About -60 dBFS: quieter than any speech, louder than digital silence.
    private static let audibleLevel: Float = 0.001

    /// Older lines are dropped from memory; transcripts are not kept.
    public let maxLines: Int

    public init(maxLines: Int = 200) {
        self.maxLines = maxLines
    }

    public func apply(_ update: TranscriptUpdate, at time: Date = Date()) {
        switch update {
        case .volatile(let text):
            partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .final(let text, _):
            partial = ""
            let settled = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !settled.isEmpty else { return }
            lines.append(CaptionLine(text: settled, time: time))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
        lastSpeechAt = time
    }

    public func setState(_ state: CaptionState) {
        self.state = state
        if state != .listening {
            markSilent()
            isAudioBrokenUp = false
        }
    }

    public func setAudioBrokenUp(_ brokenUp: Bool) {
        isAudioBrokenUp = brokenUp
    }

    /// Called for each burst of captured audio. Silence is detected both by
    /// buffers stopping and by buffers that carry nothing audible: after a
    /// relayed call ends, the Mac's call service keeps sending pure silence
    /// (observed 2026-09-30), which must not count as a call in progress.
    public func setLevel(_ level: Float) {
        self.level = min(max(level, 0), 1)
        guard level > Self.audibleLevel else { return }
        if !isReceivingAudio { isReceivingAudio = true }
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceAfter)
            guard !Task.isCancelled else { return }
            self?.markSilent()
        }
    }

    private func markSilent() {
        silenceTimer?.cancel()
        silenceTimer = nil
        level = 0
        isReceivingAudio = false
    }

    public func clear() {
        lines.removeAll()
        partial = ""
    }
}
