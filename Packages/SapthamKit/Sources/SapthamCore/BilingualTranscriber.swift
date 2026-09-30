@preconcurrency import AVFoundation

/// Captions speech that moves between two languages: both recognisers hear
/// the same audio and BilingualArbiter picks, stretch by stretch, whose
/// words to show (see there for how).
///
/// If the secondary recogniser fails (its language is not installed, or
/// permission is off) captions carry on with the primary alone; if the
/// primary fails, captioning fails.
public final class BilingualTranscriber: SpeechTranscribing {
    private let primary: SpeechTranscribing
    private let secondary: SpeechTranscribing
    private let configuration: BilingualArbiter.Configuration

    public init(primary: SpeechTranscribing, secondary: SpeechTranscribing,
                configuration: BilingualArbiter.Configuration = .init()) {
        self.primary = primary
        self.secondary = secondary
        self.configuration = configuration
    }

    private enum Event: Sendable {
        case update(TranscriptUpdate, BilingualArbiter.Side)
        case tick
        case secondaryFailed(String)
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let primary = self.primary
        let secondary = self.secondary
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let work = Task {
                // Both recognisers get every buffer.
                let (primaryAudio, toPrimary) = AsyncStream<AVAudioPCMBuffer>.makeStream()
                let (secondaryAudio, toSecondary) = AsyncStream<AVAudioPCMBuffer>.makeStream()
                let fanOut = Task {
                    for await buffer in audio {
                        toPrimary.yield(buffer)
                        toSecondary.yield(buffer)
                    }
                    toPrimary.finish()
                    toSecondary.finish()
                }

                // Every recogniser update and clock tick goes through one
                // stream, so the arbiter is only ever touched here.
                let (events, toArbiter) = AsyncStream<Event>.makeStream()
                let secondaryTask = Task {
                    do {
                        for try await update in secondary.transcribe(secondaryAudio) {
                            toArbiter.yield(.update(update, .secondary))
                        }
                    } catch {
                        toArbiter.yield(.secondaryFailed(String(describing: error)))
                    }
                }
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        toArbiter.yield(.tick)
                    }
                }
                let primaryTask = Task {
                    defer { toArbiter.finish() }
                    for try await update in primary.transcribe(primaryAudio) {
                        toArbiter.yield(.update(update, .primary))
                    }
                    // The secondary finishes its own last words before the end.
                    await secondaryTask.value
                }

                var arbiter = BilingualArbiter(configuration: configuration)
                var secondaryAlive = true
                // These tasks are not children of this one: stopping must
                // reach them explicitly, or both recognisers keep running.
                await withTaskCancellationHandler {
                    for await event in events {
                        switch event {
                        case .update(let update, let side):
                            if !secondaryAlive, side == .primary {
                                continuation.yield(update)   // no one to compare with
                            } else {
                                arbiter.add(update, from: side, at: Date()).forEach { continuation.yield($0) }
                            }
                        case .tick:
                            arbiter.tick(at: Date()).forEach { continuation.yield($0) }
                        case .secondaryFailed(let reason):
                            Diagnostics.engine.error("second language unavailable, continuing with one: \(reason, privacy: .public)")
                            secondaryAlive = false
                            arbiter.finish().forEach { continuation.yield($0) }
                        }
                    }
                } onCancel: {
                    fanOut.cancel()
                    primaryTask.cancel()
                    secondaryTask.cancel()
                    ticker.cancel()
                }
                ticker.cancel()
                fanOut.cancel()
                arbiter.finish().forEach { continuation.yield($0) }
                do {
                    try await primaryTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
