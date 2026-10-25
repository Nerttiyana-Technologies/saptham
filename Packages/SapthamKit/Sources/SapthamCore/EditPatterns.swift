import Foundation
import Observation

/// A fix the user made by hand often enough to offer as a correction rule
/// (ADR 0002). Only ever offered: a rule is added when the user accepts it.
public struct EditSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { Self.id(heard: heard, replacement: replacement) }
    /// 1–3 words, as the recogniser wrote them.
    public let heard: String
    /// 1–3 words, never empty.
    public let replacement: String
    /// Distinct edited lines showing this fix.
    public let lineCount: Int
    /// Conversations those lines are in.
    public let sessionIDs: Set<TranscriptSession.ID>

    public init(heard: String, replacement: String, lineCount: Int, sessionIDs: Set<TranscriptSession.ID>) {
        self.heard = heard
        self.replacement = replacement
        self.lineCount = lineCount
        self.sessionIDs = sessionIDs
    }

    static func id(heard: String, replacement: String) -> String {
        heard.lowercased() + "\u{1F}" + replacement.lowercased()
    }
}

/// A word-level fix found in one edited line.
public struct EditFix: Equatable, Sendable {
    public let heard: String
    public let replacement: String
}

/// Finds the fixes the user keeps making by hand, from the lines they edited.
/// Works from the transcripts alone, so nothing is counted or stored apart
/// from them, and fixes in deleted transcripts stop counting.
public enum EditPatterns {
    /// A fix must show in this many lines…
    public static let minimumLines = 2
    /// …in this many conversations: a fix repeated inside one conversation is
    /// often about that conversation ("கொடுக்காது" is right elsewhere).
    public static let minimumSessions = 2
    static let maximumWords = 3

    /// Runs of changed words between what was heard and the user's edit.
    /// Deletions and insertions are left out: a rule needs both sides.
    public static func fixes(heard: String, edited: String) -> [EditFix] {
        let from = words(heard), to = words(edited)
        let same = { (a: String, b: String) in a.lowercased() == b.lowercased() }

        // Word-level edit distance, then walk back to find what changed.
        var cost = Array(repeating: Array(repeating: 0, count: to.count + 1), count: from.count + 1)
        for i in 0...from.count { cost[i][0] = i }
        for j in 0...to.count { cost[0][j] = j }
        for i in stride(from: 1, through: from.count, by: 1) {
            for j in stride(from: 1, through: to.count, by: 1) {
                cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                                 cost[i - 1][j - 1] + (same(from[i - 1], to[j - 1]) ? 0 : 1))
            }
        }
        var fixes: [EditFix] = []
        var heardRun: [String] = [], replacementRun: [String] = []
        func endRun() {
            if !heardRun.isEmpty, !replacementRun.isEmpty,
               heardRun.count <= maximumWords, replacementRun.count <= maximumWords {
                fixes.append(EditFix(heard: heardRun.reversed().joined(separator: " "),
                                     replacement: replacementRun.reversed().joined(separator: " ")))
            }
            heardRun = []
            replacementRun = []
        }
        var i = from.count, j = to.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, same(from[i - 1], to[j - 1]), cost[i][j] == cost[i - 1][j - 1] {
                endRun()
                i -= 1; j -= 1
            } else if i > 0, j > 0, !same(from[i - 1], to[j - 1]), cost[i][j] == cost[i - 1][j - 1] + 1 {
                heardRun.append(from[i - 1]); replacementRun.append(to[j - 1])
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                heardRun.append(from[i - 1])
                i -= 1
            } else {
                replacementRun.append(to[j - 1])
                j -= 1
            }
        }
        endRun()
        return fixes.reversed()
    }

    /// The fixes repeated often enough to offer, most frequent first. Leaves
    /// out one-letter fragments, fixes a rule already makes, and `declined`.
    public static func suggestions(in sessions: [TranscriptSession], rules: [CorrectionRule],
                                   declined: Set<EditSuggestion.ID> = []) -> [EditSuggestion] {
        var found: [EditSuggestion.ID: (fix: EditFix, lines: Set<TranscriptLine.ID>, sessions: Set<TranscriptSession.ID>)] = [:]
        for session in sessions {
            for line in session.lines {
                guard let edited = line.edited else { continue }
                for fix in fixes(heard: line.heard, edited: edited) {
                    let id = EditSuggestion.id(heard: fix.heard, replacement: fix.replacement)
                    var entry = found[id] ?? (fix, [], [])
                    entry.lines.insert(line.id)
                    entry.sessions.insert(session.id)
                    found[id] = entry
                }
            }
        }
        let corrector = TextCorrector(rules: rules)
        return found
            .filter { id, entry in
                entry.lines.count >= minimumLines && entry.sessions.count >= minimumSessions
                    && !declined.contains(id)
                    // "ஷ" is one letter: as a rule it rewrites parts of other words' spelling.
                    && entry.fix.heard.filter { !$0.isWhitespace }.count >= 2
                    && corrector.apply(to: entry.fix.heard).lowercased() != entry.fix.replacement.lowercased()
            }
            .map { EditSuggestion(heard: $0.value.fix.heard, replacement: $0.value.fix.replacement,
                                  lineCount: $0.value.lines.count, sessionIDs: $0.value.sessions) }
            .sorted { ($0.lineCount, $1.heard) > ($1.lineCount, $0.heard) }
    }

    private static func words(_ text: String) -> [String] {
        let nsText = text as NSString
        return CaptionWords.ranges(in: text).map { nsText.substring(with: $0) }
    }
}

/// What the user said to suggestions: "Don't suggest this" is saved as JSON
/// on this device; "Not now" lasts until the fix shows in one more line, and
/// only while the app runs.
@MainActor
@Observable
public final class DeclinedSuggestions {
    public private(set) var declined: Set<EditSuggestion.ID> = []
    private var postponed: [EditSuggestion.ID: Int] = [:]

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            declined = Set(saved)
        }
    }

    /// The suggestions to show now.
    public func showing(_ suggestions: [EditSuggestion]) -> [EditSuggestion] {
        suggestions.filter { !declined.contains($0.id) && $0.lineCount > (postponed[$0.id] ?? 0) }
    }

    public func decline(_ suggestion: EditSuggestion) {
        declined.insert(suggestion.id)
        save()
    }

    public func restore(_ id: EditSuggestion.ID) {
        declined.remove(id)
        save()
    }

    public func postpone(_ suggestion: EditSuggestion) {
        postponed[suggestion.id] = suggestion.lineCount
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(declined.sorted()).write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.engine.error("could not save declined suggestions: \(String(describing: error), privacy: .public)")
        }
    }
}
