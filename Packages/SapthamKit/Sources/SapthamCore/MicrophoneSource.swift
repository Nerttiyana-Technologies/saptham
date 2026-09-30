@preconcurrency import AVFoundation

/// The device microphone (built-in, headset, or a Mac's chosen input,
/// including an iPhone used as a Continuity microphone).
public final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SapthamError("Microphone access is off. Turn it on in Settings → Privacy & Security → Microphone.")
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.continuation = continuation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The macOS/iOS 27 error-reporting variant. The header marks it
        // NS_REFINED_FOR_SWIFT but the SDK ships no Swift overlay yet, so it
        // imports as a throwing method with a leading "__" and a vestigial
        // `error: ()` label (the NSError out-parameter is not last).
        try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { buffer, _ in
            continuation.yield(buffer)
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
