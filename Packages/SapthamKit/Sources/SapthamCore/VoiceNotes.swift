@preconcurrency import AVFoundation
import Observation

/// Turns saved audio files (voice messages from a chat app, any recording)
/// into transcripts, with the same recognisers as live captions.
///
/// Knows nothing about windows or live captioning. Collaborators, all
/// injected by the app:
/// - `transcripts` receives the lines, as one session per file.
/// - `languageID` says which caption language to use when a file arrives.
/// - `makeTranscriber` builds a fresh recogniser for that language.
///
/// The file is copied into `recordingsFolder` and named as the session's
/// recording, so each line can be played back and the copy goes when the
/// transcript is deleted.
@MainActor
@Observable
public final class VoiceNotes {
    public static let sourceID = "voiceNote"

    public enum Status: Equatable, Sendable {
        case transcribing
        case done
        case failed(String)
    }

    public struct Job: Identifiable, Equatable, Sendable {
        public let id: TranscriptSession.ID
        public let fileName: String
        public var status: Status
    }

    /// Newest first.
    public private(set) var jobs: [Job] = []

    @ObservationIgnored private let recordingsFolder: URL
    @ObservationIgnored private weak var transcripts: TranscriptSink?
    @ObservationIgnored private let languageID: () -> String
    @ObservationIgnored private let makeTranscriber: (String) -> SpeechTranscribing

    public init(recordingsFolder: URL,
                transcripts: TranscriptSink,
                languageID: @escaping () -> String,
                makeTranscriber: @escaping (String) -> SpeechTranscribing) {
        self.recordingsFolder = recordingsFolder
        self.transcripts = transcripts
        self.languageID = languageID
        self.makeTranscriber = makeTranscriber
    }

    /// Starts transcribing `file` and returns its transcript session at once,
    /// so a window can show the lines as they arrive. Throws when the file is
    /// not audio this device can read; nothing is saved then.
    @discardableResult
    public func transcribe(_ file: URL) throws -> TranscriptSession.ID {
        guard let transcripts else { throw SapthamError("Transcripts are not available.") }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        // Opening it first rejects files that are not audio before anything is saved.
        let duration: Double
        do {
            let audio = try AVAudioFile(forReading: file)
            duration = Double(audio.length) / audio.processingFormat.sampleRate
        } catch {
            throw SapthamError("“\(file.lastPathComponent)” is not a sound file Saptham can read.")
        }
        let copyName = "voicenote-\(Self.fileStamp.string(from: Date()))-\(UUID().uuidString.prefix(4)).\(file.pathExtension.lowercased())"
        let copy = recordingsFolder.appendingPathComponent(copyName)
        do {
            try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            throw SapthamError("Could not copy “\(file.lastPathComponent)”: \(error.localizedDescription)")
        }

        let name = file.deletingPathExtension().lastPathComponent
        let language = languageID()
        let startedAt = Date()
        let sessionID = transcripts.beginSession(sourceID: Self.sourceID, sourceTitle: "Voice note: \(name)",
                                                 languageID: language, recordingFile: copyName, at: startedAt)
        jobs.insert(Job(id: sessionID, fileName: file.lastPathComponent, status: .transcribing), at: 0)
        Diagnostics.engine.info("voice note: transcribing \(String(format: "%.1f", duration), privacy: .public) s in \(language, privacy: .public)")

        let transcriber = makeTranscriber(language)
        Task { @MainActor [weak self] in
            var status = Status.done
            do {
                let audio = try Self.buffers(of: copy)
                for try await update in transcriber.transcribe(audio) {
                    // Live partials have no use here: only settled lines are kept.
                    guard case .final(let text, let span, let score) = update,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    // A line's time is where it is in the note, so times read as offsets from its start.
                    let time = startedAt.addingTimeInterval(span?.start ?? 0)
                    self?.transcripts?.appendLine(text, audio: span, score: score, at: time, to: sessionID)
                }
            } catch {
                Diagnostics.engine.error("voice note failed: \(String(describing: error), privacy: .public)")
                status = .failed(error.localizedDescription)
            }
            self?.transcripts?.endSession(sessionID, at: startedAt.addingTimeInterval(duration))
            self?.setStatus(status, of: sessionID)
        }
        return sessionID
    }

    private func setStatus(_ status: Status, of id: TranscriptSession.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
    }

    /// The whole file as half-second buffers, as fast as it can be read.
    /// Nothing is dropped: the stream holds the decoded note until the
    /// recogniser takes it (about 11 MB a minute at 48 kHz mono).
    nonisolated static func buffers(of url: URL) throws -> AsyncStream<AVAudioPCMBuffer> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 2)
        let (stream, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let reader = Task.detached {
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil,
                      buffer.frameLength > 0 else { break }
                feed.yield(buffer)
            }
            feed.finish()
        }
        feed.onTermination = { _ in reader.cancel() }
        return stream
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
