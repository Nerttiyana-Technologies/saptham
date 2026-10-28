import Foundation

/// One sign for a word: the sign, and the sense of it the word reached.
public struct SignMatch: Equatable, Sendable {
    public let entry: SignEntry
    public let sense: SignSense
    /// For the sheet: "American Sign Language".
    public let signLanguageName: String

    /// The sense's note, shown when a word has more than one sign.
    public var note: String? { sense.note }
}

/// Finds the signs a caption word reaches in one loaded pack (ADR 0003 §2.3 A).
/// Only an exact form the pack lists, after `SignWordNormaliser`, reaches a
/// sign: no near matches, no stems, no synonyms. A word that isn't listed
/// gets no sign, never a guess.
///
/// Callers pass a word and get matches; the looked-up word is never logged
/// or kept.
public actor SignLookup {
    private let index: [String: [SignMatch]]

    /// - Parameter includeUnapproved: shows draft and rejected signs too, for
    ///   a Deaf panel reviewing a draft pack in a Debug build. Off otherwise.
    public init(pack: SignPack, includeUnapproved: Bool = false) {
        var index: [String: [SignMatch]] = [:]
        for entry in pack.entries where includeUnapproved || entry.reviewStatus == .approved {
            for sense in entry.senses {
                let match = SignMatch(entry: entry, sense: sense, signLanguageName: pack.manifest.signLanguageName)
                // A form listed in two languages (a Tamil-script loanword, say)
                // still reaches this sense once.
                let keys = Set(sense.forms.flatMap(\.text).map(SignWordNormaliser.normalise)).subtracting([""])
                for key in keys {
                    index[key, default: []].append(match)
                }
            }
        }
        self.index = index
    }

    /// Every sense the word reaches, in pack order; empty when there's none.
    public func signs(for word: String) -> [SignMatch] {
        index[SignWordNormaliser.normalise(word)] ?? []
    }
}
