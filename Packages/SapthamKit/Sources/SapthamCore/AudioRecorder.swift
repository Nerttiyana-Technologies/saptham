@preconcurrency import AVFoundation

/// Writes captured audio to a file on this device.
public protocol AudioRecording: AnyObject, Sendable {
    /// File name inside the recordings folder.
    var fileName: String { get }
    /// Called off the main thread for every captured buffer.
    func write(_ buffer: AVAudioPCMBuffer)
    func finish()
}

/// Mono AAC (.m4a) recorder. Buffers are converted and written on a private
/// serial queue so the capture path never waits for the disk.
///
/// Its clock matches the recogniser's: both start at the first buffer of the
/// same stream, so TranscriptLine audio spans index straight into the file.
public final class FileAudioRecorder: AudioRecording, @unchecked Sendable {
    public let fileName: String
    private let url: URL
    private let queue = DispatchQueue(label: "saptham.recorder")
    // Touched only on `queue`.
    private var file: AVAudioFile?
    private var converter: AudioFormatConverter?
    private var failed = false

    public init(folder: URL, fileName: String) {
        self.fileName = fileName
        self.url = folder.appendingPathComponent(fileName)
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if file == nil { try open(matching: buffer.format) }
                guard let file, let converted = converter?.convert(buffer) else { return }
                try file.write(from: converted)
            } catch {
                failed = true
                Diagnostics.engine.error("recording stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func finish() {
        queue.sync { file = nil }   // closing the AVAudioFile finalises the .m4a
    }

    private func open(matching source: AVAudioFormat) throws {
        let sampleRate = source.sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        converter = try AudioFormatConverter(from: source, to: file.processingFormat)
        self.file = file
    }
}
