import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The system runs this to schedule Apple-hosted asset-pack downloads
/// (ADR 0003 P10-S10). Sign packs are on-demand, so the system never starts
/// one by itself; the app asks for a pack when the user taps Download. The
/// default behaviour is all Saptham needs.
@main
struct SignDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}
