import Foundation

/// Turns a caption word, or a form listed in a pack, into the key signs are
/// matched on (ADR 0003 §2.3 A). Matching is exact on this key: no stemming,
/// no synonyms, no near matches.
///
/// Hidden coupling: the `signpack` builder normalises every listed form with
/// this same type when it builds a pack, and the app normalises the tapped
/// word with it at lookup. If the two ever differ, a form that matched when
/// the pack was built silently misses on the device. Packs outlive app
/// versions, so each manifest stamps `normaliserVersion` and the reader
/// refuses a pack built with a different one. Any change to `normalise` that
/// can change a key must bump `version`.
public enum SignWordNormaliser {
    public static let version = 1

    /// Joiners the Tamil model and keyboards insert or leave out inside a
    /// word without changing it.
    private static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
    private static let curlyApostrophes: Set<Unicode.Scalar> = ["\u{2018}", "\u{2019}"]
    private static let edges = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)

    public static func normalise(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.precomposedStringWithCanonicalMapping.unicodeScalars where !joiners.contains(scalar) {
            scalars.append(curlyApostrophes.contains(scalar) ? "'" : scalar)
        }
        // Case folding only: diacritic folding would strip Tamil vowel signs.
        return String(scalars)
            .folding(options: .caseInsensitive, locale: nil)
            .trimmingCharacters(in: edges)
            .precomposedStringWithCanonicalMapping
    }
}
