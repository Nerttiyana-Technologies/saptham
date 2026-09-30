import Testing
@testable import SapthamCore

struct BrokenAudioDetectorTests {
    private let rate = 1_000.0   // 3 000 samples per block; a gap is 5 samples

    /// One block of sound split into `pieces` bursts at `level`, with
    /// `zeroShare` of the block as exact zeros spread between them.
    private func block(zeroShare: Double, pieces: Int = 8, level: Float = 0.3) -> [Float] {
        let zeros = Int(3_000 * zeroShare)
        let sound = 3_000 - zeros
        var samples: [Float] = []
        for piece in 0..<pieces {
            samples += [Float](repeating: 0, count: zeros / pieces + (piece < zeros % pieces ? 1 : 0))
            samples += [Float](repeating: level, count: sound / pieces + (piece < sound % pieces ? 1 : 0))
        }
        return samples
    }

    private let silence = [Float](repeating: 0, count: 3_000)

    private func feed(_ detector: inout BrokenAudioDetector, _ samples: [Float]) -> Bool? {
        samples.withUnsafeBufferPointer { detector.add($0, sampleRate: rate) }
    }

    @Test func loudAudioMostlyMissingIsReported() {
        var detector = BrokenAudioDetector()
        #expect(feed(&detector, block(zeroShare: 0.93)) == true)
        #expect(detector.isBrokenUp)
    }

    @Test func staysReportedWhenTheSoundDisappearsEntirely() {
        var detector = BrokenAudioDetector()
        _ = feed(&detector, block(zeroShare: 0.7))
        for _ in 0..<5 { #expect(feed(&detector, silence) == nil) }
        #expect(detector.isBrokenUp)
    }

    @Test func aSingleSoundThenSilenceIsNotBrokenUp() {
        var detector = BrokenAudioDetector()
        #expect(feed(&detector, block(zeroShare: 0.9, pieces: 1)) == nil)
        #expect(!detector.isBrokenUp)
    }

    @Test func pausedOrQuietAudioIsNotBrokenUp() {
        var detector = BrokenAudioDetector()
        for _ in 0..<3 { #expect(feed(&detector, silence) == nil) }
        for _ in 0..<3 { #expect(feed(&detector, block(zeroShare: 0.9, level: 0.001)) == nil) }
        #expect(!detector.isBrokenUp)
    }

    @Test func clearsOnceAudioArrivesWhole() {
        var detector = BrokenAudioDetector()
        _ = feed(&detector, block(zeroShare: 0.93))
        #expect(feed(&detector, block(zeroShare: 0)) == false)
        #expect(!detector.isBrokenUp)
    }

    @Test func smallBuffersAddUpToBlocks() {
        var detector = BrokenAudioDetector()
        let samples = block(zeroShare: 0.93) + block(zeroShare: 0.93)
        var verdicts: [Bool] = []
        for start in stride(from: 0, to: samples.count, by: 256) {
            let chunk = Array(samples[start..<min(start + 256, samples.count)])
            if let verdict = feed(&detector, chunk) { verdicts.append(verdict) }
        }
        #expect(verdicts == [true])
    }
}
