import Foundation
import Testing
@testable import SapthamSigns

struct SignWordNormaliserTests {
    private let key = SignWordNormaliser.normalise

    @Test func versionIsOne() {
        #expect(SignWordNormaliser.version == 1)
    }

    @Test func tamilMatchesWithAndWithoutJoiners() {
        #expect(key("வாட்\u{200D}டர்") == key("வாட்டர்"))
        #expect(key("க்\u{200C}ஷ") == key("க்ஷ"))
        #expect(key("வாட்டர்") == "வாட்டர்")
    }

    @Test func leavesTamilVowelSignsAlone() {
        // ீ, ு, ை and the pulli are marks, not punctuation or diacritics to fold.
        #expect(key("தண்ணீர்") == "தண்ணீர்")
        #expect(key("வீட்டுக்கு") == "வீட்டுக்கு")
        #expect(key("தண்ணீரை") != key("தண்ணீர்"))
    }

    @Test func composesTamilToNFC() {
        // கொ written as க + ெ + ா rather than க + ொ. Compared as scalars, since
        // String == already treats the two as equal but dictionary keys built
        // from other tools may not.
        #expect(Array(key("\u{0B95}\u{0BC6}\u{0BBE}").unicodeScalars) == ["\u{0B95}", "\u{0BCA}"])
    }

    @Test func foldsCaseAndTrimsEdgePunctuation() {
        #expect(key("Water,") == "water")
        #expect(key("\"WATER!\"") == "water")
        #expect(key("  (water)  ") == "water")
        #expect(key("தண்ணீர்?") == "தண்ணீர்")
    }

    @Test func straightensCurlyApostrophes() {
        #expect(key("don’t") == "don't")
        #expect(key("Don‘t") == key("don't"))
    }

    @Test func keepsInnerPunctuationAndWords() {
        #expect(key("ice-cream") == "ice-cream")
        #expect(key("thank you") == "thank you")
        #expect(key("!!!") == "")
    }
}
