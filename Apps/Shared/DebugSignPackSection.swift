#if DEBUG
import SapthamSigns
import SwiftUI
import UniformTypeIdentifiers

/// Debug builds only (ADR 0003 P10-S11): installs a sign pack from a folder
/// picked in Files or Finder, so a pack built with `signpack` can be tried,
/// and a Deaf panel can review a draft, before it's published. Compiled out
/// of Release builds, where packs arrive only as downloads.
struct DebugSignPackSection: View {
    var showsTitle = true
    @State private var store: SignPackStore
    @State private var packs: [InstalledSignPack] = []
    @State private var importing = false
    @State private var message: String?
    @State private var pendingDelete: String?

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
            ForEach(packs, id: \.key) { installed in
                row(installed)
            }
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
        .confirmationDialog("Delete this sign pack?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Pack", role: .destructive) {
                if let key = pendingDelete { Task { await delete(key) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its videos are removed from this device.") }
        .task { await reload() }
    }

    private func row(_ installed: InstalledSignPack) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                switch installed.pack {
                case .success(let pack):
                    Text(pack.manifest.signLanguageName).font(.body)
                    Text(summary(pack)).font(.caption).foregroundStyle(.secondary)
                case .failure(let error):
                    Text(installed.key).font(.body)
                    Text(error.userMessage).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { pendingDelete = installed.key } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete sign pack \(installed.key)")
        }
    }

    private func summary(_ pack: SignPack) -> String {
        let approved = pack.entries.filter { $0.reviewStatus == .approved }.count
        let review = pack.manifest.review == nil ? "draft pack" : "reviewed"
        return "\(pack.manifest.packId) · \(pack.entries.count) signs, \(approved) approved · \(review)"
    }

    private func reload() async {
        packs = await store.installed()
    }

    private func importPack(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        // Files grants access to the picked folder only while this is held.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pack = try await store.install(from: url)
            message = "Installed \(pack.manifest.packId): \(pack.entries.count) signs."
        } catch let error as SignPackError {
            message = error.userMessage
        } catch {
            message = "Couldn't import that folder."
        }
        await reload()
    }

    private func delete(_ key: String) async {
        do { try await store.delete(key: key) } catch { message = "Couldn't delete that pack." }
        pendingDelete = nil
        await reload()
    }
}
#endif
