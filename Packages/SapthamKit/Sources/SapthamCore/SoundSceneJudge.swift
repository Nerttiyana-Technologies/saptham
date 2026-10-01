/// Turns a sound classifier's scores, one analysis window at a time, into a
/// steady SoundScene. Classifier scores jump around from window to window;
/// without hysteresis the "music" notice would flicker on every drum fill
/// and every pause between lines of a song.
///
/// - Each window votes: `singing` when its singing score is high, `music`
///   when music is high and speech is low, otherwise `speech`.
/// - Staying in a scene needs a lower score than entering it, so a song's
///   quieter bars do not count as leaving it.
/// - Once in music, an unsure window is NOT a vote for speech. The built-in
///   classifier was not trained on Indian film singing: on a Tamil song it
///   scores speech, music and singing all low and calls the voice a duck,
///   a sheep or a ringtone. So a song leaves only on clear speech
///   (`speechToLeave`, steady, as real talking scores ~0.9), or after
///   `windowsWithoutMusicToLeave` windows with no musical sign at all.
/// - A scene changes only after the same vote `windowsToEnter` times in a
///   row (music or singing) or `windowsToLeave` times (back to speech).
///   Leaving is slower: hiding captions for a moment of real speech costs
///   less than filling the screen with guesses for every bar of a song.
///
/// Pure logic over scores, so it can be tested without audio.
public struct SoundSceneJudge {
    /// One window's scores, 0 … 1 each, as the classifier reports them.
    public struct Scores: Equatable, Sendable {
        public var speech: Double
        public var music: Double
        public var singing: Double

        public init(speech: Double = 0, music: Double = 0, singing: Double = 0) {
            self.speech = speech
            self.music = music
            self.singing = singing
        }
    }

    public var singingToEnter = 0.5
    public var singingToStay = 0.3
    public var musicToEnter = 0.6
    public var musicToStay = 0.4
    /// Music with speech scoring at least this is treated as talking over
    /// music (a film scene, a podcast), which should still be captioned.
    public var speechOverMusic = 0.5
    /// While in music, a window counts as talking only at this speech
    /// score and above the music score.
    public var speechToLeave = 0.6
    public var windowsToEnter = 2
    public var windowsToLeave = 4
    /// About 15 s with no musical sign at all also ends a song, so quiet
    /// talking that never scores as clear speech is not hidden for long.
    public var windowsWithoutMusicToLeave = 20

    public private(set) var scene: SoundScene = .speech

    private var candidate: SoundScene = .speech
    private var candidateRun = 0
    private var windowsWithoutMusic = 0

    public init() {}

    /// Adds one window's scores. Returns the new scene when it changes,
    /// otherwise nil.
    public mutating func add(_ scores: Scores) -> SoundScene? {
        if scene.isMusical {
            let musicalSign = scores.music >= musicToStay || scores.singing >= singingToStay
            windowsWithoutMusic = musicalSign ? 0 : windowsWithoutMusic + 1
            if windowsWithoutMusic >= windowsWithoutMusicToLeave {
                return change(to: .speech)
            }
        }
        let vote = self.vote(scores)
        if vote == scene {
            candidateRun = 0
            return nil
        }
        if vote == candidate {
            candidateRun += 1
        } else {
            candidate = vote
            candidateRun = 1
        }
        guard candidateRun >= (vote.isMusical ? windowsToEnter : windowsToLeave) else { return nil }
        return change(to: vote)
    }

    private mutating func change(to newScene: SoundScene) -> SoundScene {
        scene = newScene
        candidate = newScene
        candidateRun = 0
        windowsWithoutMusic = 0
        return newScene
    }

    private func vote(_ scores: Scores) -> SoundScene {
        let singing = scene == .singing ? singingToStay : singingToEnter
        let music = scene.isMusical ? musicToStay : musicToEnter
        if scores.singing >= singing { return .singing }
        if scores.music >= music && scores.speech < speechOverMusic { return .music }
        if scene.isMusical {
            let clearSpeech = scores.speech >= speechToLeave && scores.speech > scores.music
            return clearSpeech ? .speech : scene
        }
        return .speech
    }
}
