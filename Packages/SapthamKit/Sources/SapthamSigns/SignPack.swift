import Foundation

/// What a sign-language pack is, from its `manifest.json` (ADR 0003 §2.6).
/// One pack is one sign language, one regional variety, one content source.
/// Fields the app doesn't know are ignored; a newer `formatVersion` is refused.
public struct SignPackManifest: Codable, Equatable, Sendable {
    /// The newest pack format this app reads.
    public static let supportedFormatVersion = 1

    public let formatVersion: Int
    /// For example `ase-US-commissioned-2027.1`.
    public let packId: String
    /// ISO 639-3: `ins` ISL, `ase` ASL, …
    public let signLanguage: String
    public let signLanguageName: String
    /// Shown with the name, for example "US / English Canada (not LSQ)".
    public let variety: String
    /// ISO 3166-1 alpha-2.
    public let region: String
    /// Regions where this pack is suggested when the feature is turned on.
    public let defaultForRegions: [String]
    /// Languages the pack lists word forms for, for example `en`, `ta`.
    public let headwordLanguages: [String]
    /// Must equal `SignWordNormaliser.version`, or the forms may not match.
    public let normaliserVersion: Int
    public let source: Source
    public let licence: Licence
    public let contentUse: ContentUse
    /// Absent on a draft pack that a Deaf panel hasn't signed off yet.
    public let review: Review?
    public let version: String
    public let minAppVersion: String
    /// Every other file in the pack, with its hash and size.
    public let files: [File]

    public init(formatVersion: Int, packId: String, signLanguage: String, signLanguageName: String, variety: String,
                region: String, defaultForRegions: [String], headwordLanguages: [String], normaliserVersion: Int,
                source: Source, licence: Licence, contentUse: ContentUse, review: Review?, version: String,
                minAppVersion: String, files: [File]) {
        self.formatVersion = formatVersion
        self.packId = packId
        self.signLanguage = signLanguage
        self.signLanguageName = signLanguageName
        self.variety = variety
        self.region = region
        self.defaultForRegions = defaultForRegions
        self.headwordLanguages = headwordLanguages
        self.normaliserVersion = normaliserVersion
        self.source = source
        self.licence = licence
        self.contentUse = contentUse
        self.review = review
        self.version = version
        self.minAppVersion = minAppVersion
        self.files = files
    }

    public struct Source: Codable, Equatable, Sendable {
        public let organisation: String
        /// `commissioned` or `licensed`.
        public let kind: String

        public init(organisation: String, kind: String) {
            self.organisation = organisation
            self.kind = kind
        }
    }

    public struct Licence: Codable, Equatable, Sendable {
        /// SPDX identifier or `LicenseRef-…`.
        public let id: String
        /// Path of the licence text inside the pack.
        public let file: String

        public init(id: String, file: String) {
            self.id = id
            self.file = file
        }
    }

    public struct Review: Codable, Equatable, Sendable {
        public let panel: String
        /// ISO date, `yyyy-MM-dd`.
        public let signedOff: String

        public init(panel: String, signedOff: String) {
            self.panel = panel
            self.signedOff = signedOff
        }
    }

    public struct File: Codable, Equatable, Sendable {
        /// Relative to the pack folder.
        public let path: String
        /// Lowercase hex SHA-256.
        public let sha256: String
        public let bytes: Int

        public init(path: String, sha256: String, bytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    /// Reads a manifest, checking `formatVersion` before anything else, since
    /// a newer format may have changed the very fields this app requires.
    public static func decode(_ data: Data) throws -> SignPackManifest {
        struct Probe: Decodable { let formatVersion: Int }
        let probe: Probe
        do { probe = try JSONDecoder().decode(Probe.self, from: data) } catch {
            throw SignPackError.malformed(file: "manifest.json")
        }
        guard probe.formatVersion <= supportedFormatVersion else {
            throw SignPackError.newerFormat(probe.formatVersion)
        }
        do { return try JSONDecoder().decode(SignPackManifest.self, from: data) } catch {
            throw SignPackError.malformed(file: "manifest.json")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        packId = try c.decode(String.self, forKey: .packId)
        signLanguage = try c.decode(String.self, forKey: .signLanguage)
        signLanguageName = try c.decode(String.self, forKey: .signLanguageName)
        variety = try c.decode(String.self, forKey: .variety)
        region = try c.decode(String.self, forKey: .region)
        defaultForRegions = try c.decode([String].self, forKey: .defaultForRegions)
        headwordLanguages = try c.decode([String].self, forKey: .headwordLanguages)
        normaliserVersion = try c.decode(Int.self, forKey: .normaliserVersion)
        source = try c.decode(Source.self, forKey: .source)
        licence = try c.decode(Licence.self, forKey: .licence)
        // Missing means the stricter use, so training code can't be let in by omission.
        contentUse = try c.decodeIfPresent(ContentUse.self, forKey: .contentUse) ?? .displayOnly
        review = try c.decodeIfPresent(Review.self, forKey: .review)
        version = try c.decode(String.self, forKey: .version)
        minAppVersion = try c.decode(String.self, forKey: .minAppVersion)
        files = try c.decode([File].self, forKey: .files)
    }
}

/// What a pack's content may be used for. Any future training code must
/// refuse `displayOnly`.
public enum ContentUse: String, Codable, Equatable, Sendable {
    case displayOnly
    case trainingPermitted

    /// An unknown value reads as `displayOnly`, the stricter use.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContentUse(rawValue: raw) ?? .displayOnly
    }
}

/// One sign in `entries.json` (the file is a JSON array of these).
public struct SignEntry: Codable, Equatable, Sendable {
    /// The sign's gloss, for example `WATER`.
    public let idGloss: String
    public let lemmaId: String
    /// The `idGloss` this sign is a variant of, if any.
    public let variantOf: String?
    public let regionalTag: String?
    public let senses: [SignSense]
    public let media: SignMedia
    /// Pseudonymous; never a real name.
    public let signerId: String
    /// The credit the signer chose, a name only if they opted in.
    public let signerCredit: String
    /// Set when this clip's licence differs from the pack's.
    public let clipLicence: String?
    public let reviewStatus: ReviewStatus

    public init(idGloss: String, lemmaId: String, variantOf: String?, regionalTag: String?, senses: [SignSense],
                media: SignMedia, signerId: String, signerCredit: String, clipLicence: String?, reviewStatus: ReviewStatus) {
        self.idGloss = idGloss
        self.lemmaId = lemmaId
        self.variantOf = variantOf
        self.regionalTag = regionalTag
        self.senses = senses
        self.media = media
        self.signerId = signerId
        self.signerCredit = signerCredit
        self.clipLicence = clipLicence
        self.reviewStatus = reviewStatus
    }

    /// Reads `entries.json`.
    public static func decodeAll(_ data: Data) throws -> [SignEntry] {
        do { return try JSONDecoder().decode([SignEntry].self, from: data) } catch {
            throw SignPackError.malformed(file: "entries.json")
        }
    }
}

/// One meaning of a sign and the exact written forms that reach it (§2.3 A).
public struct SignSense: Codable, Equatable, Sendable {
    /// Shown when a word has more than one sense, for example "drinking water".
    public let note: String?
    public let forms: [Forms]

    public init(note: String?, forms: [Forms]) {
        self.note = note
        self.forms = forms
    }

    public struct Forms: Codable, Equatable, Sendable {
        /// BCP 47 language, for example `en`, `ta`.
        public let lang: String
        public let text: [String]

        public init(lang: String, text: [String]) {
            self.lang = lang
            self.text = text
        }
    }
}

public struct SignMedia: Codable, Equatable, Sendable {
    /// Relative to the pack folder.
    public let file: String
    public let poster: String?
    public let durationMs: Int
    public let loop: Bool

    public init(file: String, poster: String?, durationMs: Int, loop: Bool) {
        self.file = file
        self.poster = poster
        self.durationMs = durationMs
        self.loop = loop
    }
}

/// Where a sign is in the Deaf panel's review. Only `approved` signs are shown.
public enum ReviewStatus: Codable, Equatable, Sendable {
    case approved
    case draft
    case rejected
    /// A status this app doesn't know; treated as not approved.
    case unrecognised(String)

    public init(raw: String) {
        switch raw {
        case "approved": self = .approved
        case "draft": self = .draft
        case "rejected": self = .rejected
        default: self = .unrecognised(raw)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .approved: try c.encode("approved")
        case .draft: try c.encode("draft")
        case .rejected: try c.encode("rejected")
        case .unrecognised(let raw): try c.encode(raw)
        }
    }
}

/// Why a pack can't be used. Never carries a looked-up word; paths are the
/// pack's own relative paths.
public enum SignPackError: Error, Equatable, Sendable {
    /// The file is missing required fields or isn't valid JSON.
    case malformed(file: String)
    /// The pack is newer than this app: "Update Saptham to use this pack".
    case newerFormat(Int)
    /// Built with a different `SignWordNormaliser`, so its forms may not match.
    case normaliserMismatch(pack: Int, app: Int)
    /// Listed or referenced, but not in the folder.
    case missingFile(String)
    /// In the folder, but not listed in the manifest.
    case unlistedFile(String)
    /// Its size or SHA-256 differs from the manifest.
    case damaged(String)
    /// Absolute, escapes the pack folder, listed twice, or a symbolic link.
    case unsafePath(String)
    /// The catalogue lists this pack ID, language and region, or suggested
    /// region more than once.
    case duplicateCatalogueEntry(String)
}
