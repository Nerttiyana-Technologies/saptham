import Foundation

/// The packs the app offers, from the bundled `SignPackCatalogue.json`
/// (ADR 0003 §2.8). Lets Settings list packs, with their size, before any is
/// downloaded.
///
/// Hidden coupling: each `packId` here must equal an asset pack ID uploaded
/// in App Store Connect, or the app offers a pack it can't download. Nothing
/// in code can check that; the release checklist does (ADR 0003 P10-S21).
public struct SignPackCatalogue: Codable, Equatable, Sendable {
    public static let fileName = "SignPackCatalogue.json"

    public let formatVersion: Int
    public let packs: [Pack]

    public struct Pack: Codable, Equatable, Sendable {
        /// Equals the pack's `manifest.json` `packId`, version included.
        public let packId: String
        /// ISO 639-3.
        public let signLanguage: String
        public let signLanguageName: String
        public let variety: String
        /// ISO 3166-1 alpha-2.
        public let region: String
        public let defaultForRegions: [String]
        /// Shown before downloading.
        public let downloadBytes: Int

        /// Stays the same across pack versions, so a user's choice survives
        /// an update: for example `ase-US`.
        public var choiceKey: String { "\(signLanguage)-\(region)" }
    }

    public init(formatVersion: Int = 1, packs: [Pack]) throws {
        self.formatVersion = formatVersion
        self.packs = packs
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        packs = try c.decode([Pack].self, forKey: .packs)
    }

    public static func decode(_ data: Data) throws -> SignPackCatalogue {
        let catalogue: SignPackCatalogue
        do { catalogue = try JSONDecoder().decode(SignPackCatalogue.self, from: data) } catch {
            throw SignPackError.malformed(file: fileName)
        }
        try catalogue.validate()
        return catalogue
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// One pack per ID and per sign language and region, and at most one pack
    /// suggested for any region, so the suggestion is never ambiguous.
    private func validate() throws {
        var ids: Set<String> = [], keys: Set<String> = [], regions: Set<String> = []
        for pack in packs {
            guard ids.insert(pack.packId).inserted else { throw SignPackError.duplicateCatalogueEntry(pack.packId) }
            guard keys.insert(pack.choiceKey).inserted else { throw SignPackError.duplicateCatalogueEntry(pack.choiceKey) }
            for region in pack.defaultForRegions.map({ $0.uppercased() }) {
                guard regions.insert(region).inserted else { throw SignPackError.duplicateCatalogueEntry(region) }
            }
        }
    }
}
