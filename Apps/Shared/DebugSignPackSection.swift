#if DEBUG
import SapthamSigns
import SwiftUI
import UniformTypeIdentifiers

/// Debug builds only (ADR 0003 P10-S11): installs a sign pack from a folder
/// picked in Files or Finder, so a pack built with `signpack` can be tried,
/// and a Deaf panel can review a draft, before it's published. Compiled out
/// of Release builds, where packs arrive only as downloads. Installed packs
/// are listed, and deleted, in the Sign language section above.
struct DebugSignPackSection: View {
    var showsTitle = true
    @State private var store: SignPackStore
    @State private var importing = false
    @State private var message: String?

    init(folder: URL, showsTitle: Bool = true) {
        _store = State(initialValue: SignPackStore(folder: folder))
        self.showsTitle = showsTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text("Sign packs (Debug)").font(.headline)
            }
            Text("Install a pack folder built with signpack, to try it before it's published. Not in release builds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { importing = true } label: {
                Label("Import pack…", systemImage: "square.and.arrow.down")
            }
            .accessibilityLabel("Import a sign pack folder")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            Task { await importPack(result) }
        }
    }

    private func importPack(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        // Files grants access to the picked folder only while this is held.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pack = try await store.install(from: url)
            message = "Installed \(pack.manifest.packId): \(pack.entries.count) signs."
            NotificationCenter.default.post(name: SignDictionary.packsChanged, object: nil)
        } catch let error as SignPackError {
            message = error.userMessage
        } catch {
            message = "Couldn't import that folder."
        }
    }
}
#endif
