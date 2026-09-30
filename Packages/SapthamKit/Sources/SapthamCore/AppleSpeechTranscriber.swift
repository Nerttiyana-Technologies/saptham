@preconcurrency import AVFoundation
import Speech

/// Apple's on-device recognisers (iOS/macOS 26+). Audio never leaves the
/// device. Default locale is English (India).
public final class AppleSpeechTranscriber: SpeechTranscribing {
    /// Which of Apple's two on-device recognisers to use.
    public enum Model: String, Sendable, CaseIterable {
        /// SpeechTranscriber: Apple's newer long-form model. Ignores
        /// vocabulary hints (measured 2026-09-30 on the latency bench).
        case speech
        /// DictationTranscriber: the system dictation model; honours
        /// vocabulary hints and custom language models.
        case dictation
    }

    private let locale: Locale
    private let model: Model
    private let vocabulary: [String]

    /// - Parameter vocabulary: words and phrases the speaker is likely to say
    ///   (names, places, jargon). Only the dictation model uses them.
    public init(locale: Locale = Locale(identifier: "en-IN"), model: Model = .speech, vocabulary: [String] = []) {
        self.locale = locale
        self.model = model
        self.vocabulary = vocabulary
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await self.run(audio: audio) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The standalone test program asked for this permission and worked; the
    /// app did not ask and produced no captions, so ask before every run
    /// (the system only shows the prompt once).
    private static func requireSpeechPermission() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        Diagnostics.engine.info("speech permission status \(status.rawValue, privacy: .public)")
        guard status == .authorized else {
            throw SapthamError("Speech recognition is off. Turn it on in System Settings → Privacy & Security → Speech Recognition.")
        }
    }

    /// One recogniser module plus its results reduced to (text, isFinal).
    private struct Recogniser {
        let module: any SpeechModule
        let results: AsyncThrowingStream<(text: AttributedString, isFinal: Bool), Error>
    }

    private func makeRecogniser() async throws -> Recogniser {
        let unavailable = SapthamError("Speech recognition for \(locale.identifier) is not available on this device.")
        switch model {
        case .speech:
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw unavailable }
            let module = SpeechTranscriber(locale: supported,
                                           transcriptionOptions: [],
                                           // fastResults trades a little accuracy in the
                                           // provisional words for showing them sooner.
                                           reportingOptions: [.volatileResults, .fastResults],
                                           // Per-word timing (caption delay, line position)
                                           // and confidence (choosing between languages).
                                           attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            return Recogniser(module: module, results: Self.bridge(module.results) { ($0.text, $0.isFinal) })
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { throw unavailable }
            let module = DictationTranscriber(locale: supported,
                                              contentHints: [],
                                              transcriptionOptions: [.punctuation],
                                              reportingOptions: [.volatileResults, .frequentFinalization],
                                              attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            return Recogniser(module: module, results: Self.bridge(module.results) { ($0.text, $0.isFinal) })
        }
    }

    private static func bridge<Results: AsyncSequence & Sendable>(
        _ results: Results,
        _ transform: @escaping @Sendable (Results.Element) -> (text: AttributedString, isFinal: Bool)
    ) -> AsyncThrowingStream<(text: AttributedString, isFinal: Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results { continuation.yield(transform(result)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(audio: AsyncStream<AVAudioPCMBuffer>,
                     emit: @escaping (TranscriptUpdate) -> Void) async throws {
        try await Self.requireSpeechPermission()
        let recogniser = try await makeRecogniser()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [recogniser.module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [recogniser.module])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recogniser.module]) else {
            throw SapthamError("The speech recogniser offered no audio format.")
        }

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        Diagnostics.engine.info("recogniser ready (\(self.model.rawValue, privacy: .public))")

        let latency = LatencyMeter()
        let results = Task {
            for try await (text, isFinal) in recogniser.results {
                // Delay is measured from the end of the newest recognised word,
                // not the end of the audio the recogniser has been given.
                if let lastWordEnd = text.runs.compactMap({ $0.audioTimeRange?.end.seconds }).max() {
                    latency.resultArrived(coveringAudioUpTo: lastWordEnd)
                }
                let plain = String(text.characters)
                if isFinal {
                    let ranges = text.runs.compactMap(\.audioTimeRange)
                    let span = ranges.isEmpty ? nil : AudioSpan(start: ranges.map(\.start.seconds).min()!,
                                                                end: ranges.map(\.end.seconds).max()!)
                    let confidences = text.runs.compactMap(\.transcriptionConfidence)
                    let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    emit(.final(plain, audio: span, confidence: confidence))
                } else {
                    emit(.volatile(plain))
                }
            }
        }

        var converter: AudioFormatConverter?
        var fedSeconds = 0.0
        for await buffer in audio {
            if Task.isCancelled { break }
            if converter == nil { converter = try AudioFormatConverter(from: buffer.format, to: analyzerFormat) }
            if let converted = converter?.convert(buffer) {
                feed.yield(AnalyzerInput(buffer: converted))
                fedSeconds += Double(converted.frameLength) / analyzerFormat.sampleRate
                latency.audioFed(upTo: fedSeconds)
            }
        }
        feed.finish()
        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
            results.cancel()
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
        }
    }
}
