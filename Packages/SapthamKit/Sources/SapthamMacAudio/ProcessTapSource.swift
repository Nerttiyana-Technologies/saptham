@preconcurrency import AVFoundation
import CoreAudio
import SapthamCore

/// Captures the audio OUTPUT of chosen processes, or of the whole system,
/// through a Core Audio process tap (macOS 14.2+). The audio keeps playing
/// normally; the tap only listens.
///
/// Permission: needs "System Audio Recording", requested through
/// NSAudioCaptureUsageDescription in the app's Info.plist (write the key in
/// the plist itself; Xcode's INFOPLIST_KEY_ build setting drops it). If the
/// grant is missing Core Audio does NOT fail — it delivers silence.
///
/// The tap only delivers buffers while a tapped process is playing, so for
/// call audio "listening" includes waiting for a call.
public final class ProcessTapSource: AudioSource {
    public enum Target: Sendable {
        /// Every process whose executable name or bundle ID contains one of these.
        case processes(matching: [String])
        /// All system audio except this app.
        case everything
    }

    /// macOS daemons that play iPhone calls relayed to the Mac ("Calls from
    /// iPhone") and FaceTime audio. Verified on macOS 27.0.1.
    public static let callProcessNames = ["callservicesd", "avconferenced"]

    private let target: Target
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let queue = DispatchQueue(label: "saptham.process-tap", qos: .userInteractive)

    public init(target: Target) {
        self.target = target
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        let description: CATapDescription
        switch target {
        case .everything:
            let own = try AudioProcessList.all().filter { $0.pid == getpid() }.map(\.objectID)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        case .processes(let names):
            let matches = try AudioProcessList.all().filter { process in names.contains { process.matches($0) } }
            guard !matches.isEmpty else {
                throw SapthamError("No running app matches \(names.joined(separator: ", ")).")
            }
            description = CATapDescription(stereoMixdownOfProcesses: matches.map(\.objectID))
        }
        description.name = "Saptham captions"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the audio tap")
        var streamDescription: AudioStreamBasicDescription = try CoreAudioProperty.scalar(tapID, kAudioTapPropertyFormat)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw SapthamError("The audio tap reported an unusable format.")
        }

        let clockUID = try AudioClockDevice.uid(forSampleRate: format.sampleRate)

        // A private aggregate device is the only way to read a tap: the tap
        // becomes its input stream, clocked by `clockUID`. Nothing is played
        // through that device; it only paces the reads.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Saptham captions",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        do {
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                           "create the capture device")
            // Buffers are read as `format`; at any other rate speech is
            // silently sped up or slowed down (see AudioClockDevice).
            let captureRate: Float64 = try CoreAudioProperty.scalar(aggregateID, kAudioDevicePropertyNominalSampleRate)
            guard captureRate == format.sampleRate else {
                throw SapthamError("The capture device runs at \(Int(captureRate)) Hz instead of \(Int(format.sampleRate)) Hz.")
            }

            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(100))
            self.continuation = continuation
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
                if let copy = Self.copy(input, format: format) { continuation.yield(copy) }
            }, "start listening")
            try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start the capture device")
            return stream
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    deinit { stop() }

    /// Core Audio's buffer is only valid during the callback; hand out a copy.
    private static func copy(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
              borrowed.frameLength > 0,
              let owned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: borrowed.frameLength)
        else { return nil }
        owned.frameLength = borrowed.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: borrowed.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            if let from = source[index].mData, let to = target[index].mData { memcpy(to, from, Int(bytes)) }
            target[index].mDataByteSize = bytes
        }
        return owned
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw SapthamError("Could not \(what) (Core Audio error \(status) \(fourCC(UInt32(bitPattern: status)))).")
        }
    }
}
