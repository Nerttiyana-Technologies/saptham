@preconcurrency import AVFoundation
import Speech

/// Apple's on-device recogniser (SpeechTranscriber, iOS/macOS 26+).
/// Audio never leaves the device. Default locale is English (India).
public final class AppleSpeechTranscriber: SpeechTranscribing {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-IN")) {
        self.locale = locale
    }

    /// Makes sure the speech model for the locale is installed. Safe to call
    /// repeatedly; downloads only the first time.
    public func prepare() async throws {
        let transcriber = try await makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
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

    private func makeModule() async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SapthamError("Speech recognition for \(locale.identifier) is not available on this device.")
        }
        return SpeechTranscriber(locale: supported,
                                 transcriptionOptions: [],
                                 reportingOptions: [.volatileResults],
                                 attributeOptions: [])
    }

    private func run(audio: AsyncStream<AVAudioPCMBuffer>,
                     emit: @escaping (TranscriptUpdate) -> Void) async throws {
        try await Self.requireSpeechPermission()
        let transcriber = try await makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SapthamError("The speech recogniser offered no audio format.")
        }

        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        Diagnostics.engine.info("recogniser ready")

        let results = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                emit(result.isFinal ? .final(text) : .volatile(text))
            }
        }

        var converter: AudioFormatConverter?
        for await buffer in audio {
            if Task.isCancelled { break }
            if converter == nil { converter = try AudioFormatConverter(from: buffer.format, to: analyzerFormat) }
            if let converted = converter?.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
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
