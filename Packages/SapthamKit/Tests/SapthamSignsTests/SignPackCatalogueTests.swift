import Foundation
import Testing
@testable import SapthamSigns

func pack(_ id: String, _ language: String, _ region: String, defaultFor regions: [String]) -> SignPackCatalogue.Pack {
    SignPackCatalogue.Pack(packId: id, signLanguage: language, signLanguageName: language == "ins" ? "Indian Sign Language" : "American Sign Language",
                           variety: region, region: region, defaultForRegions: regions, downloadBytes: 92_000_000)
}

let isl = pack("ins-IN-licensed-2027.1", "ins", "IN", defaultFor: ["IN"])
let asl = pack("ase-US-commissioned-2027.1", "ase", "US", defaultFor: ["US", "CA"])

struct SignPackCatalogueTests {
    @Test func roundTrips() throws {
        let catalogue = try SignPackCatalogue(packs: [isl, asl])
        #expect(try SignPackCatalogue.decode(catalogue.encoded()) == catalogue)
    }

    @Test func decodesTheBundledShape() throws {
        let json = """
        { "formatVersion": 1, "packs": [ { "packId": "ins-IN-licensed-2027.1", "signLanguage": "ins",
          "signLanguageName": "Indian Sign Language", "variety": "Tamil Nadu", "region": "IN",
          "defaultForRegions": ["IN"], "downloadBytes": 84000000, "futureField": true } ] }
        """
        let catalogue = try SignPackCatalogue.decode(Data(json.utf8))
        #expect(catalogue.packs.first?.choiceKey == "ins-IN")
        #expect(throws: SignPackError.malformed(file: "SignPackCatalogue.json")) {
            try SignPackCatalogue.decode(Data("{\"packs\": 1}".utf8))
        }
    }

    @Test func rejectsDuplicatePackIDs() throws {
        let json = try SignPackCatalogue(packs: [isl]).encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let packs = try #require(object["packs"] as? [Any])
        object["packs"] = packs + packs
        let doubled = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SignPackError.duplicateCatalogueEntry("ins-IN-licensed-2027.1")) { try SignPackCatalogue.decode(doubled) }
    }

    @Test func rejectsTwoVersionsOfOnePackAndTwoSuggestionsForARegion() {
        let newer = pack("ins-IN-licensed-2027.2", "ins", "IN", defaultFor: [])
        #expect(throws: SignPackError.duplicateCatalogueEntry("ins-IN")) { try SignPackCatalogue(packs: [isl, newer]) }
        let rival = pack("bfi-GB-commissioned-2028.1", "bfi", "GB", defaultFor: ["ca"])
        #expect(throws: SignPackError.duplicateCatalogueEntry("CA")) { try SignPackCatalogue(packs: [asl, rival]) }
    }
}
