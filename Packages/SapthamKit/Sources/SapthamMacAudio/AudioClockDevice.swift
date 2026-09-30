import CoreAudio
import SapthamCore

/// Chooses the device that paces reads from a process tap.
///
/// The tap always reports its own format (48 kHz), but the private capture
/// device runs at the rate of whichever device clocks it, and Core Audio does
/// not convert between the two. Bluetooth hearing devices and headsets run at
/// 16 kHz: clocked by them, the capture device delivered a third of the
/// samples while still describing them as 48 kHz, so speech reached the
/// recogniser at three times its speed and nothing was recognised (measured
/// 2026-09-30 with hearing aids as the output). Clocked by a device already
/// at the tap's rate, the same sentence was recognised word for word.
///
/// The clock device plays nothing; the user's sound keeps going to their
/// chosen output unchanged.
enum AudioClockDevice {
    /// The default output when it already runs at `sampleRate`; otherwise
    /// another output at that rate, preferring the built-in speakers, which
    /// cannot disconnect mid-call the way Bluetooth devices do.
    static func uid(forSampleRate sampleRate: Double) throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultOutput: AudioObjectID = try CoreAudioProperty.scalar(
            system, kAudioHardwarePropertyDefaultSystemOutputDevice)
        if rate(of: defaultOutput) == sampleRate {
            return try CoreAudioProperty.string(defaultOutput, kAudioDevicePropertyDeviceUID)
        }

        let devices: [AudioObjectID] = try CoreAudioProperty.array(system, kAudioHardwarePropertyDevices)
        let candidates = devices.filter { hasOutput($0) && rate(of: $0) == sampleRate }
        let builtIn = candidates.first {
            (try? CoreAudioProperty.scalar($0, kAudioDevicePropertyTransportType) as UInt32) == kAudioDeviceTransportTypeBuiltIn
        }
        if let chosen = builtIn ?? candidates.first,
           let uid = try? CoreAudioProperty.string(chosen, kAudioDevicePropertyDeviceUID) {
            Diagnostics.engine.info("default output runs at \(rate(of: defaultOutput) ?? 0, privacy: .public) Hz; capture clocked by \(uid, privacy: .public)")
            return uid
        }
        throw SapthamError("""
            The sound output runs at \(Int(rate(of: defaultOutput) ?? 0)) Hz and no other output runs at \
            \(Int(sampleRate)) Hz, so captions would be garbled.
            """)
    }

    private static func rate(of device: AudioObjectID) -> Double? {
        try? CoreAudioProperty.scalar(device, kAudioDevicePropertyNominalSampleRate)
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
