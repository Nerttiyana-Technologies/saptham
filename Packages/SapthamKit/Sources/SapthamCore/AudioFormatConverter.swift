@preconcurrency import AVFoundation

/// Sample-rate / channel / sample-type conversion for one fixed format pair.
public final class AudioFormatConverter {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    public init(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw SapthamError("Cannot convert audio from \(source) to \(target).")
        }
        // Mix all channels into mono rather than keeping only the first.
        converter.downmix = true
        self.converter = converter
        self.target = target
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

extension AVAudioPCMBuffer {
    /// A copy with its own sample memory. An AVAudioEngine tap reuses the
    /// memory of the buffers it hands out (seen on iPhone, iOS 27.1,
    /// 2026-10-29), so a buffer kept past its callback — queued for the
    /// recogniser — can be overwritten with later sound, and the recogniser
    /// then hears that sound twice ("Water, water"). Taps queue a copy.
    public func ownedCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0, let owned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        owned.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            if let from = source[index].mData, let to = target[index].mData { memcpy(to, from, Int(bytes)) }
            target[index].mDataByteSize = bytes
        }
        return owned
    }

    /// Peak amplitude of the first channel, 0 … 1. Float formats only.
    public var peakLevel: Float {
        guard let samples = floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(frameLength) { peak = max(peak, abs(samples[index])) }
        return min(peak, 1)
    }
}
