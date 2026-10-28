import BackgroundAssets
import Foundation
import SapthamSigns
import System

/// Downloads a sign pack from Apple's asset-pack hosting (ADR 0003 §2.5A,
/// P10-S10). Apple serves the files, so Saptham runs no server; the system
/// keeps them in the app group until `SignPackStore` has verified and copied
/// them, and `discardDownload(of:)` then frees them.
///
/// Hidden coupling 1: the asset pack's ID must equal the catalogue
/// `packId`, and the asset pack must hold the pack's files under a folder
/// named after that ID (`<packId>/manifest.json`, …). The asset-pack
/// manifest built for `ba-package` sets both (release checklist); nothing
/// in code can check what was uploaded to App Store Connect.
///
/// Hidden coupling 2: the system finds the downloaded files through the app
/// group named by `BAAppGroupID` in Support/Info.plist, which must also be in
/// the app's and SignDownloader's entitlements. Change all three together.
struct AppleHostedSignPackDownloader: SignPackDownloading {
    func download(_ pack: SignPackCatalogue.Pack) async throws -> URL {
        let manager = AssetPackManager.shared
        guard let assetPack = try await manager.manifest.assetPack(withID: pack.packId) else {
            throw ManagedBackgroundAssetsError.assetPackNotFound(withID: pack.packId)
        }
        try await manager.ensureLocalAvailability(of: assetPack, requireLatestVersion: true)
        let manifest = FilePath(pack.packId).appending(SignPackReader.manifestFileName)
        return try manager.url(for: manifest).deletingLastPathComponent()
    }

    func discardDownload(of pack: SignPackCatalogue.Pack) async {
        // Nothing to free if the download never finished; the store's copy
        // is what the app uses either way.
        try? await AssetPackManager.shared.remove(assetPackWithID: pack.packId)
    }
}
