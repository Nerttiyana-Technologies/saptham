import Foundation
import os

/// Measures how long after audio reaches the recogniser the matching words
/// come back, and logs the median every 20 results. Diagnostics only: it
/// never sees the words themselves.
///
/// Audio time is counted from the first sample handed to the recogniser, the
/// same origin the recogniser uses for result ranges.
final class LatencyMeter: @unchecked Sendable {
    private struct State {
        var marks: [(audio: Double, fedAt: ContinuousClock.Instant)] = []
        var samples: [Double] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func audioFed(upTo audioSeconds: Double) {
        state.withLock { state in
            state.marks.append((audioSeconds, .now))
            if state.marks.count > 4_000 { state.marks.removeFirst(2_000) }
        }
    }

    func resultArrived(coveringAudioUpTo audioSeconds: Double) {
        guard audioSeconds.isFinite, audioSeconds > 0 else { return }
        let report: (median: Double, worst: Double)? = state.withLock { state in
            guard let mark = state.marks.first(where: { $0.audio >= audioSeconds }) else { return nil }
            let delay = ContinuousClock.now - mark.fedAt
            state.samples.append(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
            guard state.samples.count >= 20 else { return nil }
            let sorted = state.samples.sorted()
            state.samples.removeAll()
            return (sorted[sorted.count / 2], sorted[sorted.count - 1])
        }
        if let report {
            Diagnostics.engine.info("recogniser delay: median \(Int(report.median * 1000), privacy: .public) ms, worst \(Int(report.worst * 1000), privacy: .public) ms")
        }
    }
}
