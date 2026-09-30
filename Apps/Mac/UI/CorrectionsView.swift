import SapthamCore
import SwiftUI

struct CorrectionsView: View {
    let corrections: CorrectionBook
    @State private var selectedRuleID: CorrectionRule.ID?
    @State private var addingRule = false

    var body: some View {
        VStack(spacing: 0) {
            if corrections.rules.isEmpty {
                ContentUnavailableView {
                    Label("No corrections yet", systemImage: "text.badge.checkmark")
                } description: {
                    Text("Fixes you make while reviewing transcripts will appear here and apply to future captions.")
                } actions: {
                    Button("Add correction") { addingRule = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Table(corrections.rules, selection: $selectedRuleID) {
                    TableColumn("When Saptham hears") { rule in
                        RuleTextField(text: rule.heard) { value in update(rule, heard: value, replacement: rule.replacement) }
                    }
                    .width(min: 220, ideal: 280)
                    TableColumn("Show") { rule in
                        RuleTextField(text: rule.replacement) { value in update(rule, heard: rule.heard, replacement: value) }
                    }
                    .width(min: 220, ideal: 280)
                    TableColumn("") { rule in
                        Button(role: .destructive) { corrections.remove(rule.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete correction")
                        .accessibilityLabel("Delete correction for \(rule.heard)")
                    }
                    .width(44)
                }
                .alternatingRowBackgrounds(.disabled)
                // Rows sit directly on the window's glass.
                .scrollContentBackground(.hidden)
                .onDeleteCommand(perform: deleteSelected)
                .contextMenu(forSelectionType: CorrectionRule.ID.self) { ids in
                    if let id = ids.first {
                        Button("Delete Correction", systemImage: "trash", role: .destructive) { corrections.remove(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text("Changes apply to live captions and saved transcripts.")
                    .font(.caption).foregroundStyle(.glassSecondary)
                Spacer()
                Button("Add correction", systemImage: "plus") { addingRule = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .navigationTitle("Corrections")
        .frame(minWidth: 600, minHeight: 380)
        .glassWindowBackground()
        .sheet(isPresented: $addingRule) {
            AddCorrectionView(corrections: corrections) { addingRule = false }
        }
    }

    private func update(_ rule: CorrectionRule, heard: String, replacement: String) {
        var changed = rule
        changed.heard = heard
        changed.replacement = replacement
        corrections.update(changed)
    }

    private func deleteSelected() {
        guard let selectedRuleID else { return }
        corrections.remove(selectedRuleID)
        self.selectedRuleID = nil
    }
}

private struct RuleTextField: View {
    @State var text: String
    let save: (String) -> Void

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .onSubmit { save(text) }
            .onChange(of: text) { _, value in save(value) }
            .accessibilityLabel("Correction text")
    }
}

private struct AddCorrectionView: View {
    let corrections: CorrectionBook
    let onClose: () -> Void
    @State private var heard = ""
    @State private var replacement = ""
    @FocusState private var heardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add correction").font(.title2.weight(.semibold))
            TextField("When Saptham hears", text: $heard).focused($heardFocused)
            TextField("Show", text: $replacement).onSubmit(add)
            HStack {
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add correction", action: add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { heardFocused = true }
    }

    private func add() {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        corrections.add(heard: heard, replacement: replacement)
        onClose()
    }
}

#Preview {
    let services = MacCaptionEngine.makePreviewServices()
    CorrectionsView(corrections: services.corrections)
}
