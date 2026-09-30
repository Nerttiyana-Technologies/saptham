// Adapted from Spikes/CallCaptionTap, proven on a real relayed call 2026-09-30.
import CoreAudio
import Darwin

/// One process that Core Audio knows about (i.e. has an audio client).
public struct AudioProcess: Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isRunningOutput: Bool

    /// Matches a user-supplied filter against the executable name or bundle ID.
    public func matches(_ needle: String) -> Bool {
        name.localizedCaseInsensitiveContains(needle) || bundleID.localizedCaseInsensitiveContains(needle)
    }
}

public enum AudioProcessList {
    public static func all() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            let pid: pid_t = (try? CoreAudioProperty.scalar(id, kAudioProcessPropertyPID)) ?? -1
            let bundleID = (try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let running: UInt32 = (try? CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningOutput)) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID,
                                name: processName(pid), isRunningOutput: running != 0)
        }
    }

    private static func processName(_ pid: pid_t) -> String {
        guard pid > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "?"
    }
}

/// Thin typed wrappers over AudioObjectGetPropertyData for the global scope.
enum CoreAudioProperty {
    struct Failure: Error, CustomStringConvertible {
        let selector: AudioObjectPropertySelector
        let status: OSStatus
        var description: String { "Core Audio property \(fourCC(selector)) failed: OSStatus \(status)" }
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value)
        guard status == noErr else { throw Failure(selector: selector, status: status) }
        return value.pointee
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw Failure(selector: selector, status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer)
        guard status == noErr else { throw Failure(selector: selector, status: status) }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { throw Failure(selector: selector, status: status) }
        return value.takeRetainedValue() as String
    }
}

func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}
