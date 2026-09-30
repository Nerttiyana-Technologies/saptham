import Foundation
import Observation

/// "When the recogniser writes `heard`, show `replacement` instead."
public struct CorrectionRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var heard: String
    public var replacement: String
    public let createdAt: Date

    public init(id: UUID = UUID(), heard: String, replacement: String, createdAt: Date = Date()) {
        self.id = id
        self.heard = heard
        self.replacement = replacement
        self.createdAt = createdAt
    }
}

/// Applies correction rules to caption text. A value type so it can be
/// handed to any thread as a snapshot.
///
/// Matching is case-insensitive, on whole words only ("cat" never changes
/// "category"), tolerant of extra spaces inside phrases, and longest phrase
/// first so "butt theories" wins over "butt".
public struct TextCorrector: Sendable {
    private let rules: [(pattern: NSRegularExpression, replacement: String)]

    public init(rules: [CorrectionRule]) {
        self.rules = rules
            .filter { !$0.heard.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
            .compactMap { rule in
                let words = rule.heard.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                let body = words.joined(separator: "\\s+")
                guard let pattern = try? NSRegularExpression(
                    pattern: "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])",
                    options: [.caseInsensitive]) else { return nil }
                return (pattern, rule.replacement)
            }
    }

    public static let none = TextCorrector(rules: [])

    public func apply(to text: String) -> String {
        var result = text
        for rule in rules {
            let matches = rule.pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: Self.matchingCase(of: result[range], rule.replacement))
            }
        }
        return result
    }

    /// Keeps a sentence-initial capital: "Sabtham shows" → "Saptham shows",
    /// and "caffeine" at the start of a line → "Captioning".
    private static func matchingCase(of original: Substring, _ replacement: String) -> String {
        guard let first = original.first, first.isUppercase,
              let replacementFirst = replacement.first, replacementFirst.isLowercase
        else { return replacement }
        return replacementFirst.uppercased() + replacement.dropFirst()
    }
}

/// The user's correction rules, saved as JSON on this device.
@MainActor
@Observable
public final class CorrectionBook {
    public private(set) var rules: [CorrectionRule] = []
    /// Snapshot of the current rules for applying to text.
    public private(set) var corrector = TextCorrector.none

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([CorrectionRule].self, from: data) {
            rules = saved
        }
        corrector = TextCorrector(rules: rules)
    }

    /// Adds a rule, or updates the existing rule for the same `heard` text.
    @discardableResult
    public func add(heard: String, replacement: String) -> CorrectionRule {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = rules.firstIndex(where: { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) {
            rules[index].replacement = replacement
            save()
            return rules[index]
        }
        let rule = CorrectionRule(heard: heard, replacement: replacement)
        rules.append(rule)
        save()
        return rule
    }

    public func update(_ rule: CorrectionRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    public func remove(_ id: CorrectionRule.ID) {
        rules.removeAll { $0.id == id }
        save()
    }

    public func apply(to text: String) -> String {
        corrector.apply(to: text)
    }

    private func save() {
        corrector = TextCorrector(rules: rules)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.engine.error("could not save corrections: \(String(describing: error), privacy: .public)")
        }
    }
}
