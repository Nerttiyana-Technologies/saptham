import SapthamSigns
import SwiftUI

/// Settings → Sign language (ADR 0003 §2.9, P10-S15): the on/off switch,
/// then each pack with Download, Delete Pack and Credits.
struct SignLanguageSettingsSection: View {
    @Bindable var signs: SignDictionary

    @State private var confirmingDelete: SignPackListing.Row?
    @State private var confirmingDownload: SignPackListing.Row?
    @State private var creditsFor: CreditsItem?

    var body: some View {
        Section("Sign language") {
            Toggle("Show signs for words", isOn: $signs.isEnabled)
            Text("Select words in a saved transcript and choose Show sign to see a recorded dictionary sign. Saptham doesn't sign whole sentences.")
                .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
            if signs.isEnabled {
                if signs.rows.isEmpty {
                    Text("No sign-language packs are available yet.").foregroundStyle(.secondary)
                }
                ForEach(signs.rows) { row in
                    packRow(row)
                }
                if let problem = signs.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await signs.load() }
        .confirmationDialog("Delete \(confirmingDelete?.name ?? "this pack")?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Pack", role: .destructive) {
                if let key = confirmingDelete?.key { Task { await signs.delete(key) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its videos are removed from this Mac. You can download it again later.") }
        .confirmationDialog("Download \(confirmingDownload?.name ?? "this pack")?", isPresented: Binding(
            get: { confirmingDownload != nil }, set: { if !$0 { confirmingDownload = nil } }), titleVisibility: .visible) {
            Button("Download \(confirmingDownload?.bytes?.formatted(.byteCount(style: .file)) ?? "")") {
                if let key = confirmingDownload?.key { Task { await signs.download(key) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The sign videos are stored on this Mac.") }
        .sheet(item: $creditsFor) { item in SignPackCreditsSheet(pack: item.pack) }
    }

    private func packRow(_ row: SignPackListing.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { signs.choose(row.key) } label: {
                Image(systemName: row.isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(row.isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!row.isReady)
            .help(row.isReady ? "Use this pack" : "Download this pack to use it")
            .accessibilityLabel("Use \(row.name)")
            .accessibilityAddTraits(row.isActive ? .isSelected : [])
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                Text(row.detail).font(.callout)
                    .foregroundStyle(row.isInstalled && !row.isReady ? AnyShapeStyle(.orange) : AnyShapeStyle(.glassSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let pack = row.pack {
                        Button("Credits…", systemImage: "info.circle") { creditsFor = CreditsItem(pack: pack) }
                            .accessibilityLabel("Credits for \(row.name)")
                    }
                    if signs.downloadingKey == row.key {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    } else if row.isInstalled {
                        Button("Delete Pack…", systemImage: "trash", role: .destructive) { confirmingDelete = row }
                            .accessibilityLabel("Delete \(row.name)")
                    } else if signs.canDownload {
                        Button("Download…", systemImage: "arrow.down.circle") { confirmingDownload = row }
                            .disabled(signs.downloadingKey != nil)
                            .accessibilityLabel("Download \(row.name)")
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// `sheet(item:)` needs an identity; a pack's is its ID and version.
private struct CreditsItem: Identifiable {
    let pack: SignPack
    var id: String { pack.manifest.packId }
}
