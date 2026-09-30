import Foundation

/// Chooses, stretch by stretch, between two recognisers that heard the same
/// audio: a *primary* one whose lines are shown by default, and a
/// *secondary* one whose lines replace them where it is sure of itself.
///
/// Built for Tamil conversations that move in and out of English: the Tamil
/// model (primary) writes everything in Tamil script, English included, while
/// Apple's English recogniser (secondary) knows when it is hearing English.
/// Measured 2026-10-01: English sentences scored 0.96–0.99 with it, Tamil
/// speech 0.23–0.47 (12 FLEURS Tamil recordings and 4 synthetic sentences),
/// and a Tamil sentence with English words in it 0.46 — so such sentences
/// stay in Tamil script, which is how they are normally written.
///
/// Lines from both recognisers are grouped where their audio overlaps. A
/// group is decided once no more lines can join it — either recogniser has
/// moved past it, or nothing has joined it for `settleAfter` — and shows the
/// secondary's lines if they are at least `secondaryConfidence` sure and
/// cover most of the group, otherwise the primary's. Provisional words
/// follow whichever recogniser won the latest group.
///
/// Pure logic with no audio, recognisers or clock of its own, so it can be
/// tested with made-up lines and times.
public struct BilingualArbiter {
    public enum Side: Sendable { case primary, secondary }

    public struct Configuration: Sendable {
        /// Secondary lines this sure (their average, weighted by duration) win.
        public var secondaryConfidence = 0.70
        /// Share of the group's audio the secondary lines must cover to win,
        /// so one confident English word does not replace a Tamil sentence.
        public var secondaryCoverage = 0.5
        /// Seconds to wait for more lines before deciding a group.
        public var settleAfter: TimeInterval = 2.0
        /// Lines this close in the audio count as overlapping.
        public var tolerance: Double = 0.15

        public init() {}
    }

    private struct Line {
        let id: Int
        let side: Side
        let text: String
        let span: AudioSpan
        let confidence: Double?
        let arrived: Date
    }

    public let configuration: Configuration
    /// The side that won the most recent group; its provisional words are shown.
    public private(set) var showing: Side = .primary

    private var pending: [Line] = []
    private var nextID = 0
    /// Audio before this has been decided; late lines inside it are dropped.
    private var decidedUpTo: Double = -.infinity
    /// The furthest each side's settled lines reach.
    private var reached: [Side: Double] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Takes one recogniser's update; returns what to show now.
    public mutating func add(_ update: TranscriptUpdate, from side: Side, at now: Date) -> [TranscriptUpdate] {
        switch update {
        case .volatile:
            return side == showing ? [update] : []
        case .final(let text, let span, let confidence):
            guard let span else {
                Diagnostics.engine.info("bilingual: line without timing from \(side == .primary ? "primary" : "secondary", privacy: .public), sure \(confidence ?? -1, privacy: .public)")
                // Cannot be placed against the other side: trust only the
                // primary, or a secondary that is sure of itself.
                let trusted = side == .primary || (confidence ?? 0) >= configuration.secondaryConfidence
                return trusted ? [update] : []
            }
            reached[side] = max(reached[side] ?? -.infinity, span.end)
            // Mostly inside audio already decided: the other side's line won.
            if span.end - max(span.start, decidedUpTo) < (span.end - span.start) / 2 { return decide(at: now) }
            pending.append(Line(id: nextID, side: side, text: text, span: span, confidence: confidence, arrived: now))
            nextID += 1
            return decide(at: now)
        }
    }

    /// Decides groups that have waited long enough; call regularly.
    public mutating func tick(at now: Date) -> [TranscriptUpdate] {
        decide(at: now)
    }

    /// Decides everything still waiting, at the end of the audio.
    public mutating func finish() -> [TranscriptUpdate] {
        decide(at: .distantFuture, force: true)
    }

    // MARK: -

    private mutating func decide(at now: Date, force: Bool = false) -> [TranscriptUpdate] {
        var updates: [TranscriptUpdate] = []
        while let group = firstGroup(), force || isSettled(group, at: now) {
            let decided = Set(group.map(\.id))
            pending.removeAll { decided.contains($0.id) }
            decidedUpTo = max(decidedUpTo, group.map(\.span.end).max()!)
            updates += choose(group)
        }
        return updates
    }

    /// The earliest group of overlapping lines.
    private func firstGroup() -> [Line]? {
        let sorted = pending.sorted { $0.span.start < $1.span.start }
        guard let first = sorted.first else { return nil }
        var group = [first]
        var end = first.span.end
        for line in sorted.dropFirst() where line.span.start <= end + configuration.tolerance {
            group.append(line)
            end = max(end, line.span.end)
        }
        return group
    }

    private func isSettled(_ group: [Line], at now: Date) -> Bool {
        let end = group.map(\.span.end).max()!
        let bothMovedOn = [Side.primary, .secondary].allSatisfy { (reached[$0] ?? -.infinity) > end + configuration.tolerance }
        let quiet = now.timeIntervalSince(group.map(\.arrived).max()!) >= configuration.settleAfter
        return bothMovedOn || quiet
    }

    private mutating func choose(_ group: [Line]) -> [TranscriptUpdate] {
        let secondary = group.filter { $0.side == .secondary }
        let primary = group.filter { $0.side == .primary }
        let start = group.map(\.span.start).min()!
        let end = group.map(\.span.end).max()!
        let covered = secondary.map { $0.span.end - $0.span.start }.reduce(0, +)
        let weighted = secondary.map { ($0.confidence ?? 0) * ($0.span.end - $0.span.start) }.reduce(0, +)
        let secondaryWins = covered > 0
            && weighted / covered >= configuration.secondaryConfidence
            && covered >= (end - start) * configuration.secondaryCoverage
        let winners = secondaryWins ? secondary : primary
        // Numbers only: what was said stays out of the log.
        Diagnostics.engine.info("""
            bilingual: \(String(format: "%.2f–%.2f", start, end), privacy: .public) s, \(primary.count, privacy: .public) primary \
            + \(secondary.count, privacy: .public) secondary lines, secondary sure \(String(format: "%.2f", covered > 0 ? weighted / covered : 0), privacy: .public) \
            covering \(String(format: "%.0f", 100 * covered / max(end - start, 0.001)), privacy: .public)% → \(secondaryWins ? "secondary" : "primary", privacy: .public)
            """)
        guard !winners.isEmpty else { return [] }
        showing = secondaryWins ? .secondary : .primary
        return winners.map { .final($0.text, audio: $0.span, confidence: $0.confidence) }
    }
}
