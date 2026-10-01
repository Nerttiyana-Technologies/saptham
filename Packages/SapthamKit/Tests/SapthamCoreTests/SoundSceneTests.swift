import Testing
@testable import SapthamCore

struct SoundSceneJudgeTests {
    private let talking = SoundSceneJudge.Scores(speech: 0.9, music: 0.1)
    private let song = SoundSceneJudge.Scores(speech: 0.2, music: 0.9, singing: 0.8)
    private let band = SoundSceneJudge.Scores(speech: 0.1, music: 0.9)

    private func run(_ judge: inout SoundSceneJudge, _ windows: [SoundSceneJudge.Scores]) -> [SoundScene?] {
        windows.map { judge.add($0) }
    }

    @Test func startsAsSpeechAndStaysThereForTalking() {
        var judge = SoundSceneJudge()
        #expect(run(&judge, Array(repeating: talking, count: 5)).allSatisfy { $0 == nil })
        #expect(judge.scene == .speech)
    }

    @Test func singingNeedsTwoWindowsInARow() {
        var judge = SoundSceneJudge()
        #expect(run(&judge, [song, talking, song]) == [nil, nil, nil])
        #expect(judge.add(song) == .singing)
    }

    @Test func instrumentalMusicIsMusic() {
        var judge = SoundSceneJudge()
        #expect(run(&judge, [band, band]) == [nil, .music])
    }

    @Test func talkingOverMusicIsStillSpeech() {
        var judge = SoundSceneJudge()
        let film = SoundSceneJudge.Scores(speech: 0.7, music: 0.8)
        #expect(run(&judge, Array(repeating: film, count: 5)).allSatisfy { $0 == nil })
    }

    @Test func aQuieterBarDoesNotLeaveTheSong() {
        var judge = SoundSceneJudge()
        _ = run(&judge, [song, song])
        let quieter = SoundSceneJudge.Scores(speech: 0.3, music: 0.6, singing: 0.35)
        #expect(run(&judge, Array(repeating: quieter, count: 6)).allSatisfy { $0 == nil })
        #expect(judge.scene == .singing)
    }

    @Test func leavingTakesFourWindowsOfTalking() {
        var judge = SoundSceneJudge()
        _ = run(&judge, [song, song])
        #expect(run(&judge, [talking, talking, talking, song, talking, talking, talking]) == [nil, nil, nil, nil, nil, nil, nil])
        #expect(judge.add(talking) == .speech)
    }

    /// Scores like those a Tamil film song gave: the classifier is unsure
    /// of everything once the voice comes in.
    @Test func anUnsureSongDoesNotLeaveMusic() {
        var judge = SoundSceneJudge()
        _ = run(&judge, [band, band])
        let unsure = SoundSceneJudge.Scores(speech: 0.52, music: 0.32, singing: 0.08)
        let mixed: [SoundSceneJudge.Scores] = [
            .init(speech: 0.07, music: 0.26), unsure, .init(speech: 0.10, music: 0.15),
            .init(speech: 0.68, music: 0.37), .init(speech: 0.12, music: 0.45), unsure,
        ]
        #expect(run(&judge, mixed + mixed).allSatisfy { $0 == nil })
        #expect(judge.scene == .music)
    }

    @Test func aLongStretchWithNoMusicEndsTheSong() {
        var judge = SoundSceneJudge()
        _ = run(&judge, [band, band])
        let quietTalk = SoundSceneJudge.Scores(speech: 0.4, music: 0.1)
        let results = run(&judge, Array(repeating: quietTalk, count: 20))
        #expect(results.dropLast().allSatisfy { $0 == nil })
        #expect(results.last == .speech)
    }
}

@MainActor
struct CaptionFeedSoundSceneTests {
    private let unclear = TranscriptUpdate.unclearText

    @Test func unclearLinesAreHiddenDuringMusic() {
        let feed = CaptionFeed()
        feed.setState(.listening)
        feed.setSoundScene(.singing)
        feed.apply(.volatile(unclear))
        #expect(feed.partial.isEmpty)
        feed.apply(.final(unclear))
        feed.apply(.final("clear words"))
        #expect(feed.lines.map(\.text) == ["clear words"])
    }

    @Test func unclearLinesAreShownForSpeech() {
        let feed = CaptionFeed()
        feed.setState(.listening)
        feed.apply(.final(unclear))
        #expect(feed.lines.map(\.text) == [unclear])
    }

    @Test func musicStartingTakesBackRecentUnclearLines() {
        let feed = CaptionFeed()
        feed.setState(.listening)
        for text in [unclear, "hello", unclear, unclear] { feed.apply(.final(text)) }
        feed.setSoundScene(.music)
        #expect(feed.lines.map(\.text) == [unclear, "hello"])
    }

    @Test func stoppingClearsTheSceneAndIgnoresLateVerdicts() {
        let feed = CaptionFeed()
        feed.setState(.listening)
        feed.setSoundScene(.singing)
        feed.setState(.idle)
        #expect(feed.soundScene == .speech)
        feed.setSoundScene(.music)
        #expect(feed.soundScene == .speech)
    }
}
