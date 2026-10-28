import Foundation
import Testing
@testable import SapthamSigns

struct SignPackStoreTests {
    private func store() -> SignPackStore {
        SignPackStore(folder: FileManager.default.temporaryDirectory.appending(path: "signstore-\(UUID().uuidString)"))
    }

    @Test func installsListsAndDeletes() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let installed = try await store.install(from: TestPatternPackTests.fixture())
        #expect(installed.folder.lastPathComponent == "zxx-XX")
        let listed = await store.installed()
        #expect(listed.map(\.key) == ["zxx-XX"])
        #expect((try? listed.first?.pack.get())?.entries.count == 4)
        try await store.delete(key: "zxx-XX")
        #expect(await store.installed().isEmpty)
    }

    @Test func aNewerVersionReplacesTheOld() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let old = try TestPack { $0["version"] = "2027.1" }
        let new = try TestPack { $0["version"] = "2027.2"; $0["packId"] = "ase-US-commissioned-2027.2" }
        defer { old.remove(); new.remove() }
        try await store.install(from: old.folder)
        try await store.install(from: new.folder)
        let listed = await store.installed()
        #expect(listed.map(\.key) == ["ase-US"])
        #expect((try? listed.first?.pack.get())?.manifest.version == "2027.2")
    }

    @Test func aDamagedPackIsNotInstalledAndLeavesTheOldOne() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let good = try TestPack()
        let bad = try TestPack { $0["version"] = "2027.9" }
        defer { good.remove(); bad.remove() }
        try await store.install(from: good.folder)
        try bad.write(Data("changed".utf8), to: "LICENSE.txt")
        await #expect(throws: SignPackError.damaged("LICENSE.txt")) { try await store.install(from: bad.folder) }
        #expect((try? await store.installed().first?.pack.get())?.manifest.version == "2027.1")
        // Nothing left over from the failed install.
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.appending(path: ".staging").path(percentEncoded: false))
        #expect(names.isEmpty)
    }

    @Test func listsADamagedInstalledPackSoItCanBeDeleted() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let pack = try TestPack()
        defer { pack.remove() }
        let installed = try await store.install(from: pack.folder)
        try Data("changed".utf8).write(to: installed.url(for: "credits.txt"))
        let listed = await store.installed()
        #expect(listed.first?.key == "ase-US")
        if case .failure(let error)? = listed.first?.pack { #expect(error == .damaged("credits.txt")) } else { Issue.record("expected damaged") }
        try await store.delete(key: "ase-US")
        #expect(await store.installed().isEmpty)
    }

    @Test func refusesUnsafeKeys() async {
        let store = store()
        for key in ["..", "../x", ".staging", "a/b", ""] {
            await #expect(throws: SignPackError.self) { try await store.delete(key: key) }
        }
    }
}
