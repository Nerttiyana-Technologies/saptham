@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// The device microphone (built-in, headset, or a Mac's chosen input,
/// including an iPhone used as a Continuity microphone).
///
/// Recovers by itself: when the audio route changes, another app takes the
/// input, or (on a Mac) the default input device changes, AVAudioEngine
/// stops delivering without finishing the stream, so captions would show
/// "listening" while hearing nothing. The tap is then put back on the
/// current device, retrying for a while if the device is not ready yet.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    /// Replaced on every restart: an engine can stay bound to the device
    /// it was made on, so a fresh one picks up the current input.
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    #endif
    /// Bumped on every restart, so a retry left over from an older one stops.
    private var generation = 0

    public var deliversContinuously: Bool { true }

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
        try lock.withLock {
            self.continuation = continuation
            try startEngine()
        }
        watchForChanges()
        return stream
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(macOS)
        stopWatchingDefaultInput()
        #endif
        lock.withLock {
            generation += 1
            stopEngine()
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: Engine

    /// Caller holds `lock`.
    private func startEngine() throws {
        guard let continuation else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SapthamError("No microphone is available right now.")
        }
        // The macOS/iOS 27 error-reporting variant. The header marks it
        // NS_REFINED_FOR_SWIFT but the SDK ships no Swift overlay yet, so it
        // imports as a throwing method with a leading "__" and a vestigial
        // `error: ()` label (the NSError out-parameter is not last).
        try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { buffer, _ in
            continuation.yield(buffer)
        }
        engine.prepare()
        try engine.start()
        Diagnostics.engine.info("microphone started: \(format.description, privacy: .public)")
    }

    /// Caller holds `lock`.
    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Puts the tap back on whatever input is current now. Retries every
    /// 2 s for up to a minute: a device that has just been plugged in, or
    /// released by another app, is often not ready at once.
    private func restart(reason: String, attempt: Int = 1) {
        let current: Int? = lock.withLock {
            guard continuation != nil else { return nil }
            if attempt == 1 { generation += 1 }
            stopEngine()
            engine = AVAudioEngine()
            do {
                try startEngine()
                Diagnostics.engine.info("microphone restarted (\(reason, privacy: .public))")
                return nil
            } catch {
                Diagnostics.engine.error("microphone restart \(attempt, privacy: .public) failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
                return generation
            }
        }
        guard let current, attempt < 30 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, lock.withLock({ self.generation == current }) else { return }
            restart(reason: reason, attempt: attempt + 1)
        }
    }

    // MARK: Watching for changes

    private func watchForChanges() {
        let centre = NotificationCenter.default
        // Any engine's change: ours is replaced on restart, so match it here.
        observers.append(centre.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self, let changed = note.object as? AVAudioEngine,
                  lock.withLock({ changed === self.engine }) else { return }
            restart(reason: "audio configuration changed")
        })
        #if os(iOS)
        observers.append(centre.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { self?.restart(reason: "interruption ended") }
        })
        #else
        watchDefaultInput()
        #endif
    }

    #if os(macOS)
    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The default input device changed in System Settings (or a device
    /// that was the default came or went).
    private func watchDefaultInput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restart(reason: "default input device changed")
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                         DispatchQueue.global(), listener)
        if status == noErr { defaultInputListener = listener }
    }

    private func stopWatchingDefaultInput() {
        guard let listener = defaultInputListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                               DispatchQueue.global(), listener)
        defaultInputListener = nil
    }
    #endif
}
