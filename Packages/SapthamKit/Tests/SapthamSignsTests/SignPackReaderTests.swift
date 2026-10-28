import CryptoKit
import Foundation
import Testing
@testable import SapthamSigns

/// Writes a small, valid pack into a fresh temporary folder: the ADR mock
/// entry, made-up bytes for its clip and poster, and a manifest whose hashes
/// match. Tests then break one thing at a time.
struct TestPack {
    let folder: URL

    static let files: [String: Data] = [
        "entries.json": Data(SignPackModelTests.entries.utf8),
        "LICENSE.txt": Data("Test content only.\n".utf8),
        "credits.txt": Data("Signed by S03\n".utf8),
        "media/ASL-WATER-1.mp4": Data((0..<4096).map { UInt8($0 % 251) }),
        "media/ASL-WATER-1.jpg": Data((0..<512).map { UInt8($0 % 7) }),
    ]

    init(manifest edit: (inout [String: Any]) -> Void = { _ in }) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "signpack-\(UUID().uuidString)")
        for (path, data) in Self.files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(SignPackModelTests.manifest.utf8)) as? [String: Any])
        manifest["files"] = Self.files.keys.sorted().map { path -> [String: Any] in
            let data = Self.files[path] ?? Data()
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha256": hash, "bytes": data.count]
        }
        edit(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
    }

    func write(_ data: Data, to path: String) throws {
        try data.write(to: folder.appending(path: path))
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

struct SignPackReaderTests {
    @Test func opensAGoodPack() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        let opened = try SignPackReader.open(pack.folder)
        #expect(opened.manifest.packId == "ase-US-commissioned-2027.1")
        #expect(opened.entries.map(\.idGloss) == ["WATER"])
        #expect(FileManager.default.fileExists(atPath: opened.url(for: "media/ASL-WATER-1.mp4").path(percentEncoded: false)))
    }

    @Test func oneChangedByteFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        var clip = try #require(TestPack.files["media/ASL-WATER-1.mp4"])
        clip[100] ^= 0xFF
        try pack.write(clip, to: "media/ASL-WATER-1.mp4")
        #expect(throws: SignPackError.damaged("media/ASL-WATER-1.mp4")) { try SignPackReader.open(pack.folder) }
    }

    @Test func aChangedSizeFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try pack.write(Data("Test content only.\nmore\n".utf8), to: "LICENSE.txt")
        #expect(throws: SignPackError.damaged("LICENSE.txt")) { try SignPackReader.open(pack.folder) }
    }

    @Test func aMissingFileFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try FileManager.default.removeItem(at: pack.folder.appending(path: "media/ASL-WATER-1.jpg"))
        #expect(throws: SignPackError.missingFile("media/ASL-WATER-1.jpg")) { try SignPackReader.open(pack.folder) }
    }

    @Test func aMissingManifestFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try FileManager.default.removeItem(at: pack.folder.appending(path: "manifest.json"))
        #expect(throws: SignPackError.missingFile("manifest.json")) { try SignPackReader.open(pack.folder) }
    }

    @Test func anExtraUnlistedFileFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try pack.write(Data("extra".utf8), to: "media/extra.mp4")
        #expect(throws: SignPackError.unlistedFile("media/extra.mp4")) { try SignPackReader.open(pack.folder) }
    }

    @Test func finderMetadataIsIgnored() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try pack.write(Data([0, 0, 0, 1]), to: ".DS_Store")
        try pack.write(Data([0, 0, 0, 1]), to: "media/.DS_Store")
        #expect(try SignPackReader.open(pack.folder).entries.count == 1)
    }

    @Test func aDifferentNormaliserFails() throws {
        let pack = try TestPack { $0["normaliserVersion"] = 2 }
        defer { pack.remove() }
        #expect(throws: SignPackError.normaliserMismatch(pack: 2, app: 1)) { try SignPackReader.open(pack.folder) }
    }

    @Test func aNewerFormatFails() throws {
        let pack = try TestPack { $0["formatVersion"] = 2 }
        defer { pack.remove() }
        #expect(throws: SignPackError.newerFormat(2)) { try SignPackReader.open(pack.folder) }
    }

    @Test func unsafeListedPathsFail() throws {
        for path in ["../outside.txt", "/etc/hosts", "media/../LICENSE.txt", "media//x.mp4", ""] {
            let pack = try TestPack { manifest in
                var files = manifest["files"] as? [[String: Any]] ?? []
                files.append(["path": path, "sha256": "00", "bytes": 0])
                manifest["files"] = files
            }
            defer { pack.remove() }
            #expect(throws: SignPackError.unsafePath(path)) { try SignPackReader.open(pack.folder) }
        }
    }

    @Test func aFileListedTwiceFails() throws {
        let pack = try TestPack { manifest in
            var files = manifest["files"] as? [[String: Any]] ?? []
            if let first = files.first { files.append(first) }
            manifest["files"] = files
        }
        defer { pack.remove() }
        #expect(throws: SignPackError.unsafePath("LICENSE.txt")) { try SignPackReader.open(pack.folder) }
    }

    @Test func aSymbolicLinkFails() throws {
        let pack = try TestPack()
        defer { pack.remove() }
        try FileManager.default.createSymbolicLink(at: pack.folder.appending(path: "media/link.mp4"),
                                                   withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(throws: SignPackError.unsafePath("media/link.mp4")) { try SignPackReader.open(pack.folder) }
    }

    @Test func aSignWhoseVideoIsNotListedFails() throws {
        // Hashes all match, but entries.json points at a clip the manifest doesn't cover.
        let pack = try TestPack { manifest in
            let files = manifest["files"] as? [[String: Any]] ?? []
            manifest["files"] = files.filter { ($0["path"] as? String) != "media/ASL-WATER-1.jpg" }
        }
        defer { pack.remove() }
        try FileManager.default.removeItem(at: pack.folder.appending(path: "media/ASL-WATER-1.jpg"))
        #expect(throws: SignPackError.missingFile("media/ASL-WATER-1.jpg")) { try SignPackReader.open(pack.folder) }
    }
}
