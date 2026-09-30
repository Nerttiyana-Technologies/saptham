@preconcurrency import AVFoundation
import Observation

/// Joins one audio source to one transcriber and writes the result into a
/// CaptionFeed. Implements CaptionControlling so a UI can drive it without
/// knowing which sources or recogniser exist.
@MainActor
@Observable
public final class CaptionSession: CaptionControlling {
    public let feed: CaptionFeed
    public let sources: [CaptionSourceOption]
    public private(set) var activeSourceID: CaptionSourceOption.ID?

    @ObservationIgnored private let makeSource: (CaptionSourceOption.ID) -> AudioSource?
    @ObservationIgnored private let makeTranscriber: () -> SpeechTranscribing
    @ObservationIgnored private var running: (source: AudioSource, task: Task<Void, Never>)?

    /// - Parameters:
    ///   - sources: the options the UI may offer.
    ///   - makeSource: builds the audio source for an option id.
    ///   - makeTranscriber: builds a fresh recogniser for each run.
    public init(sources: [CaptionSourceOption],
                feed: CaptionFeed? = nil,
                makeSource: @escaping (CaptionSourceOption.ID) -> AudioSource?,
                makeTranscriber: @escaping () -> SpeechTranscribing) {
        self.sources = sources
        self.feed = feed ?? CaptionFeed()
        self.makeSource = makeSource
        self.makeTranscriber = makeTranscriber
    }

    public func start(_ sourceID: CaptionSourceOption.ID) {
        stop()
        guard let source = makeSource(sourceID) else {
            feed.setState(.failed("That audio source is not available."))
            return
        }
        activeSourceID = sourceID
        feed.setState(.preparing)
        let transcriber = makeTranscriber()
        let feed = self.feed

        let task = Task { @MainActor [weak self] in
            do {
                let audio = try await source.start()
                feed.setState(.listening)
                let (metered, meterFeed) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(100))
                // Tee: level meter on the way to the recogniser.
                let pump = Task.detached {
                    var lastLevelAt = ContinuousClock.now
                    var peak: Float = 0
                    for await buffer in audio {
                        peak = max(peak, buffer.peakLevel)
                        if ContinuousClock.now - lastLevelAt > .milliseconds(100) {
                            let level = peak
                            await MainActor.run { feed.setLevel(level) }
                            peak = 0
                            lastLevelAt = .now
                        }
                        meterFeed.yield(buffer)
                    }
                    meterFeed.finish()
                }
                for try await update in transcriber.transcribe(metered) {
                    feed.apply(update)
                }
                pump.cancel()
                if !Task.isCancelled { feed.setState(.idle) }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                feed.setState(.failed(error.localizedDescription))
            }
            if !Task.isCancelled { self?.finished(sourceID) }
        }
        running = (source, task)
    }

    public func stop() {
        guard let running else { return }
        self.running = nil
        running.source.stop()
        running.task.cancel()
        activeSourceID = nil
        feed.setState(.idle)
    }

    public func clear() {
        feed.clear()
    }

    private func finished(_ sourceID: CaptionSourceOption.ID) {
        guard activeSourceID == sourceID else { return }
        running = nil
        activeSourceID = nil
    }
}
