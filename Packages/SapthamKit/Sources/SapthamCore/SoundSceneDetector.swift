@preconcurrency import AVFoundation
import SoundAnalysis

/// Tells music and singing from speech with Apple's built-in sound
/// classifier (SoundAnalysis). Runs on this device; no audio leaves it, and
/// nothing beyond the operating system is needed.
public final class SoundSceneDetector: SoundSceneDetecting {
    /// Seconds of audio per classification. The classifier accepts 0.5–15 s;
    /// 1.5 s with half overlap gives a score about every 0.75 s.
    public var windowSeconds = 1.5
    public var judge = SoundSceneJudge()

    public init() {}

    public func scenes(in audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<SoundScene> {
        let (scenes, output) = AsyncStream<SoundScene>.makeStream()
        let windowSeconds = self.windowSeconds
        let observer = Observer(judge: judge, output: output)
        let task = Task.detached {
            var analyzer: SNAudioStreamAnalyzer?
            var format: AVAudioFormat?
            var position: AVAudioFramePosition = 0
            for await buffer in audio {
                // A source may change format mid-stream (a device switch);
                // the analyser only accepts the format it was made with.
                if format != buffer.format {
                    analyzer?.completeAnalysis()
                    analyzer = Self.makeAnalyzer(format: buffer.format, windowSeconds: windowSeconds, observer: observer)
                    format = buffer.format
                    position = 0
                }
                analyzer?.analyze(buffer, atAudioFramePosition: position)
                position += AVAudioFramePosition(buffer.frameLength)
            }
            analyzer?.completeAnalysis()
            output.finish()
        }
        output.onTermination = { _ in task.cancel() }
        return scenes
    }

    private static func makeAnalyzer(format: AVAudioFormat, windowSeconds: Double,
                                     observer: Observer) -> SNAudioStreamAnalyzer? {
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 16_000)
            request.overlapFactor = 0.5
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            return analyzer
        } catch {
            // Captions still work without it; only the music notice is lost.
            Diagnostics.engine.error("sound classifier unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Receives classifier results. The analyser calls it from the thread
    /// that called `analyze`, which is always the one detached task above,
    /// so the judge is never touched from two threads at once.
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private var judge: SoundSceneJudge
        private let output: AsyncStream<SoundScene>.Continuation

        init(judge: SoundSceneJudge, output: AsyncStream<SoundScene>.Continuation) {
            self.judge = judge
            self.output = output
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func score(_ labels: String...) -> Double { score(labels) }
            func score(_ labels: [String]) -> Double {
                labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
            }
            let scores = SoundSceneJudge.Scores(
                speech: score("speech"),
                // On Indian film songs the classifier is often surer of the
                // instrument (tabla 0.95) than of "music" itself.
                music: score(["music"] + Self.instruments),
                singing: score("singing", "choir_singing", "rapping", "humming", "yodeling"))
            // Every window, at debug level (not stored; read with `log stream --level debug`),
            // so thresholds can be tuned against real songs.
            let top = result.classifications.prefix(4)
                .map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }
                .joined(separator: ", ")
            Diagnostics.engine.debug("sound window: speech \(scores.speech, format: .fixed(precision: 2)), music \(scores.music, format: .fixed(precision: 2)), singing \(scores.singing, format: .fixed(precision: 2)); top: \(top, privacy: .public)")
            if let scene = judge.add(scores) {
                Diagnostics.engine.info("sound scene: \(String(describing: scene), privacy: .public) (speech \(scores.speech, format: .fixed(precision: 2)), music \(scores.music, format: .fixed(precision: 2)), singing \(scores.singing, format: .fixed(precision: 2)))")
                output.yield(scene)
            }
        }

        /// Built-in classifier labels that are musical instruments.
        static let instruments = [
            "tabla", "sitar", "mandolin", "flute", "violin_fiddle",
            "percussion", "drum", "drum_kit", "plucked_string_instrument",
            "bowed_string_instrument", "keyboard_musical", "synthesizer",
            "piano", "guitar", "acoustic_guitar", "electric_guitar",
            "tambourine", "mallet_percussion",
        ]

        func request(_ request: SNRequest, didFailWithError error: Error) {
            Diagnostics.engine.error("sound classifier failed: \(String(describing: error), privacy: .public)")
        }
    }
}
