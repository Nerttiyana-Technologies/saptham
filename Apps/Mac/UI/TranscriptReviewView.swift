import AppKit
import SapthamCore
import SwiftUI

struct TranscriptReviewView: View {
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    @AppStorage("captionTextSize") private var captionTextSize = 30.0
    @State private var selectedSessionID: TranscriptSession.ID?
    @State private var query = ""
    @State private var pendingDeletion: TranscriptSession.ID?
    @State private var confirmsDeletion = false

    private var filteredSessions: [TranscriptSession] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcripts.sessions }
        return transcripts.sessions.filter { session in
            session.lines.contains { $0.displayText(using: corrections.corrector).localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSessionID) {
                if filteredSessions.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No transcripts yet" : "No matches", systemImage: query.isEmpty ? "text.alignleft" : "magnifyingglass", description: Text(query.isEmpty ? "Completed caption sessions will appear here." : "Try a different search.") )
                } else {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, corrector: corrections.corrector)
                                    .tag(session.id)
                                    .contextMenu {
                                        Button("Copy Transcript", systemImage: "doc.on.doc") { copy(session) }
                                        Divider()
                                        Button("Delete Transcript…", systemImage: "trash", role: .destructive) {
                                            pendingDeletion = session.id
                                            confirmsDeletion = true
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
            .searchable(text: $query, prompt: "Search transcripts")
            .navigationTitle("Transcripts")
            .onDeleteCommand(perform: confirmSelectedDeletion)
            .confirmationDialog("Delete this transcript?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Delete Transcript", role: .destructive) { deletePending() }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This also deletes its recording if no other transcript uses it.")
            }
        } detail: {
            if let session = transcripts.sessions.first(where: { $0.id == selectedSessionID }) {
                SessionDetailView(session: session, transcripts: transcripts, corrections: corrections,
                                  textSize: min(captionTextSize, 28))
            } else {
                ContentUnavailableView("Choose a transcript", systemImage: "text.alignleft", description: Text("Select a session to review its captions."))
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        // The window background is Liquid Glass; the system glass sidebar
        // and toolbar float on top of it.
        .glassWindowBackground()
        .onChange(of: transcripts.sessions) { _, sessions in
            if !sessions.contains(where: { $0.id == selectedSessionID }) { selectedSessionID = sessions.first?.id }
        }
        .onAppear { selectedSessionID = selectedSessionID ?? transcripts.sessions.first?.id }
        .onChange(of: query) { _, _ in
            if !filteredSessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = filteredSessions.first?.id
            }
        }
    }

    private var groups: [SessionGroup] {
        let calendar = Calendar.current
        let today = filteredSessions.filter { calendar.isDateInToday($0.startedAt) }
        let yesterday = filteredSessions.filter { calendar.isDateInYesterday($0.startedAt) }
        let earlier = filteredSessions.filter { !calendar.isDateInToday($0.startedAt) && !calendar.isDateInYesterday($0.startedAt) }
        return [SessionGroup(title: "Today", sessions: today),
                SessionGroup(title: "Yesterday", sessions: yesterday),
                SessionGroup(title: "Earlier", sessions: earlier)]
            .filter { !$0.sessions.isEmpty }
    }

    private func confirmSelectedDeletion() {
        guard let selectedSessionID else { return }
        pendingDeletion = selectedSessionID
        confirmsDeletion = true
    }

    private func deletePending() {
        guard let id = pendingDeletion else { return }
        transcripts.delete(id)
        selectedSessionID = transcripts.sessions.first?.id
        pendingDeletion = nil
    }

    private func copy(_ session: TranscriptSession) {
        let text = session.lines.map { "\(timeString($0.time))  \($0.displayText(using: corrections.corrector))" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


private struct SessionGroup: Identifiable {
    let title: String
    let sessions: [TranscriptSession]
    var id: String { title }
}

private struct SessionRow: View {
    let session: TranscriptSession
    let corrector: TextCorrector

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: sourceSymbol)
                    .accessibilityHidden(true)
                Text(session.sourceTitle).font(.headline)
                Spacer(minLength: 4)
                Text(session.startedAt, style: .time).foregroundStyle(.glassSecondary)
            }
            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted) + " · " + duration)
                .font(.caption).foregroundStyle(.glassSecondary)
            Text(session.lines.first?.displayText(using: corrector) ?? "No captions")
                .font(.subheadline).foregroundStyle(.glassSecondary).lineLimit(2)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sourceSymbol: String {
        switch session.sourceID {
        case "calls": "phone.fill"
        case "microphone": "person.2.wave.2.fill"
        default: "speaker.wave.2.fill"
        }
    }

    private var duration: String {
        let seconds = Int(max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)))
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct SessionDetailView: View {
    let session: TranscriptSession
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let textSize: Double
    @State private var player = TranscriptAudioPlayer()
    @State private var selectedLineIDs = Set<TranscriptLine.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.sourceTitle).font(.title2.weight(.semibold))
                    Text(session.startedAt.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.glassSecondary)
                }
                Spacer()
                Button("Copy Selected Lines", systemImage: "doc.on.doc") { copySelectedLines() }
                    .disabled(selectedLineIDs.isEmpty)
                    .help("Copy selected lines")
                Button("Copy Transcript", systemImage: "doc.on.doc") { copyTranscript() }
                    .help("Copy the whole transcript")
            }
            .padding()
            Divider()
            if session.lines.isEmpty {
                ContentUnavailableView("No captions", systemImage: "text.alignleft")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(session.lines) { line in
                            TranscriptLineRow(session: session, line: line, transcripts: transcripts,
                                              corrections: corrections, textSize: textSize,
                                              player: player, selectedLineIDs: $selectedLineIDs)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Transcript")
        .focusedValue(\.transcriptCopy) {
            if selectedLineIDs.isEmpty { copyTranscript() } else { copySelectedLines() }
        }
        .onDisappear { player.stop() }
    }

    private func copyTranscript() {
        copyLines(session.lines)
    }

    private func copySelectedLines() {
        copyLines(session.lines.filter { selectedLineIDs.contains($0.id) })
    }

    private func copyLines(_ lines: [TranscriptLine]) {
        let text = lines.map { "\(timeString($0.time))  \($0.displayText(using: corrections.corrector))" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct TranscriptLineRow: View {
    let session: TranscriptSession
    let line: TranscriptLine
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let textSize: Double
    let player: TranscriptAudioPlayer
    @Binding var selectedLineIDs: Set<TranscriptLine.ID>
    @State private var selectedWords: ClosedRange<Int>?
    @State private var editorOpen = false
    @State private var accessibleEditorOpen = false
    @State private var replacement = ""
    @State private var replacementSelection: TextSelection?

    private var display: String { line.displayText(using: corrections.corrector) }
    private var words: [NSRange] { WordSelection.ranges(in: display) }
    private var selectedPhrase: String {
        guard let selectedWords, words.indices.contains(selectedWords.lowerBound), words.indices.contains(selectedWords.upperBound),
              let range = Range(NSRange(location: words[selectedWords.lowerBound].location,
                                        length: NSMaxRange(words[selectedWords.upperBound]) - words[selectedWords.lowerBound].location), in: display) else { return "" }
        return String(display[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if selectedLineIDs.contains(line.id) { selectedLineIDs.remove(line.id) }
                else { selectedLineIDs.insert(line.id) }
            } label: {
                Image(systemName: selectedLineIDs.contains(line.id) ? "checkmark.circle.fill" : "circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedLineIDs.contains(line.id) ? "Deselect line" : "Select line for copying")
            Text(line.time, style: .time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.glassSecondary)
                .frame(width: 72, alignment: .trailing)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 0) {
                    ForEach(words.indices, id: \.self) { index in
                        token(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: textSize))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(display)
                .accessibilityAction(named: "Correct words in this line") { openAccessibleEditor() }
                .focusable()
                .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
                .onKeyPress(.return) { if selectedWords != nil { editorOpen = true; return .handled }; return .ignored }
                if editorOpen { correctionEditor(accessible: false) }
                HStack(spacing: 8) {
                    if line.edited != nil {
                        Label("Edited", systemImage: "pencil")
                            .font(.caption).foregroundStyle(.glassSecondary)
                            .accessibilityLabel("Manually edited")
                        Button("Revert to original") {
                            transcripts.setEdited(nil, line: line.id, in: session.id)
                        }
                        .font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
            if let span = line.audio, let url = transcripts.recordingURL(for: session), FileManager.default.fileExists(atPath: url.path) {
                Button {
                    player.play(span, from: url)
                } label: {
                    Image(systemName: "play.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .help("Play this line")
                .accessibilityLabel("Play this line from the recording")
                .accessibilityHint("Plays only the audio for this caption")
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $accessibleEditorOpen) { correctionEditor(accessible: true).frame(minWidth: 420) }
        .contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") { copy(display) }
            Button("Correct words in this line…", systemImage: "pencil") { openAccessibleEditor() }
        }
    }

    private func token(_ index: Int) -> some View {
        let range = words[index]
        let textRange = Range(range, in: display)!
        let tokenText = display[textRange]
        let isSelected = selectedWords.map { $0.contains(index) } ?? false
        return Button {
            let shift = NSEvent.modifierFlags.contains(.shift)
            if shift, let selectedWords {
                self.selectedWords = min(selectedWords.lowerBound, index)...max(selectedWords.upperBound, index)
            } else {
                selectedWords = index...index
            }
            replacement = selectedPhraseForCurrentSelection(index: index, extend: shift)
            replacementSelection = TextSelection(range: replacement.startIndex..<replacement.endIndex)
            editorOpen = true
        } label: {
            Text(tokenText + trailingText(after: range))
                .foregroundStyle(.primary)
                .padding(.vertical, 2)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .selectedTextBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.7), lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .help("Select \(tokenText) to correct it")
    }

    private func trailingText(after range: NSRange) -> String {
        let end = NSMaxRange(range)
        let next = words.first(where: { $0.location >= end })?.location ?? (display as NSString).length
        return (display as NSString).substring(with: NSRange(location: end, length: max(0, next - end)))
    }

    private func selectedPhraseForCurrentSelection(index: Int, extend: Bool) -> String {
        let selection: ClosedRange<Int>
        if extend, let selectedWords {
            selection = min(selectedWords.lowerBound, index)...max(selectedWords.upperBound, index)
        } else { selection = index...index }
        guard let start = Range(words[selection.lowerBound], in: display),
              let end = Range(words[selection.upperBound], in: display) else { return "" }
        return String(display[start.lowerBound..<end.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func correctionEditor(accessible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(accessible ? "Correct this line" : "Correct selected words")
                .font(.headline)
            Text(accessible ? "Heard: \(line.heard)" : "Heard: \(selectedPhrase)")
                .foregroundStyle(.glassSecondary).textSelection(.enabled)
            TextField("Should be:", text: $replacement, selection: $replacementSelection)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { accessible ? saveLineEdit() : saveRule() }
            HStack {
                Button("Cancel") { editorOpen = false; accessibleEditorOpen = false; selectedWords = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if accessible {
                    // The whole line is being rewritten here, so a rule (which
                    // would match the entire sentence) makes no sense.
                    Button("Save this line") { saveLineEdit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Only this line") { saveLineEdit() }
                        .keyboardShortcut("\r", modifiers: [.command])
                    Button("Always fix this") { saveRule() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(16)
        .onAppear {
            if accessible { selectedWords = nil; replacement = display }
            else { replacement = selectedPhrase }
            replacementSelection = TextSelection(range: replacement.startIndex..<replacement.endIndex)
            fieldFocused = true
        }
        .onKeyPress(.escape) { editorOpen = false; accessibleEditorOpen = false; return .handled }
    }

    @FocusState private var fieldFocused: Bool

    private func saveRule() {
        let heard = accessibleEditorOpen ? line.heard : selectedPhrase
        guard !heard.isEmpty, !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        corrections.add(heard: heard, replacement: replacement)
        editorOpen = false
        accessibleEditorOpen = false
        selectedWords = nil
    }

    private func saveLineEdit() {
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if accessibleEditorOpen {
            transcripts.setEdited(replacement, line: line.id, in: session.id)
        } else if let selectedWords,
                  let start = Range(words[selectedWords.lowerBound], in: display),
                  let end = Range(words[selectedWords.upperBound], in: display) {
            var text = display
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: replacement)
            transcripts.setEdited(text, line: line.id, in: session.id)
        }
        editorOpen = false
        accessibleEditorOpen = false
        selectedWords = nil
    }

    private func openAccessibleEditor() {
        replacement = display
        replacementSelection = TextSelection(range: replacement.startIndex..<replacement.endIndex)
        accessibleEditorOpen = true
    }

    private func moveSelection(_ delta: Int) {
        guard !words.isEmpty else { return }
        let current = selectedWords?.upperBound ?? (delta > 0 ? -1 : words.count)
        let next = min(words.count - 1, max(0, current + delta))
        selectedWords = next...next
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum WordSelection {
    static func ranges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}

/// Lays word tokens out left to right, wrapping at the available width.
/// Measuring and placing share one row computation so they always agree.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .greatestFiniteMagnitude)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + size.width > maxWidth {
                rows.append(Row())
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

private func timeString(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

#Preview {
    let services = MacCaptionEngine.makePreviewServices()
    TranscriptReviewView(transcripts: services.transcripts, corrections: services.corrections)
}
