import Foundation
import Testing
@testable import SapthamCore

struct TextCorrectorTests {
    private func corrector(_ pairs: [(String, String)]) -> TextCorrector {
        TextCorrector(rules: pairs.map { CorrectionRule(heard: $0.0, replacement: $0.1) })
    }

    @Test func replacesWholeWordsCaseInsensitively() {
        let fix = corrector([("sabtham", "Saptham")])
        #expect(fix.apply(to: "Sabtham shows live captions.") == "Saptham shows live captions.")
        #expect(fix.apply(to: "I use SABTHAM daily") == "I use Saptham daily")
    }

    @Test func neverChangesPartOfAWord() {
        let fix = corrector([("cat", "dog")])
        #expect(fix.apply(to: "The category of cat.") == "The category of dog.")
    }

    @Test func treatsTamilVowelSignsAsPartOfTheWord() {
        let fix = corrector([("கட", "கடல்"), ("சென்னை", "Chennai")])
        #expect(fix.apply(to: "கடை திறந்திருக்கு") == "கடை திறந்திருக்கு")
        #expect(fix.apply(to: "கட பக்கத்துல") == "கடல் பக்கத்துல")
        #expect(fix.apply(to: "சென்னைக்கு போறேன், சென்னை.") == "சென்னைக்கு போறேன், Chennai.")
    }

    @Test func picksWholeTamilWordsForCorrecting() {
        let text = "என்னடா, எப்படி இருக்க? Don't worry"
        let words = CaptionWords.ranges(in: text).map { (text as NSString).substring(with: $0) }
        #expect(words == ["என்னடா", "எப்படி", "இருக்க", "Don't", "worry"])
        // A picked word, saved as a rule, matches where it was picked.
        let fix = corrector([(words[0], "என்ன")])
        #expect(fix.apply(to: text) == "என்ன, எப்படி இருக்க? Don't worry")
    }

    @Test func matchesPhrasesAcrossExtraSpaces() {
        let fix = corrector([("butt theories", "batteries")])
        #expect(fix.apply(to: "Bring the spare butt  theories, please.") == "Bring the spare batteries, please.")
    }

    @Test func longestPhraseWins() {
        let fix = corrector([("butt", "but"), ("butt theories", "batteries")])
        #expect(fix.apply(to: "spare butt theories") == "spare batteries")
    }

    @Test func keepsSentenceInitialCapital() {
        let fix = corrector([("caffeine", "captioning")])
        #expect(fix.apply(to: "Caffeine is on.") == "Captioning is on.")
        #expect(fix.apply(to: "live caffeine works") == "live captioning works")
    }

    @Test func handlesPunctuationAndRegexCharacters() {
        let fix = corrector([("Rs.", "₹"), ("c++", "C++")])
        #expect(fix.apply(to: "It costs Rs. 500 in c++.") == "It costs ₹ 500 in C++.")
    }
}

@MainActor
struct CorrectionBookTests {
    @Test func rulesPersistAndSameHeardUpdates() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let book = CorrectionBook(fileURL: file)
        book.add(heard: "Chen Li", replacement: "Chennai")
        book.add(heard: "chen li", replacement: "Chennai branch")
        #expect(book.rules.count == 1)
        #expect(book.apply(to: "sent to Chen Li today") == "sent to Chennai branch today")

        let reopened = CorrectionBook(fileURL: file)
        #expect(reopened.rules.map(\.replacement) == ["Chennai branch"])
        reopened.remove(reopened.rules[0].id)
        #expect(CorrectionBook(fileURL: file).rules.isEmpty)
    }
}

@MainActor
struct TranscriptLibraryTests {
    private func makeFolders() -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID())")
        return (root.appendingPathComponent("Transcripts"), root.appendingPathComponent("Recordings"))
    }

    @Test func sessionsPersistAndDisplayUsesCorrections() {
        let (transcripts, recordings) = makeFolders()
        defer { try? FileManager.default.removeItem(at: transcripts.deletingLastPathComponent()) }

        let library = TranscriptLibrary(transcriptsFolder: transcripts, recordingsFolder: recordings)
        let id = library.beginSession(sourceID: "calls", sourceTitle: "Phone calls", languageID: "en", recordingFile: nil, at: Date())
        library.appendLine("Sabtham works", audio: AudioSpan(start: 1, end: 2), at: Date(), to: id)
        library.endSession(id, at: Date())

        let reopened = TranscriptLibrary(transcriptsFolder: transcripts, recordingsFolder: recordings)
        let line = try! #require(reopened.sessions.first?.lines.first)
        #expect(line.audio == AudioSpan(start: 1, end: 2))
        let fix = TextCorrector(rules: [CorrectionRule(heard: "Sabtham", replacement: "Saptham")])
        #expect(line.displayText(using: fix) == "Saptham works")

        reopened.setEdited("Saptham works well", line: line.id, in: id)
        #expect(reopened.sessions[0].lines[0].displayText(using: fix) == "Saptham works well")
    }

    @Test func deletingOldSessionsRemovesUnusedRecordings() throws {
        let (transcripts, recordings) = makeFolders()
        defer { try? FileManager.default.removeItem(at: transcripts.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let audio = recordings.appendingPathComponent("call.m4a")
        try Data([1, 2, 3]).write(to: audio)

        let library = TranscriptLibrary(transcriptsFolder: transcripts, recordingsFolder: recordings)
        let old = library.beginSession(sourceID: "calls", sourceTitle: "Phone calls", languageID: "en", recordingFile: "call.m4a",
                                       at: Date(timeIntervalSinceNow: -40 * 86_400))
        library.endSession(old, at: Date(timeIntervalSinceNow: -40 * 86_400))
        let recent = library.beginSession(sourceID: "calls", sourceTitle: "Phone calls", languageID: "en", recordingFile: "call.m4a", at: Date())

        #expect(library.deleteSessions(endedBefore: Date(timeIntervalSinceNow: -30 * 86_400)) == 1)
        #expect(FileManager.default.fileExists(atPath: audio.path))   // still used by `recent`
        library.delete(recent)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }
}

@MainActor
struct CaptionSessionTranscriptTests {
    /// Emits a fixed script of updates, ignoring audio.
    final class ScriptedTranscriber: SpeechTranscribing {
        let updates: [TranscriptUpdate]
        init(_ updates: [TranscriptUpdate]) { self.updates = updates }
        func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
            AsyncThrowingStream { continuation in
                for update in updates { continuation.yield(update) }
                continuation.finish()
            }
        }
    }

    final class SilentSource: AudioSource {
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> { AsyncStream { $0.finish() } }
        func stop() {}
    }

    @Test func correctsShownTextButSavesWhatWasHeard() async throws {
        let (transcripts, recordings) = (FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID())/T"),
                                         FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID())/R"))
        let library = TranscriptLibrary(transcriptsFolder: transcripts, recordingsFolder: recordings)
        let fix = TextCorrector(rules: [CorrectionRule(heard: "caffeine", replacement: "captioning")])
        let session = CaptionSession(
            sources: [CaptionSourceOption(id: "calls", title: "Phone calls", detail: "", systemImage: "phone")],
            languages: [CaptionLanguageOption(id: "en", title: "English", nativeTitle: "English")],
            makeSource: { _ in SilentSource() },
            makeTranscriber: { _ in ScriptedTranscriber([.volatile("live caffeine"), .final("Live caffeine works.")]) },
            transcripts: library,
            correctText: fix.apply(to:))

        session.start("calls")
        for _ in 0..<50 where session.activeSourceID != nil { try await Task.sleep(for: .milliseconds(20)) }

        #expect(session.feed.lines.map(\.text) == ["Live captioning works."])
        #expect(library.sessions.first?.lines.map(\.heard) == ["Live caffeine works."])
        #expect(library.sessions.first?.endedAt != nil)
    }

    @Test func captionsInTheChosenLanguageAndSavesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID())")
        let library = TranscriptLibrary(transcriptsFolder: folder.appendingPathComponent("T"),
                                        recordingsFolder: folder.appendingPathComponent("R"))
        var saved: [String] = []
        let session = CaptionSession(
            sources: [CaptionSourceOption(id: "mic", title: "Conversation", detail: "", systemImage: "mic")],
            languages: [CaptionLanguageOption(id: "en", title: "English", nativeTitle: "English"),
                        CaptionLanguageOption(id: "ta", title: "Tamil", nativeTitle: "தமிழ்")],
            languageID: "unknown",
            makeSource: { _ in SilentSource() },
            makeTranscriber: { language in ScriptedTranscriber([.final(language == "ta" ? "வணக்கம்" : "Hello")]) },
            languageChanged: { saved.append($0) },
            transcripts: library)

        #expect(session.activeLanguageID == "en")
        session.setLanguage("ta")
        session.setLanguage("fr")   // not offered: ignored
        #expect(session.activeLanguageID == "ta")
        #expect(saved == ["ta"])

        session.start("mic")
        for _ in 0..<50 where session.activeSourceID != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.feed.lines.map(\.text) == ["வணக்கம்"])
        #expect(library.sessions.first?.languageID == "ta")
    }
}

import AVFoundation

struct FileAudioRecorderTests {
    @Test func writesPlayableMonoAudioOfTheRightLength() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saptham-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = FileAudioRecorder(folder: folder, fileName: "test.m4a")

        // 2 s of a 440 Hz tone, delivered like the call tap: 48 kHz stereo interleaved, 10 ms buffers.
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        for block in 0..<200 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<480 {
                let value = Float(sin(2 * Double.pi * 440 * Double(block * 480 + frame) / 48_000)) * 0.5
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            recorder.write(buffer)
        }
        recorder.finish()

        let file = try AVAudioFile(forReading: folder.appendingPathComponent("test.m4a"))
        #expect(file.fileFormat.channelCount == 1)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 2) < 0.1)
    }
}
