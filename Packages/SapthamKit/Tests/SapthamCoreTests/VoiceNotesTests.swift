@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SapthamCore

@MainActor
struct VoiceNotesTests {
    /// Counts the audio it is given, then emits a fixed script.
    final class CountingTranscriber: SpeechTranscribing, @unchecked Sendable {
        let updates: [TranscriptUpdate]
        private(set) var frames: AVAudioFrameCount = 0
        init(_ updates: [TranscriptUpdate]) { self.updates = updates }
        func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for await buffer in audio { self.frames += buffer.frameLength }
                    for update in self.updates { continuation.yield(update) }
                    continuation.finish()
                }
            }
        }
    }

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-voicenotes-\(UUID())")

    /// A 3 s tone, written as a .caf file.
    private func makeNote(named name: String = "note.caf", seconds: Double = 3) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = sin(Float(index) * 0.1) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    private func makeLibrary() -> TranscriptLibrary {
        TranscriptLibrary(transcriptsFolder: folder.appendingPathComponent("T"),
                          recordingsFolder: folder.appendingPathComponent("R"))
    }

    private func waitUntilDone(_ notes: VoiceNotes) async throws {
        for _ in 0..<100 where notes.jobs.contains(where: { $0.status == .transcribing }) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func savesLinesAtTheirPlaceInTheNote() async throws {
        let library = makeLibrary()
        let transcriber = CountingTranscriber([
            .volatile("vanakkam"),
            .final("வணக்கம்", audio: AudioSpan(start: 0.2, end: 1.0), score: LineScore(confidence: 0.8, recogniser: "Tamil")),
            .final("See you at four.", audio: AudioSpan(start: 1.5, end: 2.8)),
        ])
        var askedLanguage: String?
        let notes = VoiceNotes(recordingsFolder: library.recordingsFolder, transcripts: library,
                               languageID: { "ta+en" },
                               makeTranscriber: { askedLanguage = $0; return transcriber })

        let id = try notes.transcribe(try makeNote())
        try await waitUntilDone(notes)

        #expect(askedLanguage == "ta+en")
        #expect(notes.jobs.first?.status == .done)
        #expect(transcriber.frames == 48_000)
        let session = try #require(library.sessions.first { $0.id == id })
        #expect(session.sourceID == VoiceNotes.sourceID)
        #expect(session.sourceTitle == "Voice note: note")
        #expect(session.lines.map(\.heard) == ["வணக்கம்", "See you at four."])
        #expect(session.lines[0].score?.recogniser == "Tamil")
        #expect(session.lines[1].time.timeIntervalSince(session.startedAt) == 1.5)
        #expect(session.endedAt.map { $0.timeIntervalSince(session.startedAt) } == 3)
        // Played back from its own copy, which goes with the transcript.
        let copy = try #require(library.recordingURL(for: session))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        library.delete(id)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func refusesAFileThatIsNotAudio() throws {
        let library = makeLibrary()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = folder.appendingPathComponent("message.opus")
        try Data("not audio".utf8).write(to: text)
        let notes = VoiceNotes(recordingsFolder: library.recordingsFolder, transcripts: library,
                               languageID: { "en" }, makeTranscriber: { _ in CountingTranscriber([]) })

        #expect(throws: SapthamError.self) { try notes.transcribe(text) }
        #expect(library.sessions.isEmpty)
        #expect(notes.jobs.isEmpty)
    }

    @Test func aFailingRecogniserIsReported() async throws {
        final class Failing: SpeechTranscribing {
            func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
                AsyncThrowingStream { $0.finish(throwing: SapthamError("model missing")) }
            }
        }
        let library = makeLibrary()
        let notes = VoiceNotes(recordingsFolder: library.recordingsFolder, transcripts: library,
                               languageID: { "ta" }, makeTranscriber: { _ in Failing() })

        let id = try notes.transcribe(try makeNote())
        try await waitUntilDone(notes)

        #expect(notes.jobs.first?.status == .failed("model missing"))
        #expect(library.sessions.first { $0.id == id }?.endedAt != nil)
    }
}
