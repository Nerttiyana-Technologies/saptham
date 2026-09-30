@preconcurrency import AVFoundation
@preconcurrency import CoreML

/// A speech model that hears a fixed window of audio and returns its best
/// guess for each frame of it (CTC). Built by Tools/ModelBuild.
public protocol CTCWindowModel: AnyObject {
    var sampleRate: Double { get }
    var windowSamples: Int { get }
    var frameSamples: Int { get }
    var vocabulary: [String] { get }
    var blank: Int { get }
    var wordStartMarker: String { get }
    /// Best vocabulary index or `blank` for each frame; `window.count == windowSamples`.
    func bestPieces(window: [Float]) throws -> [Int]
}

/// A CTC model packaged as `<name>.mlmodelc` (compiled by Xcode from the
/// .mlpackage) next to `<name>.json`, both written by
/// Tools/ModelBuild/build_speech_model.py. The two files are one unit: the
/// JSON describes the network's input size, frame length and vocabulary.
public final class CoreMLCTCModel: CTCWindowModel {
    private struct Description: Decodable {
        let sampleRate: Double
        let windowSamples: Int
        let frameSamples: Int
        let blank: Int
        let wordStartMarker: String
        let vocabulary: [String]
    }

    public let sampleRate: Double
    public let windowSamples: Int
    public let frameSamples: Int
    public let vocabulary: [String]
    public let blank: Int
    public let wordStartMarker: String
    private let model: MLModel

    /// Loading takes a second or two; do it off the main thread.
    public init(compiledModel: URL, description: URL) throws {
        let info = try JSONDecoder().decode(Description.self, from: Data(contentsOf: description))
        let configuration = MLModelConfiguration()
        // The Neural Engine's half precision overflows in this model's
        // spectrogram (measured 2026-09-30); the GPU runs an 8 s window in
        // about 15 ms.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
        sampleRate = info.sampleRate
        windowSamples = info.windowSamples
        frameSamples = info.frameSamples
        vocabulary = info.vocabulary
        blank = info.blank
        wordStartMarker = info.wordStartMarker
    }

    public func bestPieces(window: [Float]) throws -> [Int] {
        let input = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
        window.withUnsafeBufferPointer { samples in
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
                _ = pointer.update(fromContentsOf: samples)
            }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        guard let scores = output.featureValue(for: "ctc_logprobs")?.multiArrayValue else {
            throw SapthamError("The speech model returned no scores.")
        }
        return Self.argmaxPerFrame(scores)
    }

    /// `scores` is [pieces, frames]; returns the best piece for each frame.
    private static func argmaxPerFrame(_ scores: MLMultiArray) -> [Int] {
        let pieces = scores.shape[0].intValue
        let frames = scores.shape[1].intValue
        let pieceStride = scores.strides[0].intValue
        let frameStride = scores.strides[1].intValue
        var best = [Int](repeating: 0, count: frames)
        func scan<T: BinaryFloatingPoint>(_ pointer: UnsafeBufferPointer<T>) {
            for frame in 0..<frames {
                var bestPiece = 0
                var bestScore = -T.infinity
                for piece in 0..<pieces {
                    let score = pointer[piece * pieceStride + frame * frameStride]
                    if score > bestScore { bestScore = score; bestPiece = piece }
                }
                best[frame] = bestPiece
            }
        }
        switch scores.dataType {
        case .float16:
            scores.withUnsafeBufferPointer(ofType: Float16.self) { scan($0) }
        default:
            scores.withUnsafeBufferPointer(ofType: Float.self) { scan($0) }
        }
        return best
    }
}

/// Live captions from a CTC window model: the model hears the latest
/// window of audio every `hopSeconds`, and CTCLiveDecoder turns its guesses
/// into provisional and settled lines. Audio never leaves the device.
public final class WindowedCTCTranscriber: SpeechTranscribing {
    private let loadModel: @Sendable () throws -> CTCWindowModel
    private let hopSeconds: Double

    /// - Parameter loadModel: called once per run, off the main thread.
    public init(hopSeconds: Double = 0.32, loadModel: @escaping @Sendable () throws -> CTCWindowModel) {
        self.hopSeconds = hopSeconds
        self.loadModel = loadModel
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let loadModel = self.loadModel
        let hopSeconds = self.hopSeconds
        return AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.run(audio: audio, model: try loadModel(), hopSeconds: hopSeconds) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func run(audio: AsyncStream<AVAudioPCMBuffer>, model: CTCWindowModel, hopSeconds: Double,
                            emit: @escaping (TranscriptUpdate) -> Void) async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: model.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw SapthamError("Cannot describe the speech model's audio format.")
        }
        Diagnostics.engine.info("Tamil recogniser ready")
        let windowSamples = model.windowSamples
        let hop = Int(hopSeconds * model.sampleRate) / model.frameSamples * model.frameSamples
        let frameCount = windowSamples / model.frameSamples
        var decoder = CTCLiveDecoder(vocabulary: model.vocabulary, blank: model.blank,
                                     wordStartMarker: model.wordStartMarker,
                                     configuration: .forWindow(frames: frameCount))
        // The window starts as silence and fills from the right.
        var window = [Float](repeating: 0, count: windowSamples)
        var pending: [Float] = []
        var received = 0          // samples of the stream seen so far
        var converter: AudioFormatConverter?
        let latency = LatencyMeter()

        for await buffer in audio {
            if Task.isCancelled { break }
            if converter == nil { converter = try AudioFormatConverter(from: buffer.format, to: format) }
            guard let converted = converter?.convert(buffer), let samples = converted.floatChannelData?[0] else { continue }
            pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
            while pending.count >= hop {
                window.removeFirst(hop)
                window.append(contentsOf: pending.prefix(hop))
                pending.removeFirst(hop)
                received += hop
                latency.audioFed(upTo: Double(received) / model.sampleRate)
                let pieces = try model.bestPieces(window: window)
                // Frame 0 of the window lies this many frames into the stream
                // (negative until a full window has been heard).
                let firstFrame = (received - windowSamples) / model.frameSamples
                latency.resultArrived(coveringAudioUpTo: Double(received) / model.sampleRate)
                for update in decoder.consume(ids: Array(pieces.prefix(frameCount)), firstFrame: firstFrame) {
                    emit(update)
                }
            }
        }
        if !Task.isCancelled {
            decoder.finish().forEach(emit)
        }
    }
}
