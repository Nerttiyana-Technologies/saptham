import Foundation

/// A pack found in the store's folder, or why it can't be used.
public struct InstalledSignPack: Sendable {
    /// `SignPackCatalogue.Pack.choiceKey`, which is also its folder name.
    public let key: String
    public let pack: Result<SignPack, SignPackError>
}

/// The packs installed on this device, one folder per sign language and
/// region (ADR 0003 §2.6): installing a newer version replaces the older one,
/// and deleting removes its files. Every pack is verified with
/// `SignPackReader` before it's installed, and again when listed.
///
/// Packs reach `install(from:)` from a download (Background Assets, P10-S10)
/// or, in Debug builds only, from a folder the user picks in Files.
public actor SignPackStore {
    public nonisolated let folder: URL
    private static let staging = ".staging"

    public init(folder: URL) {
        self.folder = folder
    }

    /// Verifies the pack at `source`, copies it in, verifies the copy, then
    /// swaps it in place of any installed version. A failure leaves the
    /// installed packs as they were.
    @discardableResult
    public func install(from source: URL) throws -> SignPack {
        let incoming = try SignPackReader.open(source)
        let fm = FileManager.default
        let staging = folder.appending(path: "\(Self.staging)/\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        // The copy is checked too: the source may change while it's copied.
        let copied = try SignPackReader.open(staging)
        guard copied.manifest == incoming.manifest else { throw SignPackError.damaged(SignPackReader.manifestFileName) }

        let target = folder.appending(path: copied.manifest.choiceKey, directoryHint: .isDirectory)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        return try SignPackReader.open(target)
    }

    /// Every installed pack, by key, including damaged ones so the user can
    /// delete them ("This pack is damaged; delete and download again").
    public func installed() -> [InstalledSignPack] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { key in
            let url = folder.appending(path: key, directoryHint: .isDirectory)
            do { return InstalledSignPack(key: key, pack: .success(try SignPackReader.open(url))) } catch let error as SignPackError {
                return InstalledSignPack(key: key, pack: .failure(error))
            } catch {
                return InstalledSignPack(key: key, pack: .failure(.missingFile(SignPackReader.manifestFileName)))
            }
        }
    }

    public func delete(key: String) throws {
        guard SignPackReader.isSafe(key), !key.contains("/"), !key.hasPrefix(".") else { throw SignPackError.unsafePath(key) }
        let url = folder.appending(path: key, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public extension SignPackManifest {
    /// Same as `SignPackCatalogue.Pack.choiceKey`: for example `ase-US`.
    var choiceKey: String { "\(signLanguage)-\(region)" }
}
