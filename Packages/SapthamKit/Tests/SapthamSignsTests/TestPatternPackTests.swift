import Foundation
import Testing
@testable import SapthamSigns

/// The generated test-pattern pack in Fixtures (ADR 0003 P10-S8), opened the
/// way the app opens a downloaded pack. Rebuild it with
/// `swift run signpack testpattern <dir>` then `swift run signpack build`.
struct TestPatternPackTests {
    static func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/test-pattern-pack", withExtension: nil))
    }

    @Test func opensAndVerifies() throws {
        let pack = try SignPackReader.open(Self.fixture())
        #expect(pack.manifest.packId == "test-XX-pattern-1")
        #expect(pack.manifest.defaultForRegions.isEmpty)
        #expect(pack.entries.map(\.idGloss) == ["WATER", "HELLO", "BANK", "TEA"])
        #expect(pack.entries.allSatisfy { $0.media.durationMs == 1200 && $0.media.poster != nil })
    }

    @Test func staysSmall() throws {
        let pack = try SignPackReader.open(Self.fixture())
        // ADR 0003 P10-S8: the fixture stays under 500 KB.
        #expect(pack.manifest.files.map(\.bytes).reduce(0, +) < 500_000)
    }

    @Test func looksUpTamilAndEnglishWords() async throws {
        let lookup = SignLookup(pack: try SignPackReader.open(Self.fixture()))
        #expect(await lookup.signs(for: "வாட்டர்").map(\.entry.idGloss) == ["WATER"])
        #expect(await lookup.signs(for: "Hello!").map(\.entry.idGloss) == ["HELLO"])
        #expect(await lookup.signs(for: "bank").map(\.note) == ["money", "river"])
        // TEA is a draft.
        #expect(await lookup.signs(for: "tea").isEmpty)
    }
}
