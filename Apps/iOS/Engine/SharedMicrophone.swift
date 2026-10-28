@preconcurrency import AVFoundation
import SapthamCore
import Synchronization

/// The iPhone's microphone, captured once and shared by everyone listening:
/// live captions and sound alerts each get an `AudioSource` from here.
///
/// Why one capture: iOS has a single audio session per app. A second
/// AVAudioEngine starting or stopping reconfigures that session under the
/// first, which then stops receiving audio. So listeners never own the
/// session; this class does, and keeps the engine running while anyone
/// listens. Listeners receive the same buffers and must not modify them.
///
/// Also restarts after interruptions (a phone call, Siri) and route changes
/// (headphones plugged in), which stop the engine without telling listeners.
final class SharedMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let listeners = Mutex<[UUID: AsyncStream<AVAudioPCMBuffer>.Continuation]>([:])
    /// Serialises starting, stopping and restarting the engine.
    private let control = NSLock()
    private var isRunning = false
    /// Stereo capture for SoundDirection; see setStereo.
    private var wantsStereo = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { self?.restart(reason: "interruption ended") }
        })
        observers.append(centre.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart(reason: "audio route changed")
        })
        observers.append(centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.restart(reason: "media services reset")
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether the built-in microphone can capture in stereo on this iPhone.
    static var supportsStereo: Bool {
        AVAudioSession.sharedInstance().availableInputs?
            .first { $0.portType == .builtInMic }?
            .dataSources?.contains { $0.supportedPolarPatterns?.contains(.stereo) == true } ?? false
    }

    /// Captures in stereo (for SoundDirection) or mono. Restarts the
    /// capture if it is running; every listener keeps its stream.
    /// Coupled to SoundDirection by channel order (see there).
    func setStereo(_ stereo: Bool) {
        let changed = control.withLock { () -> Bool in
            guard wantsStereo != stereo else { return false }
            wantsStereo = stereo
            return true
        }
        if changed { restart(reason: stereo ? "stereo on" : "stereo off") }
    }

    /// A new listener. Each `start()` on it joins the shared capture.
    func makeSource() -> AudioSource { Listener(microphone: self) }

    fileprivate func join(_ id: UUID) async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SapthamError("Microphone access is off. Turn it on in Settings → Apps → Saptham.")
        }
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(100))
        listeners.withLock { $0[id] = continuation }
        do {
            try control.withLock { try startEngine() }
        } catch {
            leave(id)
            throw error
        }
        return stream
    }

    fileprivate func leave(_ id: UUID) {
        let continuation = listeners.withLock { $0.removeValue(forKey: id) }
        continuation?.finish()
        guard listeners.withLock({ $0.isEmpty }) else { return }
        control.withLock { stopEngine() }
    }

    /// Caller holds `control`.
    private func startEngine() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off the voice processing meant for calls, which
        // would otherwise smooth away the sounds alerts listen for.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        if wantsStereo { configureStereo(session) }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw SapthamError("No microphone is available right now.") }
        // See MicrophoneSource: the iOS/macOS 27 error-reporting variant.
        try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { [weak self] buffer, _ in
            self?.share(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Diagnostics.engine.info("shared microphone started: \(format.description, privacy: .public)")
    }

    /// Picks the built-in microphone's stereo pattern, left channel on the
    /// user's left with the iPhone upright. Failing quietly leaves mono.
    private func configureStereo(_ session: AVAudioSession) {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let source = builtIn.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true }) else { return }
        do {
            try source.setPreferredPolarPattern(.stereo)
            try builtIn.setPreferredDataSource(source)
            try session.setPreferredInput(builtIn)
            try session.setPreferredInputOrientation(.portrait)
        } catch {
            Diagnostics.engine.error("stereo capture unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs on the audio thread for every captured buffer. The engine reuses
    /// the buffer's memory, so listeners get one copy between them (see
    /// ownedCopy); they still must not modify it.
    private func share(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.ownedCopy() else { return }
        listeners.withLock { for continuation in $0.values { continuation.yield(copy) } }
    }

    /// Caller holds `control`.
    private func stopEngine() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Diagnostics.engine.info("shared microphone stopped")
    }

    private func restart(reason: String) {
        guard !listeners.withLock({ $0.isEmpty }) else { return }
        Diagnostics.engine.info("shared microphone restarting: \(reason, privacy: .public)")
        control.withLock {
            if isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                isRunning = false
            }
            do {
                try startEngine()
            } catch {
                Diagnostics.engine.error("shared microphone could not restart: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// One listener's view of the shared microphone.
private final class Listener: AudioSource {
    private let microphone: SharedMicrophone
    private var id: UUID?

    var deliversContinuously: Bool { true }

    init(microphone: SharedMicrophone) {
        self.microphone = microphone
    }

    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        stop()
        let id = UUID()
        self.id = id
        return try await microphone.join(id)
    }

    func stop() {
        guard let id else { return }
        self.id = nil
        microphone.leave(id)
    }
}
