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
/// A line waiting to be decided is shown as provisional words, in front of
/// the words still being said, and the provisional words are re-sent after
/// every decision: otherwise a waiting line was on screen nowhere for up to
/// `settleAfter`, and the decided line then cleared the words still being
/// said (seen on iPhone 2026-10-28, in a continuous conversation).
///
/// A whole English sentence the secondary is very sure of is decided the
/// moment it arrives (`earlyConfidence`, `earlyWords`): otherwise the
/// primary's Tamil-script guess stayed on screen for seconds before the
/// English replaced it (seen on iPhone 2026-10-02, "Hi, how are you").
/// Single sure words still wait, so they cannot cut into a Tamil sentence.
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
        /// A secondary line this sure, with at least `earlyWords` words, is
        /// decided at once instead of waiting for the group to settle.
        public var earlyConfidence = 0.85
        public var earlyWords = 3
        /// Seconds to wait for more lines before deciding a group.
        public var settleAfter: TimeInterval = 2.0
        /// Lines this close in the audio count as overlapping.
        public var tolerance: Double = 0.15
        /// Names saved with each line, to tell later which recogniser won.
        public var primaryName = "primary"
        public var secondaryName = "secondary"

        public init() {}
    }

    private struct Line {
        let id: Int
        let side: Side
        let text: String
        let span: AudioSpan
        let confidence: Double?
        let arrived: Date
        /// A sure, sentence-length secondary line: its group need not wait.
        let decisive: Bool
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
    /// Each side's latest words not yet settled by that recogniser.
    private var volatileText: [Side: String] = [:]
    /// The provisional words last sent, so unchanged ones are not re-sent.
    private var sentProvisional = ""

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Takes one recogniser's update; returns what to show now.
    public mutating func add(_ update: TranscriptUpdate, from side: Side, at now: Date) -> [TranscriptUpdate] {
        switch update {
        case .volatile(let text):
            volatileText[side] = text
            return side == showing ? provisionalUpdate() : []
        case .final(let text, let span, let score):
            // A recogniser's settled line replaces its provisional words.
            volatileText[side] = ""
            let confidence = score?.confidence
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
            let decisive = side == .secondary
                && (confidence ?? 0) >= configuration.earlyConfidence
                && text.split(whereSeparator: { $0.isWhitespace }).count >= configuration.earlyWords
            pending.append(Line(id: nextID, side: side, text: text, span: span, confidence: confidence, arrived: now,
                                decisive: decisive))
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
        // CaptionFeed clears its provisional words on every final line.
        if !updates.isEmpty { sentProvisional = "" }
        return updates + provisionalUpdate()
    }

    /// The shown side's waiting lines followed by its words still being
    /// said, if that differs from what was last sent. A decided line clears
    /// the screen's provisional words, so after one they are always re-sent.
    private mutating func provisionalUpdate() -> [TranscriptUpdate] {
        let waiting = pending.filter { $0.side == showing }.sorted { $0.span.start < $1.span.start }.map(\.text)
        let text = (waiting + [volatileText[showing] ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard text != sentProvisional else { return [] }
        sentProvisional = text
        return [.volatile(text)]
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
        return bothMovedOn || quiet || group.contains(where: \.decisive)
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
        let primaryConfidences = primary.compactMap(\.confidence)
        let rival = secondaryWins
            ? (primaryConfidences.isEmpty ? nil : primaryConfidences.reduce(0, +) / Double(primaryConfidences.count))
            : (covered > 0 ? weighted / covered : nil)
        let name = secondaryWins ? configuration.secondaryName : configuration.primaryName
        return winners.map { line in
            .final(line.text, audio: line.span,
                   score: line.confidence.map { LineScore(confidence: $0, recogniser: name, rivalConfidence: rival) })
        }
    }
}
