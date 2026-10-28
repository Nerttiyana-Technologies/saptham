import Foundation
import Testing
@testable import SapthamSigns

struct SignPackModelTests {
    // The two mocks from ADR 0003 §2.6, with made-up values.
    static let manifest = """
    {
      "formatVersion": 1,
      "packId": "ase-US-commissioned-2027.1",
      "signLanguage": "ase",
      "signLanguageName": "American Sign Language",
      "variety": "US / English Canada (not LSQ)",
      "region": "US",
      "defaultForRegions": ["US", "CA"],
      "headwordLanguages": ["en", "ta"],
      "normaliserVersion": 1,
      "source": { "organisation": "Commissioned by Nerttiyana Technologies", "kind": "commissioned" },
      "licence": { "id": "LicenseRef-Saptham-Commissioned-1", "file": "LICENSE.txt" },
      "contentUse": "displayOnly",
      "review": { "panel": "Deaf ASL review panel", "signedOff": "2027-03-14" },
      "version": "2027.1",
      "minAppVersion": "1.4",
      "files": [
        { "path": "entries.json", "sha256": "9f2c", "bytes": 48211 },
        { "path": "media/ASL-WATER-1.mp4", "sha256": "41ab", "bytes": 212480 }
      ]
    }
    """

    static let entries = """
    [{
      "idGloss": "WATER",
      "lemmaId": "WATER",
      "variantOf": null,
      "regionalTag": null,
      "senses": [
        { "note": "drinking water",
          "forms": [ { "lang": "en", "text": ["water", "waters"] },
                     { "lang": "ta", "text": ["தண்ணீர்", "தண்ணி", "தண்ணீரை", "வாட்டர்"] } ] }
      ],
      "media": { "file": "media/ASL-WATER-1.mp4", "poster": "media/ASL-WATER-1.jpg", "durationMs": 1800, "loop": true },
      "signerId": "S03",
      "signerCredit": "Signed by S03",
      "clipLicence": null,
      "reviewStatus": "approved"
    }]
    """

    private func json(_ text: String, editing edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func decodesTheManifestMock() throws {
        let m = try SignPackManifest.decode(Data(Self.manifest.utf8))
        #expect(m.packId == "ase-US-commissioned-2027.1")
        #expect(m.signLanguage == "ase")
        #expect(m.defaultForRegions == ["US", "CA"])
        #expect(m.normaliserVersion == 1)
        #expect(m.contentUse == .displayOnly)
        #expect(m.review?.signedOff == "2027-03-14")
        #expect(m.files.map(\.path) == ["entries.json", "media/ASL-WATER-1.mp4"])
        #expect(m.files.last?.bytes == 212480)
    }

    @Test func decodesTheEntryMock() throws {
        let entries = try SignEntry.decodeAll(Data(Self.entries.utf8))
        let water = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(water.idGloss == "WATER")
        #expect(water.variantOf == nil)
        #expect(water.senses.first?.note == "drinking water")
        #expect(water.senses.first?.forms.first { $0.lang == "ta" }?.text.contains("வாட்டர்") == true)
        #expect(water.media.durationMs == 1800)
        #expect(water.media.loop)
        #expect(water.reviewStatus == .approved)
    }

    @Test func rejectsMissingRequiredFields() throws {
        for key in ["packId", "normaliserVersion", "files", "licence"] {
            let data = try json(Self.manifest) { $0[key] = nil }
            #expect(throws: SignPackError.malformed(file: "manifest.json")) { try SignPackManifest.decode(data) }
        }
        let noMedia = Self.entries.replacingOccurrences(of: "\"media\"", with: "\"film\"")
        #expect(throws: SignPackError.malformed(file: "entries.json")) { try SignEntry.decodeAll(Data(noMedia.utf8)) }
        #expect(throws: SignPackError.malformed(file: "manifest.json")) { try SignPackManifest.decode(Data("not json".utf8)) }
    }

    @Test func ignoresUnknownFields() throws {
        let data = try json(Self.manifest) { $0["futureField"] = ["anything": 1] }
        #expect(try SignPackManifest.decode(data).packId == "ase-US-commissioned-2027.1")
        let entry = Self.entries.replacingOccurrences(of: "\"lemmaId\"", with: "\"handshape\": \"B\", \"lemmaId\"")
        #expect(try SignEntry.decodeAll(Data(entry.utf8)).count == 1)
    }

    @Test func refusesANewerFormat() throws {
        // Even when the newer format has dropped fields this app requires.
        let data = try json(Self.manifest) { $0["formatVersion"] = 2; $0["files"] = nil }
        #expect(throws: SignPackError.newerFormat(2)) { try SignPackManifest.decode(data) }
    }

    @Test func missingOrUnknownContentUseIsDisplayOnly() throws {
        let missing = try json(Self.manifest) { $0["contentUse"] = nil }
        #expect(try SignPackManifest.decode(missing).contentUse == .displayOnly)
        let unknown = try json(Self.manifest) { $0["contentUse"] = "anything" }
        #expect(try SignPackManifest.decode(unknown).contentUse == .displayOnly)
        let training = try json(Self.manifest) { $0["contentUse"] = "trainingPermitted" }
        #expect(try SignPackManifest.decode(training).contentUse == .trainingPermitted)
    }

    @Test func draftPackHasNoReview() throws {
        let data = try json(Self.manifest) { $0["review"] = nil }
        #expect(try SignPackManifest.decode(data).review == nil)
    }

    @Test func unknownReviewStatusIsNotApproved() throws {
        let entry = Self.entries.replacingOccurrences(of: "\"approved\"", with: "\"on hold\"")
        let decoded = try #require(try SignEntry.decodeAll(Data(entry.utf8)).first)
        #expect(decoded.reviewStatus == .unrecognised("on hold"))
        #expect(decoded.reviewStatus != .approved)
    }
}

struct SignPackErrorMessageTests {
    @Test func usesTheADRWording() {
        #expect(SignPackError.damaged("media/x.mp4").userMessage == "This pack is damaged; delete and download again.")
        #expect(SignPackError.unlistedFile("x").userMessage == "This pack is damaged; delete and download again.")
        #expect(SignPackError.newerFormat(2).userMessage == "Update Saptham to use this pack.")
        #expect(!SignPackError.damaged("media/x.mp4").userMessage.contains("media"))
    }
}
