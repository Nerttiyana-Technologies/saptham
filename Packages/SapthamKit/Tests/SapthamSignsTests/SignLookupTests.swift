import Foundation
import Testing
@testable import SapthamSigns

struct SignLookupTests {
    private static let manifest = try! SignPackManifest.decode(Data(SignPackModelTests.manifest.utf8))

    private func entry(_ gloss: String, _ senses: [(note: String?, forms: [String: [String]])],
                       status: ReviewStatus = .approved) -> SignEntry {
        SignEntry(idGloss: gloss, lemmaId: gloss, variantOf: nil, regionalTag: nil,
                  senses: senses.map { sense in
                      SignSense(note: sense.note, forms: sense.forms.sorted { $0.key < $1.key }
                          .map { SignSense.Forms(lang: $0.key, text: $0.value) })
                  },
                  media: SignMedia(file: "media/\(gloss).mp4", poster: nil, durationMs: 1500, loop: true),
                  signerId: "S01", signerCredit: "Signed by S01", clipLicence: nil, reviewStatus: status)
    }

    private func lookup(_ entries: [SignEntry], includeUnapproved: Bool = false) -> SignLookup {
        SignLookup(pack: SignPack(manifest: Self.manifest, entries: entries, folder: URL(filePath: "/tmp")),
                   includeUnapproved: includeUnapproved)
    }

    private var water: SignEntry {
        entry("WATER", [("drinking water", ["en": ["water", "waters"], "ta": ["தண்ணீர்", "தண்ணி", "தண்ணீரை", "வாட்டர்"]])])
    }

    @Test func findsExactListedFormsOnly() async {
        let signs = lookup([water])
        #expect(await signs.signs(for: "water").map(\.entry.idGloss) == ["WATER"])
        #expect(await signs.signs(for: "Water,").map(\.entry.idGloss) == ["WATER"])
        #expect(await signs.signs(for: "தண்ணீரை").count == 1)
        // Not listed, so no sign, however close.
        #expect(await signs.signs(for: "watery").isEmpty)
        #expect(await signs.signs(for: "wate").isEmpty)
        #expect(await signs.signs(for: "தண்ணீருக்கு").isEmpty)
    }

    @Test func tamilScriptLoanwordReachesTheSign() async {
        let signs = lookup([water])
        #expect(await signs.signs(for: "வாட்டர்").first?.note == "drinking water")
        #expect(await signs.signs(for: "வாட்\u{200D}டர்").count == 1)
    }

    @Test func twoSensesReturnTwoMatches() async {
        let bank = entry("BANK", [("money", ["en": ["bank"]]), ("river", ["en": ["bank", "riverbank"]])])
        let signs = lookup([bank])
        #expect(await signs.signs(for: "bank").map(\.note) == ["money", "river"])
        #expect(await signs.signs(for: "riverbank").map(\.note) == ["river"])
    }

    @Test func twoSignsForOneWordComeInPackOrder() async {
        let a = entry("HELLO-1", [(nil, ["en": ["hello"]])])
        let b = entry("HELLO-2", [(nil, ["en": ["hello"], "ta": ["ஹலோ"]])])
        let signs = lookup([a, b])
        #expect(await signs.signs(for: "Hello").map(\.entry.idGloss) == ["HELLO-1", "HELLO-2"])
        #expect(await signs.signs(for: "ஹலோ").map(\.entry.idGloss) == ["HELLO-2"])
    }

    @Test func aFormInTwoLanguagesMatchesOnce() async {
        let ok = entry("OK", [(nil, ["en": ["ok"], "ta": ["ok", "ஓகே"]])])
        #expect(await lookup([ok]).signs(for: "OK").count == 1)
    }

    @Test func unknownAndEmptyWordsReturnNothing() async {
        let signs = lookup([water])
        #expect(await signs.signs(for: "elephant").isEmpty)
        #expect(await signs.signs(for: "").isEmpty)
        #expect(await signs.signs(for: "!!!").isEmpty)
    }

    @Test func onlyApprovedSignsUnlessReviewing() async {
        let draft = entry("TEA", [(nil, ["en": ["tea"]])], status: .draft)
        let odd = entry("COFFEE", [(nil, ["en": ["coffee"]])], status: .unrecognised("on hold"))
        #expect(await lookup([draft, odd]).signs(for: "tea").isEmpty)
        #expect(await lookup([draft, odd]).signs(for: "coffee").isEmpty)
        #expect(await lookup([draft, odd], includeUnapproved: true).signs(for: "tea").count == 1)
    }

    @Test func carriesThePackLanguageName() async {
        #expect(await lookup([water]).signs(for: "water").first?.signLanguageName == "American Sign Language")
    }

    @Test func indexesTenThousandSignsQuickly() async {
        let entries = (0..<10_000).map { i in
            entry("SIGN-\(i)", [(nil, ["en": ["word\(i)", "words\(i)"], "ta": ["சொல்\(i)", "சொல்லை\(i)"]])])
        }
        let start = ContinuousClock.now
        let signs = lookup(entries)
        let elapsed = ContinuousClock.now - start
        #expect(await signs.signs(for: "சொல்லை9999").map(\.entry.idGloss) == ["SIGN-9999"])
        // ADR 0003 P10-S4 asks under 1 s on a Mac (estimate). Debug build.
        #expect(elapsed < .seconds(1))
    }
}
