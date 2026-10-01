@preconcurrency import AVFoundation

/// Tells music and singing from speech with Apple's built-in sound
/// classifier (see SoundClassifier).
public final class SoundSceneDetector: SoundSceneDetecting {
    /// 1.5 s windows with half overlap give a score about every 0.75 s.
    public var classifier = SoundClassifier(windowSeconds: 1.5)
    public var judge = SoundSceneJudge()

    public init() {}

    /// Built-in classifier labels that are musical instruments. On Indian
    /// film songs the classifier is often surer of the instrument
    /// (tabla 0.95) than of "music" itself.
    static let instruments = [
        "tabla", "sitar", "mandolin", "flute", "violin_fiddle",
        "percussion", "drum", "drum_kit", "plucked_string_instrument",
        "bowed_string_instrument", "keyboard_musical", "synthesizer",
        "piano", "guitar", "acoustic_guitar", "electric_guitar",
        "tambourine", "mallet_percussion",
    ]

    public func scenes(in audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<SoundScene> {
        let windows = classifier.windows(of: audio)
        let initialJudge = judge
        return AsyncStream { output in
            let task = Task.detached {
                var judge = initialJudge
                for await window in windows {
                    let scores = SoundSceneJudge.Scores(
                        speech: window.highest(of: ["speech"]),
                        music: window.highest(of: ["music"] + Self.instruments),
                        singing: window.highest(of: ["singing", "choir_singing", "rapping", "humming", "yodeling"]))
                    // Every window, at debug level (not stored; read with `log stream --level debug`),
                    // so thresholds can be tuned against real songs.
                    Diagnostics.engine.debug("sound window: speech \(scores.speech, format: .fixed(precision: 2)), music \(scores.music, format: .fixed(precision: 2)), singing \(scores.singing, format: .fixed(precision: 2)); top: \(window.top(4), privacy: .public)")
                    if let scene = judge.add(scores) {
                        Diagnostics.engine.info("sound scene: \(String(describing: scene), privacy: .public) (speech \(scores.speech, format: .fixed(precision: 2)), music \(scores.music, format: .fixed(precision: 2)), singing \(scores.singing, format: .fixed(precision: 2)))")
                        output.yield(scene)
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}
