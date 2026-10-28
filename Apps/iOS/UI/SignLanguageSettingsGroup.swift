import SapthamSigns
import SwiftUI

/// Settings → Sign language (ADR 0003 §2.9, P10-S15): the on/off switch,
/// then each pack with Download, Delete pack and Credits.
struct SignLanguageSettingsGroup: View {
    let signs: SignDictionary

    @State private var confirmingDelete: SignPackListing.Row?
    @State private var confirmingDownload: SignPackListing.Row?
    @State private var creditsFor: CreditsItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { signs.isEnabled.toggle() } label: {
                HStack(alignment: .center, spacing: 14) {
                    LitGlyph(systemImage: "hand.raised", isLit: signs.isEnabled, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show signs for words").font(.headline).foregroundStyle(Monsoon.ink)
                        Text(signs.isEnabled ? "On" : "Off · tap to turn on")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(signs.isEnabled ? Monsoon.accent : Monsoon.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.glyph)
            .sensoryFeedback(.selection, trigger: signs.isEnabled)
            .accessibilityLabel("Show signs for words")
            .accessibilityValue(signs.isEnabled ? "On" : "Off")

            Text("Tap a word in a saved transcript to see a recorded dictionary sign for it. Saptham doesn't sign whole sentences.")
                .font(.caption).foregroundStyle(Monsoon.ink3).fixedSize(horizontal: false, vertical: true)

            if signs.isEnabled {
                if signs.rows.isEmpty {
                    Text("No sign-language packs are available yet.")
                        .font(.subheadline).foregroundStyle(Monsoon.ink2)
                }
                ForEach(signs.rows) { row in
                    packRow(row)
                }
                if let problem = signs.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
        } message: { Text("Its videos are removed from this iPhone. You can download it again later.") }
        .confirmationDialog("Download \(confirmingDownload?.name ?? "this pack")?", isPresented: Binding(
            get: { confirmingDownload != nil }, set: { if !$0 { confirmingDownload = nil } }), titleVisibility: .visible) {
            Button("Download \(confirmingDownload?.downloadBytes?.formatted(.byteCount(style: .file)) ?? "")") {
                if let key = confirmingDownload?.key { Task { await signs.download(key) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The sign videos are stored on this iPhone.") }
        .sheet(item: $creditsFor) { item in SignPackCreditsView(pack: item.pack) }
    }

    private func packRow(_ row: SignPackListing.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { signs.choose(row.key) } label: {
                Image(systemName: row.isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(row.isActive ? Monsoon.accent : Monsoon.ink3)
            }
            .buttonStyle(.glyph)
            .disabled(!row.isReady)
            .opacity(row.isReady ? 1 : 0.35)
            .accessibilityLabel("Use \(row.name)")
            .accessibilityAddTraits(row.isActive ? .isSelected : [])
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name).font(.headline).foregroundStyle(Monsoon.ink)
                Text(row.detail).font(.subheadline)
                    .foregroundStyle(row.isInstalled && !row.isReady ? .orange : Monsoon.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    if let pack = row.pack {
                        Button { creditsFor = CreditsItem(pack: pack) } label: { Label("Credits", systemImage: "info.circle") }
                            .accessibilityLabel("Credits for \(row.name)")
                    }
                    Spacer(minLength: 0)
                    if signs.downloadingKey == row.key {
                        ProgressView().tint(Monsoon.accent)
                        Text("Downloading…").font(.subheadline).foregroundStyle(Monsoon.ink2)
                    } else if row.isInstalled {
                        if row.isUpdateAvailable && signs.canDownload {
                            Button { confirmingDownload = row } label: { Label("Update pack", systemImage: "arrow.down.circle") }
                                .disabled(signs.downloadingKey != nil)
                                .accessibilityLabel("Update \(row.name)")
                        }
                        Button(role: .destructive) { confirmingDelete = row } label: { Label("Delete pack", systemImage: "trash") }
                            .accessibilityLabel("Delete \(row.name)")
                    } else if signs.canDownload {
                        Button { confirmingDownload = row } label: { Label("Download", systemImage: "arrow.down.circle") }
                            .disabled(signs.downloadingKey != nil)
                            .accessibilityLabel("Download \(row.name)")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Monsoon.accent)
                .frame(minHeight: 44)
            }
        }
    }
}

/// `sheet(item:)` needs an identity; a pack's is its ID and version.
private struct CreditsItem: Identifiable {
    let pack: SignPack
    var id: String { pack.manifest.packId }
}
