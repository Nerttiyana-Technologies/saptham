import Foundation

/// Settings' list of sign packs (ADR 0003 §2.9): every pack the catalogue
/// offers, downloaded or not, then any installed pack the catalogue doesn't
/// list (a Debug import, or a pack the catalogue has since dropped). Also
/// decides which installed pack is in use, so Settings and lookups agree.
public enum SignPackListing {
    public struct Row: Sendable, Identifiable {
        public enum State: Sendable {
            case ready(SignPack)
            /// Installed but failed verification; it's never used.
            case damaged(SignPackError)
            case notDownloaded
        }

        /// `SignPackCatalogue.Pack.choiceKey`, which is also the folder name.
        public let key: String
        public let name: String
        public let variety: String
        public let state: State
        /// On disk when installed; the catalogue's download size otherwise.
        public let bytes: Int?
        /// What Download or Update fetches: the catalogue's size, nil for a
        /// pack the catalogue doesn't list.
        public let downloadBytes: Int?
        public let isSuggested: Bool
        public let isActive: Bool
        /// Installed and verified, but the catalogue offers another version
        /// (a newer app lists a newer pack); downloading it replaces this one.
        public let isUpdateAvailable: Bool

        public var id: String { key }
    }

    /// The installed pack to use: the user's choice when it's installed and
    /// verifies, otherwise the first that verifies. Damaged packs are skipped.
    public static func activeKey(installed: [InstalledSignPack], chosenKey: String?) -> String? {
        let ready = installed.filter { (try? $0.pack.get()) != nil }.map(\.key)
        if let chosenKey, ready.contains(chosenKey) { return chosenKey }
        return ready.first
    }

    /// `region` is the device's, such as `Locale.current.region?.identifier`.
    public static func rows(catalogue: [SignPackCatalogue.Pack], installed: [InstalledSignPack],
                            activeKey: String?, region: String?) -> [Row] {
        let suggestedKey = SignPackCatalogue.suggested(from: catalogue, forRegion: region)?.choiceKey
        let installedByKey = Dictionary(installed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(catalogue.map(\.choiceKey))
        let offered = catalogue.map { entry in
            row(key: entry.choiceKey, installed: installedByKey[entry.choiceKey], entry: entry,
                suggestedKey: suggestedKey, activeKey: activeKey)
        }
        let extra = installed.filter { !listed.contains($0.key) }.map { installed in
            row(key: installed.key, installed: installed, entry: nil, suggestedKey: suggestedKey, activeKey: activeKey)
        }
        return offered + extra
    }

    private static func row(key: String, installed: InstalledSignPack?, entry: SignPackCatalogue.Pack?,
                            suggestedKey: String?, activeKey: String?) -> Row {
        let state: Row.State
        var name = entry?.signLanguageName ?? key
        var variety = entry?.variety ?? ""
        var bytes = entry?.downloadBytes
        var isUpdateAvailable = false
        switch installed?.pack {
        case .success(let pack)?:
            state = .ready(pack)
            isUpdateAvailable = entry.map { $0.packId != pack.manifest.packId } ?? false
            name = pack.manifest.signLanguageName
            variety = pack.manifest.variety
            bytes = pack.manifest.files.reduce(0) { $0 + $1.bytes }
        case .failure(let error)?:
            state = .damaged(error)
            bytes = nil
        case nil:
            state = .notDownloaded
        }
        return Row(key: key, name: name, variety: variety, state: state, bytes: bytes, downloadBytes: entry?.downloadBytes,
                   isSuggested: key == suggestedKey, isActive: key == activeKey, isUpdateAvailable: isUpdateAvailable)
    }
}
