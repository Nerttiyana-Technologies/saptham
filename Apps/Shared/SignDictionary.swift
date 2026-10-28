import Foundation
import Observation
import SapthamSigns

/// The apps' one door to sign-language packs (ADR 0003): which installed pack
/// is active, and the signs a word reaches in it. Views ask this; they never
/// open the store or a pack themselves.
///
/// Opening a pack hashes every byte of it, so the active pack and its lookup
/// are kept until a `packsChanged` notification says the installed packs
/// changed (posted after an import, a download or a delete).
@MainActor @Observable
final class SignDictionary {
    /// Under each app's data folder.
    static let folderName = "SignPacks"
    static let packsChanged = Notification.Name("SapthamSignPacksChanged")

    /// Nil when no valid pack is installed: the sign action then stays hidden.
    private(set) var activePack: SignPack?
    @ObservationIgnored private var lookup: SignLookup?
    @ObservationIgnored private let store: SignPackStore
    @ObservationIgnored private let choice: SignPackChoiceStore
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(dataFolder: URL, choice: SignPackChoiceStore = UserDefaultsSignPackChoiceStore()) {
        store = SignPackStore(folder: dataFolder.appending(path: Self.folderName, directoryHint: .isDirectory))
        self.choice = choice
        observer = NotificationCenter.default.addObserver(forName: Self.packsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.loaded = false
                await self?.load()
            }
        }
    }

    var isAvailable: Bool { activePack != nil }

    /// Picks the user's chosen pack if it's installed and valid, otherwise the
    /// first valid one. Damaged packs are skipped; Settings lists them.
    func load() async {
        guard !loaded else { return }
        loaded = true
        let ready = await store.installed().compactMap { try? $0.pack.get() }
        let pack = ready.first { $0.manifest.choiceKey == choice.chosenKey } ?? ready.first
        activePack = pack
        lookup = pack.map { SignLookup(pack: $0) }
    }

    /// Approved signs only, exact forms only. The word isn't logged or kept.
    func signs(for word: String) async -> [SignMatch] {
        guard let lookup else { return [] }
        return await lookup.signs(for: word)
    }
}
