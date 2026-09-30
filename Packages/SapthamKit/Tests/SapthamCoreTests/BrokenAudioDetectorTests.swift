import Testing
@testable import SapthamCore

struct BrokenAudioDetectorTests {
    private let rate = 1_000.0   // 3 000 samples per block

    /// One block of sound: `zeroShare` of it exact zeros, the rest at `level`.
    private func block(zeroShare: Double, level: Float = 0.3) -> [Float] {
        let zeros = Int(3_000 * zeroShare)
        return [Float](repeating: 0, count: zeros) + [Float](repeating: level, count: 3_000 - zeros)
    }

    private func feed(_ detector: inout BrokenAudioDetector, _ samples: [Float]) -> Bool? {
        samples.withUnsafeBufferPointer { detector.add($0, sampleRate: rate) }
    }

    @Test func loudAudioMostlyMissingIsReportedAfterTwoBlocks() {
        var detector = BrokenAudioDetector()
        #expect(feed(&detector, block(zeroShare: 0.93)) == nil)
        #expect(feed(&detector, block(zeroShare: 0.93)) == true)
        #expect(detector.isBrokenUp)
    }

    @Test func oneOddBlockIsNotReported() {
        var detector = BrokenAudioDetector()
        #expect(feed(&detector, block(zeroShare: 0.93)) == nil)
        #expect(feed(&detector, block(zeroShare: 0)) == nil)
        #expect(feed(&detector, block(zeroShare: 0.93)) == nil)
        #expect(!detector.isBrokenUp)
    }

    @Test func pausedOrQuietAudioIsNotBrokenUp() {
        var detector = BrokenAudioDetector()
        for _ in 0..<3 { #expect(feed(&detector, block(zeroShare: 1)) == nil) }
        for _ in 0..<3 { #expect(feed(&detector, block(zeroShare: 0.9, level: 0.001)) == nil) }
        #expect(!detector.isBrokenUp)
    }

    @Test func clearsOnceAudioArrivesWhole() {
        var detector = BrokenAudioDetector()
        _ = feed(&detector, block(zeroShare: 0.93))
        _ = feed(&detector, block(zeroShare: 0.93))
        #expect(feed(&detector, block(zeroShare: 0.1)) == false)
        #expect(!detector.isBrokenUp)
    }

    @Test func smallBuffersAddUpToBlocks() {
        var detector = BrokenAudioDetector()
        let samples = block(zeroShare: 0.93) + block(zeroShare: 0.93) + block(zeroShare: 0.93)
        var verdicts: [Bool] = []
        for start in stride(from: 0, to: samples.count, by: 256) {
            let chunk = Array(samples[start..<min(start + 256, samples.count)])
            if let verdict = feed(&detector, chunk) { verdicts.append(verdict) }
        }
        #expect(verdicts == [true])
    }
}
