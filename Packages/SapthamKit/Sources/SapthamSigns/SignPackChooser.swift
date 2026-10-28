import Foundation

/// Where the user's own pack choice is kept. Injected, so tests and the apps
/// can each use their own storage.
public protocol SignPackChoiceStore: AnyObject, Sendable {
    /// A `SignPackCatalogue.Pack.choiceKey`, or nil when the user hasn't chosen.
    var chosenKey: String? { get set }
}

/// Keeps the choice in `UserDefaults`.
public final class UserDefaultsSignPackChoiceStore: SignPackChoiceStore, @unchecked Sendable {
    // UserDefaults is thread-safe; this class adds no state of its own.
    private let defaults: UserDefaults
    private let key = "signs.chosenPack"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var chosenKey: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Picks the pack to use (ADR 0003 §2.7): the user's own choice when it's in
/// the catalogue, otherwise the pack suggested for the device's region,
/// otherwise none. The caption language never decides.
public struct SignPackChooser: Sendable {
    public let catalogue: SignPackCatalogue
    private let store: SignPackChoiceStore

    public init(catalogue: SignPackCatalogue, store: SignPackChoiceStore) {
        self.catalogue = catalogue
        self.store = store
    }

    /// The pack suggested for a region, such as `Locale.current.region?.identifier`.
    public func suggested(forRegion region: String?) -> SignPackCatalogue.Pack? {
        SignPackCatalogue.suggested(from: catalogue.packs, forRegion: region)
    }

    public func activePack(region: String?) -> SignPackCatalogue.Pack? {
        if let key = store.chosenKey, let chosen = catalogue.packs.first(where: { $0.choiceKey == key }) {
            return chosen
        }
        return suggested(forRegion: region)
    }

    /// The user picks a pack; nil goes back to the region's suggestion.
    public func choose(_ pack: SignPackCatalogue.Pack?) {
        store.chosenKey = pack?.choiceKey
    }
}
