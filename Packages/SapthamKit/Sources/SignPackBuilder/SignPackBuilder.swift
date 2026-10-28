import AVFoundation
import CryptoKit
import Foundation
import SapthamSigns

/// Why a pack couldn't be built. Messages are for the person preparing the
/// content, so they name the line and the field.
public enum SignPackBuildError: Error, Equatable, CustomStringConvertible {
    case sheet(line: Int, String)
    case content(String)

    public var description: String {
        switch self {
        case .sheet(let line, let message): "signs.csv line \(line): \(message)"
        case .content(let message): message
        }
    }
}

/// What the content folder's `pack.json` says about the pack. The builder
/// adds the format and normaliser versions, the file list and the credits.
struct PackInfo: Decodable {
    let packId: String
    let signLanguage: String
    let signLanguageName: String
    let variety: String
    let region: String
    let defaultForRegions: [String]
    let headwordLanguages: [String]
    let source: SignPackManifest.Source
    let licenceId: String
    let contentUse: ContentUse?
    let review: SignPackManifest.Review?
    let version: String
    let minAppVersion: String
}

/// Builds a pack folder (ADR 0003 §2.6) from a content folder:
///
/// ```
/// content/
///   pack.json     who made the pack, its licence and review (`PackInfo`)
///   signs.csv     one row per sense (`ContentSheet`)
///   LICENSE.txt   copied as is
///   …             the clips and posters signs.csv names
/// ```
///
/// Clips and posters are copied under `media/`; `entries.json`,
/// `credits.txt` and `manifest.json` are written; then the result is opened
/// with `SignPackReader`, so a pack this builds always loads in the app.
public enum SignPackBuilder {
    public static func build(content: URL, output: URL) async throws -> SignPack {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw SignPackBuildError.content("\(output.path(percentEncoded: false)) already exists; choose a new folder")
        }
        let info = try readInfo(content)
        let sheet = try read(content, "signs.csv")
        guard let sheetText = String(data: sheet, encoding: .utf8) else {
            throw SignPackBuildError.content("signs.csv isn't UTF-8 text")
        }
        let rows = try ContentSheet.rows(from: sheetText)
        guard !rows.isEmpty else { throw SignPackBuildError.content("signs.csv has no signs") }
        let licence = try read(content, "LICENSE.txt")

        try fm.createDirectory(at: output.appending(path: "media"), withIntermediateDirectories: true)
        do {
            let entries = try await entries(from: rows, info: info, content: content, output: output)
            try licence.write(to: output.appending(path: "LICENSE.txt"))
            try json(entries).write(to: output.appending(path: SignPackReader.entriesFileName))
            let draft = manifest(info, files: [])
            try Data(credits(draft, entries).utf8).write(to: output.appending(path: "credits.txt"))
            try json(manifest(info, files: try hashFiles(in: output))).write(to: output.appending(path: SignPackReader.manifestFileName))
            return try SignPackReader.open(output)
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Steps

    private static func readInfo(_ content: URL) throws -> PackInfo {
        do { return try JSONDecoder().decode(PackInfo.self, from: try read(content, "pack.json")) } catch let error as SignPackBuildError {
            throw error
        } catch {
            throw SignPackBuildError.content("pack.json is missing a field or isn't valid JSON")
        }
    }

    private static func read(_ folder: URL, _ name: String) throws -> Data {
        guard let data = try? Data(contentsOf: folder.appending(path: name)) else {
            throw SignPackBuildError.content("the content folder has no \(name)")
        }
        return data
    }

    /// Groups rows into signs (in first-seen order) and copies their media.
    private static func entries(from rows: [ContentRow], info: PackInfo, content: URL, output: URL) async throws -> [SignEntry] {
        var order: [String] = []
        var grouped: [String: [ContentRow]] = [:]
        for row in rows {
            if grouped[row.idGloss] == nil { order.append(row.idGloss) }
            grouped[row.idGloss, default: []].append(row)
        }
        var copied: [String: String] = [:]  // media path in the pack → source path
        var entries: [SignEntry] = []
        for gloss in order {
            let senses = grouped[gloss] ?? []
            guard let first = senses.first else { continue }
            for row in senses.dropFirst() {
                let same = row.clip == first.clip && row.poster == first.poster && row.signerId == first.signerId
                    && row.signerCredit == first.signerCredit && row.reviewStatus == first.reviewStatus
                    && row.lemmaId == first.lemmaId && row.durationMs == first.durationMs
                guard same else {
                    throw SignPackBuildError.sheet(line: row.line, "\(gloss) appears on line \(first.line) with a different clip, poster, signer, lemma, duration or review status")
                }
            }
            let clip = try copy(first.clip, line: first.line, from: content, to: output, copied: &copied)
            let poster = try first.poster.map { try copy($0, line: first.line, from: content, to: output, copied: &copied) }
            let duration: Int
            if let ms = first.durationMs { duration = ms } else { duration = try await durationMs(of: content.appending(path: first.clip), line: first.line) }
            entries.append(SignEntry(
                idGloss: gloss, lemmaId: first.lemmaId, variantOf: first.variantOf, regionalTag: first.regionalTag,
                senses: try senses.map { try sense($0, languages: info.headwordLanguages) },
                media: SignMedia(file: clip, poster: poster, durationMs: duration, loop: true),
                signerId: first.signerId, signerCredit: first.signerCredit, clipLicence: first.clipLicence,
                reviewStatus: ReviewStatus(raw: first.reviewStatus)))
        }
        return entries
    }

    /// Checks each form with the app's own normaliser (hidden coupling 1,
    /// see `main.swift`), so a form the builder accepts is one the app can match.
    /// The same form may appear under two languages (a loanword), but not
    /// twice under one.
    private static func sense(_ row: ContentRow, languages: [String]) throws -> SignSense {
        let forms = try row.forms.map { lang, text -> SignSense.Forms in
            guard languages.contains(lang) else {
                throw SignPackBuildError.sheet(line: row.line, "forms:\(lang) isn't in pack.json headwordLanguages \(languages)")
            }
            var keys: Set<String> = []
            for form in text {
                let key = SignWordNormaliser.normalise(form)
                guard !key.isEmpty else {
                    throw SignPackBuildError.sheet(line: row.line, "\"\(form)\" has no letters left after normalising")
                }
                guard keys.insert(key).inserted else {
                    throw SignPackBuildError.sheet(line: row.line, "\"\(form)\" is listed twice in forms:\(lang) (forms match ignoring case and edge punctuation)")
                }
            }
            return SignSense.Forms(lang: lang, text: text)
        }
        return SignSense(note: row.note, forms: forms)
    }

    private static func copy(_ path: String, line: Int, from content: URL, to output: URL, copied: inout [String: String]) throws -> String {
        guard SignPackReader.isSafe(path) else { throw SignPackBuildError.sheet(line: line, "\"\(path)\" must be a path inside the content folder") }
        let name = URL(filePath: path).lastPathComponent
        let target = "media/\(name)"
        if let earlier = copied[target] {
            guard earlier == path else { throw SignPackBuildError.sheet(line: line, "two different files are both named \(name)") }
            return target
        }
        let source = content.appending(path: path)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw SignPackBuildError.sheet(line: line, "\(path) isn't in the content folder")
        }
        try FileManager.default.copyItem(at: source, to: output.appending(path: target))
        copied[target] = path
        return target
    }

    private static func durationMs(of clip: URL, line: Int) async throws -> Int {
        let seconds: Double
        do { seconds = try await AVURLAsset(url: clip).load(.duration).seconds } catch {
            throw SignPackBuildError.sheet(line: line, "couldn't read the clip's length; add a durationMs column")
        }
        guard seconds.isFinite, seconds > 0 else {
            throw SignPackBuildError.sheet(line: line, "couldn't read the clip's length; add a durationMs column")
        }
        return Int((seconds * 1000).rounded())
    }

    private static func manifest(_ info: PackInfo, files: [SignPackManifest.File]) -> SignPackManifest {
        SignPackManifest(
            formatVersion: SignPackManifest.supportedFormatVersion, packId: info.packId, signLanguage: info.signLanguage,
            signLanguageName: info.signLanguageName, variety: info.variety, region: info.region,
            defaultForRegions: info.defaultForRegions, headwordLanguages: info.headwordLanguages,
            normaliserVersion: SignWordNormaliser.version, source: info.source,
            licence: SignPackManifest.Licence(id: info.licenceId, file: "LICENSE.txt"),
            contentUse: info.contentUse ?? .displayOnly, review: info.review, version: info.version,
            minAppVersion: info.minAppVersion, files: files)
    }

    /// Shown on the pack's Credits screen (ADR 0003 §2.8). Signers appear by
    /// the credit they chose, once each.
    static func credits(_ m: SignPackManifest, _ entries: [SignEntry]) -> String {
        var signers: [String] = []
        for credit in entries.map(\.signerCredit) where !signers.contains(credit) { signers.append(credit) }
        let review = m.review.map { "Reviewed by \($0.panel), signed off \($0.signedOff)." }
            ?? "Not yet reviewed by a Deaf panel. Draft."
        return """
        \(m.signLanguageName) (\(m.variety))
        Pack \(m.packId), version \(m.version)

        Content: \(m.source.organisation)
        Licence: \(m.licence.id) (see \(m.licence.file))
        \(review)

        Signers:
        \(signers.joined(separator: "\n"))

        Dictionary signs for single words only.

        """
    }

    private static func hashFiles(in folder: URL) throws -> [SignPackManifest.File] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [SignPackManifest.File] = []
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let path = String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path != SignPackReader.manifestFileName else { continue }
            let data = try Data(contentsOf: url)
            files.append(SignPackManifest.File(path: path, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                               bytes: data.count))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
