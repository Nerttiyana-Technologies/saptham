import Foundation
import Testing
@testable import SapthamCore

struct CaptureHealthTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func aQuietRoomIsHealthy() {
        let health = CaptureHealth(startedAt: at(0))
        for tenth in 0..<200 { health.received(peak: 0.0004, at: at(Double(tenth) / 10)) }
        #expect(health.stalledSince(now: at(20)) == nil)
    }

    @Test func noBuffersMeansStalled() {
        let health = CaptureHealth(startedAt: at(0))
        health.received(peak: 0.1, at: at(1))
        #expect(health.stalledSince(now: at(4)) == nil)
        #expect(health.stalledSince(now: at(5.5)) == at(1))
    }

    @Test func onlyExactZerosMeansStalled() {
        let health = CaptureHealth(startedAt: at(0))
        for tenth in 0..<100 { health.received(peak: 0, at: at(Double(tenth) / 10)) }
        #expect(health.stalledSince(now: at(9.9)) == at(0))
    }

    @Test func soundAgainRecovers() {
        let health = CaptureHealth(startedAt: at(0))
        for tenth in 0..<100 { health.received(peak: 0, at: at(Double(tenth) / 10)) }
        health.received(peak: 0.02, at: at(10))
        #expect(health.stalledSince(now: at(10.1)) == nil)
    }
}
