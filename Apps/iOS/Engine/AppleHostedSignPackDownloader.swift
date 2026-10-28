import BackgroundAssets
import Foundation
import SapthamSigns
import System

/// Downloads a sign pack from Apple's asset-pack hosting (ADR 0003 §2.5A,
/// P10-S10). Apple serves the files, so Saptham runs no server.
///
/// The system finds a downloaded file by its path, not as a folder Saptham
/// can walk, so each file the pack's manifest lists is fetched by path and
/// copied into a staging folder. `SignPackStore` then verifies that folder
/// like any other pack; a path the manifest lists that isn't safe is never
/// asked for. `discardDownload(of:)` frees the staging folder and the
/// system's copy.
///
/// Hidden coupling 1: the asset pack's ID must equal the catalogue
/// `packId`, and the asset pack must hold the pack's files under a folder
/// named after that ID (`<packId>/manifest.json`, …).
/// Tools/SignPacks/make_asset_pack.sh builds it that way (release
/// checklist); nothing in code can check what was uploaded to App Store
/// Connect.
///
/// Hidden coupling 2: the system finds the downloaded files through the app
/// group named by `BAAppGroupID` in Support/Info.plist, which must also be in
/// the app's and SignDownloader's entitlements. Change all three together.
struct AppleHostedSignPackDownloader: SignPackDownloading {
    func download(_ pack: SignPackCatalogue.Pack) async throws -> URL {
        guard SignPackReader.isSafe(pack.packId), !pack.packId.contains("/") else {
            throw SignPackError.unsafePath(pack.packId)
        }
        let manager = AssetPackManager.shared
        guard let assetPack = try await manager.manifest.assetPack(withID: pack.packId) else {
            throw ManagedBackgroundAssetsError.assetPackNotFound(withID: pack.packId)
        }
        try await manager.ensureLocalAvailability(of: assetPack, requireLatestVersion: true)

        let root = FilePath(pack.packId)
        let manifestURL = try manager.url(for: root.appending(SignPackReader.manifestFileName))
        let manifest = try SignPackManifest.decode(Data(contentsOf: manifestURL))
        let staging = Self.staging(for: pack)
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.copyItem(at: manifestURL, to: staging.appending(path: SignPackReader.manifestFileName))
        for file in manifest.files {
            guard SignPackReader.isSafe(file.path) else { throw SignPackError.unsafePath(file.path) }
            let target = staging.appending(path: file.path, directoryHint: .notDirectory)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: try manager.url(for: root.appending(file.path)), to: target)
        }
        return staging
    }

    func discardDownload(of pack: SignPackCatalogue.Pack) async {
        // Nothing to free if the download never finished; the store's copy
        // is what the app uses either way.
        try? FileManager.default.removeItem(at: Self.staging(for: pack))
        try? await AssetPackManager.shared.remove(assetPackWithID: pack.packId)
    }

    private static func staging(for pack: SignPackCatalogue.Pack) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SignPackDownloads/\(pack.packId)", directoryHint: .isDirectory)
    }
}
