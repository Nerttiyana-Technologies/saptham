import Foundation
import Observation

/// One settled caption line as the recogniser produced it.
public struct TranscriptLine: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Exactly what the recogniser wrote; correction rules are applied on display.
    public let heard: String
    /// A whole-line fix typed by the user; wins over rules when present.
    public var edited: String?
    public let time: Date
    /// Where the line lies in the session's recording, when there is one.
    public let audio: AudioSpan?
    /// How sure the recogniser was; nil in lines saved before this was kept.
    public let score: LineScore?

    public init(id: UUID = UUID(), heard: String, edited: String? = nil, time: Date, audio: AudioSpan?,
                score: LineScore? = nil) {
        self.id = id
        self.heard = heard
        self.edited = edited
        self.time = time
        self.audio = audio
        self.score = score
    }
}

/// A conversation: one call, or one stretch of captioning.
public struct TranscriptSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: String
    public let sourceTitle: String
    /// The caption language (`CaptionLanguageOption.id`); nil in sessions
    /// saved before Tamil captions existed, which were all English.
    public let languageID: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var lines: [TranscriptLine]
    /// File name of the audio recording in the recordings folder, if any.
    /// Several sessions may share one recording; `TranscriptLine.audio` spans
    /// are positions within it.
    public var recordingFile: String?

    public init(id: UUID = UUID(), sourceID: String, sourceTitle: String, languageID: String? = nil, startedAt: Date,
                endedAt: Date? = nil, lines: [TranscriptLine] = [], recordingFile: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.languageID = languageID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lines = lines
        self.recordingFile = recordingFile
    }
}

/// Where the engine sends settled lines. CaptionSession depends on this, not
/// on TranscriptLibrary, so storage can change without touching the engine.
@MainActor
public protocol TranscriptSink: AnyObject {
    func beginSession(sourceID: String, sourceTitle: String, languageID: String?, recordingFile: String?, at time: Date) -> TranscriptSession.ID
    func appendLine(_ heard: String, audio: AudioSpan?, score: LineScore?, at time: Date, to session: TranscriptSession.ID)
    func endSession(_ session: TranscriptSession.ID, at time: Date)
}

/// Saved transcripts, one JSON file per session, plus the recordings they
/// refer to. Everything stays in folders on this device.
@MainActor
@Observable
public final class TranscriptLibrary: TranscriptSink {
    /// Newest first.
    public private(set) var sessions: [TranscriptSession] = []

    @ObservationIgnored public let transcriptsFolder: URL
    @ObservationIgnored public let recordingsFolder: URL

    public init(transcriptsFolder: URL, recordingsFolder: URL) {
        self.transcriptsFolder = transcriptsFolder
        self.recordingsFolder = recordingsFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: transcriptsFolder, includingPropertiesForKeys: nil)) ?? []
        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.transcripts.decode(TranscriptSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func recordingURL(for session: TranscriptSession) -> URL? {
        session.recordingFile.map { recordingsFolder.appendingPathComponent($0) }
    }

    // MARK: TranscriptSink

    public func beginSession(sourceID: String, sourceTitle: String, languageID: String?, recordingFile: String?, at time: Date) -> TranscriptSession.ID {
        let session = TranscriptSession(sourceID: sourceID, sourceTitle: sourceTitle, languageID: languageID,
                                        startedAt: time, recordingFile: recordingFile)
        sessions.insert(session, at: 0)
        save(session)
        return session.id
    }

    public func appendLine(_ heard: String, audio: AudioSpan?, score: LineScore? = nil, at time: Date,
                           to sessionID: TranscriptSession.ID) {
        mutate(sessionID) { $0.lines.append(TranscriptLine(heard: heard, time: time, audio: audio, score: score)) }
    }

    public func endSession(_ sessionID: TranscriptSession.ID, at time: Date) {
        mutate(sessionID) { $0.endedAt = time }
    }

    // MARK: Editing

    /// Sets (or with nil, clears) the user's own wording for one line.
    public func setEdited(_ text: String?, line lineID: TranscriptLine.ID, in sessionID: TranscriptSession.ID) {
        mutate(sessionID) { session in
            guard let index = session.lines.firstIndex(where: { $0.id == lineID }) else { return }
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.lines[index].edited = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public func delete(_ sessionID: TranscriptSession.ID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        sessions.removeAll { $0.id == sessionID }
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        removeRecordingIfUnused(session.recordingFile)
    }

    public func deleteAll() {
        for session in sessions { delete(session.id) }
    }

    /// Deletes sessions (and recordings no longer referenced) that ended
    /// before `cutoff`. Returns how many sessions were removed.
    @discardableResult
    public func deleteSessions(endedBefore cutoff: Date) -> Int {
        let old = sessions.filter { ($0.endedAt ?? $0.startedAt) < cutoff }
        for session in old { delete(session.id) }
        return old.count
    }

    // MARK: Private

    private func mutate(_ sessionID: TranscriptSession.ID, _ change: (inout TranscriptSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        change(&sessions[index])
        save(sessions[index])
    }

    private func fileURL(for sessionID: TranscriptSession.ID) -> URL {
        transcriptsFolder.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func save(_ session: TranscriptSession) {
        do {
            try FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
            try JSONEncoder.transcripts.encode(session).write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            Diagnostics.engine.error("could not save transcript: \(String(describing: error), privacy: .public)")
        }
    }

    private func removeRecordingIfUnused(_ file: String?) {
        guard let file, !sessions.contains(where: { $0.recordingFile == file }) else { return }
        try? FileManager.default.removeItem(at: recordingsFolder.appendingPathComponent(file))
    }
}

extension TranscriptLine {
    /// What to show: the user's own wording, else the recogniser's text with
    /// correction rules applied.
    public func displayText(using corrector: TextCorrector) -> String {
        edited ?? corrector.apply(to: heard)
    }
}

private extension JSONEncoder {
    static let transcripts: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let transcripts: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
