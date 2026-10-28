import Foundation
import Testing
@testable import SapthamSigns

struct SignPackListingTests {
    private func testPattern() throws -> SignPack {
        try SignPackReader.open(TestPatternPackTests.fixture())
    }

    @Test func listsTheCatalogueThenExtraInstalledPacks() throws {
        let installed = [InstalledSignPack(key: "zxx-XX", pack: .success(try testPattern()))]
        let rows = SignPackListing.rows(catalogue: [isl, asl], installed: installed, activeKey: "zxx-XX", region: "US")
        #expect(rows.map(\.key) == ["ins-IN", "ase-US", "zxx-XX"])
        #expect(rows.map(\.isSuggested) == [false, true, false])
        #expect(rows.map(\.isActive) == [false, false, true])
        guard case .notDownloaded = rows[0].state else { Issue.record("ISL should be offered for download"); return }
        #expect(rows[0].bytes == 92_000_000)
        guard case .ready = rows[2].state else { Issue.record("the test pack should be ready"); return }
        #expect(rows[2].name == "Test pattern (not a sign language)")
    }

    @Test func anInstalledPackShowsItsSizeOnDisk() throws {
        let pack = try testPattern()
        let rows = SignPackListing.rows(catalogue: [], installed: [InstalledSignPack(key: "zxx-XX", pack: .success(pack))],
                                        activeKey: nil, region: nil)
        #expect(rows.first?.bytes == pack.manifest.files.reduce(0) { $0 + $1.bytes })
    }

    @Test func aDamagedPackKeepsItsCatalogueName() {
        let installed = [InstalledSignPack(key: "ase-US", pack: .failure(.damaged("media/water.mp4")))]
        let rows = SignPackListing.rows(catalogue: [asl], installed: installed, activeKey: nil, region: "US")
        #expect(rows.count == 1)
        #expect(rows[0].name == "American Sign Language")
        guard case .damaged = rows[0].state else { Issue.record("should be damaged"); return }
        #expect(rows[0].bytes == nil)
    }

    @Test func theChosenPackIsActiveOnlyWhenItVerifies() throws {
        let good = InstalledSignPack(key: "zxx-XX", pack: .success(try testPattern()))
        let bad = InstalledSignPack(key: "ase-US", pack: .failure(.damaged("x")))
        #expect(SignPackListing.activeKey(installed: [bad, good], chosenKey: "zxx-XX") == "zxx-XX")
        #expect(SignPackListing.activeKey(installed: [bad, good], chosenKey: "ase-US") == "zxx-XX")
        #expect(SignPackListing.activeKey(installed: [bad, good], chosenKey: nil) == "zxx-XX")
        #expect(SignPackListing.activeKey(installed: [bad], chosenKey: nil) == nil)
    }
}
