@preconcurrency import AVFoundation
import SoundAnalysis

/// Apple's built-in sound classifier (SoundAnalysis, about 300 everyday
/// sounds) over a stream of audio. Runs on this device; no audio leaves it,
/// and nothing beyond the operating system is needed.
///
/// Yields one window's scores at a time, label → confidence (0 … 1), for
/// whoever interprets them: the music notice and sound alerts each run
/// their own copy on their own audio.
public struct SoundClassifier: Sendable {
    /// Seconds of audio per classification; the classifier accepts 0.5–15 s.
    public var windowSeconds: Double
    /// 0.5 gives a score every half window.
    public var overlap: Double

    public init(windowSeconds: Double, overlap: Double = 0.5) {
        self.windowSeconds = windowSeconds
        self.overlap = overlap
    }

    /// Every label the classifier knows.
    public static var knownLabels: [String] {
        (try? SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications) ?? []
    }

    /// Finishes after the audio stream finishes.
    public func windows(of audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<[String: Double]> {
        let (windows, output) = AsyncStream<[String: Double]>.makeStream()
        let observer = Observer(output: output)
        let settings = self
        let task = Task.detached {
            var analyzer: SNAudioStreamAnalyzer?
            var format: AVAudioFormat?
            var position: AVAudioFramePosition = 0
            for await buffer in audio {
                // A source may change format mid-stream (a device switch);
                // the analyser only accepts the format it was made with.
                if format != buffer.format {
                    analyzer?.completeAnalysis()
                    analyzer = settings.makeAnalyzer(format: buffer.format, observer: observer)
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
        return windows
    }

    private func makeAnalyzer(format: AVAudioFormat, observer: Observer) -> SNAudioStreamAnalyzer? {
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 16_000)
            request.overlapFactor = overlap
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            return analyzer
        } catch {
            // Callers carry on without scores: captions still work, only the
            // music notice or sound alerts are lost.
            Diagnostics.engine.error("sound classifier unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let output: AsyncStream<[String: Double]>.Continuation

        init(output: AsyncStream<[String: Double]>.Continuation) {
            self.output = output
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var scores: [String: Double] = [:]
            for classification in result.classifications { scores[classification.identifier] = classification.confidence }
            output.yield(scores)
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            Diagnostics.engine.error("sound classifier failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension Dictionary where Key == String, Value == Double {
    /// The highest score among `labels`, 0 when none scored.
    func highest(of labels: [String]) -> Double {
        labels.compactMap { self[$0] }.max() ?? 0
    }

    /// The `count` best labels, for logs: "tabla 0.95, music 0.84".
    func top(_ count: Int) -> String {
        sorted { $0.value > $1.value }.prefix(count)
            .map { "\($0.key) \(String(format: "%.2f", $0.value))" }
            .joined(separator: ", ")
    }
}
