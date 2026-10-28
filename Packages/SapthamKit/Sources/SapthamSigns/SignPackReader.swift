import CryptoKit
import Foundation

/// A pack that passed every check in `SignPackReader`.
public struct SignPack: Sendable {
    public let manifest: SignPackManifest
    /// Every sign, in `entries.json` order, whatever its review status.
    public let entries: [SignEntry]
    public let folder: URL

    /// The file at a path the manifest lists, for example a sign's video.
    public func url(for path: String) -> URL {
        folder.appending(path: path, directoryHint: .notDirectory)
    }
}

/// Opens a pack folder and checks it completely before returning anything
/// (ADR 0003 §2.6): the format and normaliser versions, that the folder holds
/// exactly the files the manifest lists, and each file's size and SHA-256.
/// A pack that fails any check isn't loaded at all.
///
/// Reads every byte of the pack, so call it off the main actor.
public enum SignPackReader {
    public static let manifestFileName = "manifest.json"
    public static let entriesFileName = "entries.json"
    /// Finder writes these into any folder it shows; a reviewer opening a
    /// draft pack on a Mac shouldn't break it. Never read.
    static let ignoredNames: Set<String> = [".DS_Store"]

    public static func open(_ folder: URL) throws -> SignPack {
        let manifestURL = folder.appending(path: manifestFileName, directoryHint: .notDirectory)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw SignPackError.missingFile(manifestFileName)
        }
        let manifest = try SignPackManifest.decode(manifestData)
        guard manifest.normaliserVersion == SignWordNormaliser.version else {
            throw SignPackError.normaliserMismatch(pack: manifest.normaliserVersion, app: SignWordNormaliser.version)
        }

        var listed: [String: SignPackManifest.File] = [:]
        for file in manifest.files {
            guard isSafe(file.path), file.path != manifestFileName, listed[file.path] == nil else {
                throw SignPackError.unsafePath(file.path)
            }
            listed[file.path] = file
        }

        let present = try filesInFolder(folder)
        if let extra = present.subtracting(listed.keys).sorted().first {
            throw SignPackError.unlistedFile(extra)
        }
        if let missing = Set(listed.keys).subtracting(present).sorted().first {
            throw SignPackError.missingFile(missing)
        }
        for file in manifest.files {
            try verify(file, in: folder)
        }

        guard listed[entriesFileName] != nil else { throw SignPackError.missingFile(entriesFileName) }
        let entries = try SignEntry.decodeAll(Data(contentsOf: folder.appending(path: entriesFileName)))
        let referenced = [manifest.licence.file] + entries.flatMap { [$0.media.file, $0.media.poster].compactMap { $0 } }
        if let unlisted = referenced.first(where: { listed[$0] == nil }) {
            throw SignPackError.missingFile(unlisted)
        }
        return SignPack(manifest: manifest, entries: entries, folder: folder)
    }

    /// Relative, inside the pack, no empty or dot segments.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Every regular file under `folder` except the manifest, as pack paths.
    private static func filesInFolder(_ folder: URL) throws -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw SignPackError.missingFile(manifestFileName)
        }
        var paths: Set<String> = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            // Resolve the parent only (/var vs /private/var), never the file:
            // a symbolic link must be seen as one.
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let full = parent.appending(path: url.lastPathComponent).path(percentEncoded: false)
            let relative = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if values.isSymbolicLink == true { throw SignPackError.unsafePath(relative) }
            guard values.isRegularFile == true, !ignoredNames.contains(url.lastPathComponent),
                  relative != manifestFileName else { continue }
            paths.insert(relative)
        }
        return paths
    }

    private static func verify(_ file: SignPackManifest.File, in folder: URL) throws {
        let url = folder.appending(path: file.path, directoryHint: .notDirectory)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SignPackError.missingFile(file.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += chunk.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == file.bytes, digest == file.sha256.lowercased() else {
            throw SignPackError.damaged(file.path)
        }
    }
}
