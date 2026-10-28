import Foundation
import Testing
@testable import SapthamSigns

private final class MemoryStore: SignPackChoiceStore, @unchecked Sendable {
    var chosenKey: String?
}

struct SignPackChooserTests {
    private let catalogue = try! SignPackCatalogue(packs: [isl, asl])

    @Test func suggestsByRegion() {
        let chooser = SignPackChooser(catalogue: catalogue, store: MemoryStore())
        #expect(chooser.suggested(forRegion: "IN") == isl)
        #expect(chooser.suggested(forRegion: "US") == asl)
        #expect(chooser.suggested(forRegion: "CA") == asl)
        #expect(chooser.suggested(forRegion: "ca") == asl)
        #expect(chooser.suggested(forRegion: "MY") == nil)
        #expect(chooser.suggested(forRegion: nil) == nil)
    }

    @Test func theUsersChoiceWinsAndPersists() {
        let store = MemoryStore()
        SignPackChooser(catalogue: catalogue, store: store).choose(isl)
        // A new chooser, as after relaunch, reads the same store.
        let later = SignPackChooser(catalogue: catalogue, store: store)
        #expect(later.activePack(region: "US") == isl)
        later.choose(nil)
        #expect(later.activePack(region: "US") == asl)
        #expect(later.activePack(region: "MY") == nil)
    }

    @Test func aChoiceSurvivesAPackUpdate() throws {
        let store = MemoryStore()
        SignPackChooser(catalogue: catalogue, store: store).choose(isl)
        let updated = pack("ins-IN-licensed-2027.2", "ins", "IN", defaultFor: ["IN"])
        let chooser = SignPackChooser(catalogue: try SignPackCatalogue(packs: [updated, asl]), store: store)
        #expect(chooser.activePack(region: "US")?.packId == "ins-IN-licensed-2027.2")
    }

    @Test func aChoiceNoLongerOfferedFallsBackToTheSuggestion() {
        let store = MemoryStore()
        store.chosenKey = "xml-MY"
        #expect(SignPackChooser(catalogue: catalogue, store: store).activePack(region: "IN") == isl)
    }

    @Test func userDefaultsStoreKeepsTheChoice() throws {
        let suite = "signs-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsSignPackChoiceStore(defaults: defaults).chosenKey = "ase-US"
        #expect(UserDefaultsSignPackChoiceStore(defaults: defaults).chosenKey == "ase-US")
    }
}
