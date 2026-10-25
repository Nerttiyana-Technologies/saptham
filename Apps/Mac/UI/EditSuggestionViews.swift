import SapthamCore
import SwiftUI

/// Offers, in a transcript, the fixes the user keeps making by hand there and
/// in other conversations (ADR 0002). Nothing is learnt until they accept.
struct EditSuggestionBanner: View {
    let session: TranscriptSession
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let declined: DeclinedSuggestions

    var body: some View {
        if let suggestion = declined.showing(EditPatterns.suggestions(in: transcripts.sessions, rules: corrections.rules,
                                                                      declined: declined.declined))
            .first(where: { $0.sessionIDs.contains(session.id) }) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You changed \(Text(suggestion.heard).bold()) → \(Text(suggestion.replacement).bold()) in \(suggestion.lineCount) lines, in \(suggestion.sessionIDs.count) conversations.")
                    Text("Fix it in every caption from now on?")
                        .foregroundStyle(.glassSecondary)
                }
                Spacer()
                Button("Don't suggest this") { declined.decline(suggestion) }
                    .help("Never suggest this fix again")
                Button("Not now") { declined.postpone(suggestion) }
                    .help("Ask again after you make this fix once more")
                Button("Always fix this", systemImage: "checkmark") {
                    corrections.add(heard: suggestion.heard, replacement: suggestion.replacement)
                }
                .buttonStyle(.borderedProminent)
                .help("Add a correction: future captions and unedited lines show \(suggestion.replacement)")
            }
            .padding(14)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggested correction")
        }
    }
}

/// The Corrections window's list of fixes waiting for an answer, so a
/// suggestion skipped in a transcript is not lost.
struct SuggestedCorrectionsList: View {
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let declined: DeclinedSuggestions

    var body: some View {
        let suggestions = declined.showing(EditPatterns.suggestions(in: transcripts.sessions, rules: corrections.rules,
                                                                    declined: declined.declined))
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested from your edits").font(.headline)
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 12) {
                        Text("\(suggestion.heard)  →  \(suggestion.replacement)")
                        Spacer()
                        Text("\(suggestion.lineCount) lines · \(suggestion.sessionIDs.count) conversations")
                            .font(.caption).foregroundStyle(.glassSecondary)
                        Button("Always fix this", systemImage: "checkmark") {
                            corrections.add(heard: suggestion.heard, replacement: suggestion.replacement)
                        }
                        .help("Add this correction")
                        Button { declined.decline(suggestion) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Don't suggest this")
                            .accessibilityLabel("Don't suggest \(suggestion.heard) to \(suggestion.replacement)")
                    }
                }
            }
            .padding(12)
        }
    }
}
