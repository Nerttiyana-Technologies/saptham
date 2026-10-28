import Foundation
import Observation
import SapthamSigns

/// Fetches a catalogue pack and returns the folder it landed in, for
/// `SignPackStore` to verify and install. Background Assets fills this in
/// (ADR 0003 P10-S10); until then the apps pass none and Download is hidden.
protocol SignPackDownloading: Sendable {
    func download(_ pack: SignPackCatalogue.Pack) async throws -> URL
}

/// The apps' one door to sign-language packs (ADR 0003): whether signs are
/// on, which installed pack is active, Settings' pack list, and the signs a
/// word reaches. Views ask this; they never open the store or a pack
/// themselves.
///
/// Opening a pack hashes every byte of it, so the active pack and its lookup
/// are kept until a `packsChanged` notification says the installed packs
/// changed (posted after an import, a download, a delete or a new choice).
@MainActor @Observable
final class SignDictionary {
    /// Under each app's data folder.
    static let folderName = "SignPacks"
    static let packsChanged = Notification.Name("SapthamSignPacksChanged")
    /// The Settings switch. Off until the user turns it on (ADR 0003 §2.7).
    static let enabledKey = "signs.enabled"

    /// Nil when no valid pack is installed.
    private(set) var activePack: SignPack?
    /// Settings' list: the catalogue's packs, then any other installed pack.
    private(set) var rows: [SignPackListing.Row] = []
    /// The pack being downloaded, by `choiceKey`.
    private(set) var downloadingKey: String?
    /// The last download or delete that failed, in words for the user.
    private(set) var problem: String?
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private var lookup: SignLookup?
    @ObservationIgnored private let store: SignPackStore
    @ObservationIgnored private let catalogue: [SignPackCatalogue.Pack]
    @ObservationIgnored private let downloader: SignPackDownloading?
    @ObservationIgnored private let choice: SignPackChoiceStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(dataFolder: URL, catalogue: [SignPackCatalogue.Pack] = SignPackCatalogue.bundledPacks,
         downloader: SignPackDownloading? = nil,
         choice: SignPackChoiceStore = UserDefaultsSignPackChoiceStore(), defaults: UserDefaults = .standard) {
        store = SignPackStore(folder: dataFolder.appending(path: Self.folderName, directoryHint: .isDirectory))
        self.catalogue = catalogue
        self.downloader = downloader
        self.choice = choice
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        observer = NotificationCenter.default.addObserver(forName: Self.packsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.loaded = false
                await self?.load()
            }
        }
    }

    /// The sign action shows only when this is true.
    var isAvailable: Bool { isEnabled && activePack != nil }
    var canDownload: Bool { downloader != nil }

    /// Reads the installed packs and picks the active one (`SignPackListing`).
    func load() async {
        guard !loaded else { return }
        loaded = true
        let installed = await store.installed()
        let key = SignPackListing.activeKey(installed: installed, chosenKey: choice.chosenKey)
        let pack = installed.first { $0.key == key }.flatMap { try? $0.pack.get() }
        activePack = pack
        lookup = pack.map { SignLookup(pack: $0) }
        rows = SignPackListing.rows(catalogue: catalogue, installed: installed, activeKey: key,
                                    region: Locale.current.region?.identifier)
    }

    /// Approved signs only, exact forms only. The word isn't logged or kept.
    func signs(for word: String) async -> [SignMatch] {
        guard isEnabled, let lookup else { return [] }
        return await lookup.signs(for: word)
    }

    func choose(_ key: String) {
        choice.chosenKey = key
        announceChange()
    }

    func delete(_ key: String) async {
        problem = nil
        do { try await store.delete(key: key) } catch { problem = "Couldn't delete that pack." }
        announceChange()
    }

    func download(_ key: String) async {
        guard let downloader, downloadingKey == nil, let pack = catalogue.first(where: { $0.choiceKey == key }) else { return }
        downloadingKey = key
        problem = nil
        defer { downloadingKey = nil }
        do {
            _ = try await store.install(from: try await downloader.download(pack))
            announceChange()
        } catch let error as SignPackError {
            problem = error.userMessage
        } catch {
            problem = "Couldn't download \(pack.signLanguageName). Check the connection and try again."
        }
    }

    /// Every SignDictionary reloads, as does any other listener.
    private func announceChange() {
        NotificationCenter.default.post(name: Self.packsChanged, object: nil)
    }
}

extension SignPackCatalogue {
    /// The bundled SignPackCatalogue.json (P10-S12). Empty if it's missing or
    /// unreadable; the gate checks it before a release.
    static let bundledPacks: [Pack] = Bundle.main.url(forResource: "SignPackCatalogue", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? SignPackCatalogue.decode($0) }?
        .packs ?? []
}
