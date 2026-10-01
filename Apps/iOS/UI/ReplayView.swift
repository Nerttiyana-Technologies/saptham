import SapthamCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReplayView: View {
    let services: PhoneAppServices
    let onBack: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("captionTextSize") private var textSize = Monsoon.defaultCaptionSize
    @State private var selectedSessionID: TranscriptSession.ID?
    @State private var selectedLineID: TranscriptLine.ID?
    @State private var searchOpen = false
    @State private var query = ""
    @State private var correctingWord: String?
    @State private var correctionText = ""
    @State private var fileImporterOpen = false
    @State private var importError: String?
    @State private var pendingDelete = false
    @State private var player = TranscriptAudioPlayer()
    @State private var hapticLineID: TranscriptLine.ID?
    @State private var askOpen = false
    @State private var askQuestion = ""
    @State private var assistantReadiness: ConversationAssistant.Readiness?
    @State private var assistantBusy = false
    @State private var assistantAnswer: ConversationAssistant.Answer?
    @State private var assistantSummary: String?
    @State private var assistantError: String?
    @State private var assistantResultSessionID: TranscriptSession.ID?

    private var sessions: [TranscriptSession] { services.transcripts.sessions }
    private var session: TranscriptSession? { sessions.first { $0.id == selectedSessionID } }
    private var lines: [TranscriptLine] { session?.lines ?? [] }
    private var selectedIndex: Int {
        guard !lines.isEmpty else { return 0 }
        return lines.firstIndex(where: { $0.id == selectedLineID }) ?? 0
    }
    private var selectedLine: TranscriptLine? { lines.indices.contains(selectedIndex) ? lines[selectedIndex] : nil }
    private var display: (TranscriptLine) -> String { { $0.displayText(using: services.corrections.corrector) } }

    var body: some View {
        ZStack {
            MonsoonBackdrop()
            VStack(spacing: 10) {
                if let session {
                    header(session)
                    ScrollView {
                        VStack(spacing: 0) {
                            nearbyLines(before: true)
                            readingBand(session)
                            nearbyLines(before: false)
                            LightRule().padding(.top, 16)
                            waveform.padding(.top, 10)
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls(session)
                } else {
                    Spacer()
                    emptyBand
                    Spacer()
                    liveButton
                }
                if let importError { errorBanner(importError) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: selectInitial)
        .onChange(of: sessions) { _, updated in
            if !updated.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = updated.first?.id
                selectedLineID = updated.first?.lines.first?.id
            }
        }
        .onChange(of: selectedSessionID) { _, id in
            if let selectedSession = sessions.first(where: { $0.id == id }),
               !selectedSession.lines.contains(where: { $0.id == selectedLineID }) {
                selectedLineID = selectedSession.lines.first?.id
            }
            if askOpen, let selectedSession = sessions.first(where: { $0.id == id }) {
                assistantReadiness = services.assistant.readiness(for: selectedSession.languageID)
                assistantError = nil
            }
            player.stop()
        }
        .onChange(of: selectedLineID) { _, id in hapticLineID = id }
        .sensoryFeedback(.selection, trigger: hapticLineID)
        .fileImporter(isPresented: $fileImporterOpen, allowedContentTypes: [.audio], allowsMultipleSelection: false, onCompletion: importAudio)
        .confirmationDialog("Delete this conversation?", isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("Delete conversation", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding<CorrectionWord?>(get: { correctingWord.map { CorrectionWord(word: $0) } },
                                              set: { correctingWord = $0?.word })) { item in
            correctionSheet(word: item.word).presentationBackground(.clear)
        }
        .onDisappear { player.stop() }
    }

    private func header(_ session: TranscriptSession) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 34, weight: .light, design: .rounded))
                .foregroundStyle(Monsoon.ink)
            Text("Conversation · \(durationMinutes(of: session)) min")
                .font(.caption).foregroundStyle(Monsoon.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func nearbyLines(before: Bool) -> some View {
        let indices: [Int]
        if lines.isEmpty { indices = [] }
        else if before { indices = Array(max(0, selectedIndex - 3)..<selectedIndex) }
        else if selectedIndex + 1 < lines.count { indices = Array((selectedIndex + 1)..<min(lines.count, selectedIndex + 4)) }
        else { indices = [] }
        return VStack(alignment: .leading, spacing: 0) {
            if before { thread(indices: indices, before: true) }
            else { thread(indices: indices, before: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thread(indices: [Int], before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                let line = lines[index]
                let beadSize = before ? CGFloat(4 + offset * 3 / max(indices.count, 1)) : CGFloat(5)
                let beadOpacity = before ? 0.18 + 0.3 * Double(offset + 1) / Double(max(indices.count, 1)) : 0.16
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        if before && offset == 0 { Rectangle().fill(.clear).frame(width: 1, height: 9) }
                        Rectangle().fill(Monsoon.accent.opacity(before ? 0.35 : 0.22)).frame(width: 1, height: 14)
                        Rectangle().fill(Monsoon.accent.opacity(beadOpacity))
                            .frame(width: beadSize, height: beadSize).rotationEffect(.degrees(45)).padding(.vertical, 3)
                        Rectangle().fill(Monsoon.accent.opacity(before ? 0.25 : 0.12)).frame(width: 1, height: 14)
                    }
                    .frame(width: 10)
                    Text(display(line))
                        .font(.system(size: max(16, textSize * 0.58), weight: .medium))
                        .foregroundStyle(before ? Monsoon.ink3 : Monsoon.ink3.opacity(0.78))
                        .blur(radius: before ? CGFloat(min(1, Double(indices.count - offset) * 0.22)) : 0)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { select(line) }
                        .accessibilityLabel(display(line))
                }
            }
        }
        .padding(.vertical, before ? 1 : 5)
    }

    private func readingBand(_ session: TranscriptSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(selectedLine?.time.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.caption.weight(.medium)).foregroundStyle(Monsoon.accent)
                Spacer()
                if let line = selectedLine, line.audio != nil,
                   let url = services.transcripts.recordingURL(for: session) {
                    Button { if let span = line.audio { player.play(span, from: url) } } label: {
                        Image(systemName: "play").font(.system(size: 19, weight: .regular)).foregroundStyle(Monsoon.ink3)
                    }
                    .buttonStyle(.glyph).accessibilityLabel("Play this line")
                }
            }
            if let line = selectedLine {
                let tokens = WordToken.tokens(in: display(line))
                WordFlowLayout(spacing: 2) {
                    ForEach(tokens.indices, id: \.self) { index in
                        let token = tokens[index]
                        Button {
                            correctingWord = token.word
                            correctionText = token.word
                        } label: {
                            Text(token.rendered).font(.system(size: textSize, weight: .bold))
                                .foregroundStyle(Monsoon.ink).contentTransition(.opacity)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Correct word \(token.word)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: line.id)
            } else {
                Text("No captions in this conversation").font(.system(size: textSize, weight: .bold)).foregroundStyle(Monsoon.ink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monsoonBand()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            if value.translation.height < -18 { stepLine(1) }
            else if value.translation.height > 18 { stepLine(-1) }
        })
        .accessibilityHint("Swipe up or down to move between caption lines")
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let count = max(lines.count, 1)
            HStack(alignment: .center, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    let barHeight = CGFloat(min(38, max(8, display(line).count / 3)))
                    Rectangle().fill(index <= selectedIndex ? Monsoon.accent : Monsoon.ink3.opacity(0.5))
                        .frame(width: max(1, (width - CGFloat(count - 1) * 2) / CGFloat(count)), height: barHeight)
                        .overlay(alignment: .top) {
                            if index == selectedIndex {
                                Rectangle().fill(Monsoon.accent).frame(width: 2, height: 44).offset(y: -4).monsoonGlow()
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !lines.isEmpty else { return }
                let index = min(lines.count - 1, max(0, Int(value.location.x / max(width, 1) * CGFloat(lines.count))))
                select(lines[index])
            })
            .accessibilityElement().accessibilityLabel("Conversation waveform, line \(selectedIndex + 1) of \(lines.count)")
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: stepLine(1); case .decrement: stepLine(-1); @unknown default: break }
            }
        }
        .frame(height: 48).accessibilityHint("Drag across to move through lines")
    }

    private func controls(_ session: TranscriptSession) -> some View {
        VStack(spacing: 4) {
            if askOpen { askStrip(session) }
            if searchOpen {
                HStack(spacing: 8) {
                    TextField("Find in conversations", text: $query)
                        .font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                        .padding(.horizontal, 4).frame(minHeight: 44)
                        .underlineField().onChange(of: query) { _, value in search(value) }
                    Button { searchOpen = false; query = "" } label: { Image(systemName: "xmark").foregroundStyle(Monsoon.ink3) }
                        .buttonStyle(.glyph).accessibilityLabel("Close search")
                }
                if !query.isEmpty && !hasMatches(query) { Text("No matches").font(.caption).foregroundStyle(Monsoon.ink3) }
                if !query.isEmpty && hasMatches(query) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 18) {
                            ForEach(sessions) { matchSession in
                                ForEach(matchSession.lines.indices.filter({ display(matchSession.lines[$0]).localizedCaseInsensitiveContains(query) }), id: \.self) { index in
                                    let matchLine = matchSession.lines[index]
                                    Button { selectedSessionID = matchSession.id; selectedLineID = matchLine.id } label: {
                                        Text("\(matchSession.startedAt.formatted(date: .omitted, time: .shortened)) · \(display(matchLine))")
                                            .font(.caption).foregroundStyle(Monsoon.ink2).frame(minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(matchSession.sourceTitle), line \(index + 1), \(display(matchLine))")
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            HStack(spacing: 10) {
                neighborButton(previous: true)
                neighborButton(previous: false)
                Spacer(minLength: 0)
                Button { searchOpen.toggle() } label: { Image(systemName: "magnifyingglass").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Find in conversations")
                Button { fileImporterOpen = true } label: { Image(systemName: "waveform.badge.plus").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Add voice note")
                Button { openAsk(session) } label: { Image(systemName: "sparkles").foregroundStyle(askOpen ? Monsoon.accent : Monsoon.ink3).monsoonGlow(askOpen ? Monsoon.accent : .clear) }
                    .buttonStyle(.glyph).accessibilityLabel("Ask about this conversation")
                Menu {
                    Button("Copy conversation", systemImage: "doc.on.doc") { copy(session) }
                    ShareLink(item: conversationText(session)) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Delete conversation", systemImage: "trash", role: .destructive) { pendingDelete = true }
                    Button("Settings", systemImage: "gearshape") { onOpenSettings() }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Monsoon.ink3).frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.glyph).accessibilityLabel("More conversation actions")
            }
            liveButton.frame(maxWidth: .infinity)
            if let job = services.voiceNotes.jobs.first(where: { $0.id == session.id }), case .transcribing = job.status {
                HStack(spacing: 8) { ProgressView().tint(Monsoon.accent); Text("Transcribing voice note…").font(.caption).foregroundStyle(Monsoon.ink2) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let job = services.voiceNotes.jobs.first(where: { $0.id == session.id }), case .failed(let message) = job.status {
                errorBanner(message)
            }
        }
    }

    private func askStrip(_ session: TranscriptSession) -> some View {
        let readiness = assistantReadiness ?? services.assistant.readiness(for: session.languageID)
        let unavailable: Bool = { if case .unavailable = readiness { true } else { false } }()
        let limitedMessage: String? = { if case .limited(let message) = readiness { message } else { nil } }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask — e.g. what time did they say?", text: $askQuestion)
                    .font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                    .padding(.horizontal, 4).frame(minHeight: 44)
                    .underlineField().disabled(unavailable || assistantBusy)
                    .onSubmit { ask(session) }
                Button { ask(session) } label: { Image(systemName: "arrow.up").foregroundStyle(Monsoon.accent) }
                    .buttonStyle(.glyph).accessibilityLabel("Send question")
                    .disabled(unavailable || assistantBusy || askQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { summarise(session) } label: { Image(systemName: "text.alignleft").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Summarise")
                    .disabled(unavailable || assistantBusy)
                Button { closeAsk() } label: { Image(systemName: "xmark").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Close ask strip")
            }
            if let limitedMessage {
                Text(limitedMessage).font(.caption).foregroundStyle(Monsoon.ink3)
            } else if case .unavailable(let message) = readiness {
                Text(message).font(.caption).foregroundStyle(Monsoon.ink3)
            }
            if assistantBusy {
                ProgressView().tint(Monsoon.accent).frame(maxWidth: .infinity, alignment: .leading)
            } else if let assistantError {
                Text(assistantError).font(.caption).foregroundStyle(Monsoon.ink3)
            } else if let assistantAnswer, assistantResultSessionID == session.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text(assistantAnswer.text)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(assistantAnswer.text.count <= 24 ? Monsoon.accent : Monsoon.ink)
                        .monsoonGlow(assistantAnswer.text.count <= 24 ? Monsoon.accent : .clear)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sourceLineID = assistantAnswer.sourceLineID,
                       let sourceLine = session.lines.first(where: { $0.id == sourceLineID }) {
                        Text("from \(sourceLine.time.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(Monsoon.ink3)
                    }
                    assistantPrivacyMark
                }
            } else if let assistantSummary, assistantResultSessionID == session.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text(assistantSummary).font(.system(size: 20)).foregroundStyle(Monsoon.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    assistantPrivacyMark
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monsoonBand()
    }

    private var assistantPrivacyMark: some View {
        Label("Answered on this iPhone", systemImage: "lock.fill")
            .font(.caption2).foregroundStyle(Monsoon.ink3)
            .accessibilityLabel("Answered on this iPhone")
    }

    private func openAsk(_ session: TranscriptSession) {
        assistantReadiness = services.assistant.readiness(for: session.languageID)
        assistantError = nil
        assistantAnswer = nil
        assistantSummary = nil
        assistantResultSessionID = nil
        askOpen.toggle()
    }

    private func closeAsk() {
        askOpen = false
        askQuestion = ""
        assistantReadiness = nil
        assistantAnswer = nil
        assistantSummary = nil
        assistantResultSessionID = nil
        assistantError = nil
    }

    private func ask(_ session: TranscriptSession) {
        let question = askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !assistantBusy else { return }
        assistantBusy = true
        assistantError = nil
        assistantAnswer = nil
        assistantSummary = nil
        assistantResultSessionID = nil
        Task { @MainActor in
            defer { assistantBusy = false }
            do {
                let answer = try await services.assistant.answer(question, in: session, corrector: services.corrections.corrector)
                assistantResultSessionID = session.id
                assistantAnswer = answer
                if let sourceLineID = answer.sourceLineID,
                   session.lines.contains(where: { $0.id == sourceLineID }) {
                    selectedSessionID = session.id
                    selectedLineID = sourceLineID
                }
            } catch {
                assistantError = error.localizedDescription
            }
        }
    }

    private func summarise(_ session: TranscriptSession) {
        guard !assistantBusy else { return }
        assistantBusy = true
        assistantError = nil
        assistantAnswer = nil
        assistantSummary = nil
        assistantResultSessionID = nil
        Task { @MainActor in
            defer { assistantBusy = false }
            do {
                assistantSummary = try await services.assistant.summary(of: session, corrector: services.corrections.corrector)
                assistantResultSessionID = session.id
            } catch {
                assistantError = error.localizedDescription
            }
        }
    }

    private func neighborButton(previous: Bool) -> some View {
        let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
        let target = previous ? index + 1 : index - 1
        let candidate = sessions.indices.contains(target) ? sessions[target] : nil
        return Button { if let candidate { selectedSessionID = candidate.id } } label: {
            HStack(spacing: 5) {
                if previous { Image(systemName: "arrow.left").font(.system(size: 20, weight: .light)).foregroundStyle(candidate == nil ? Monsoon.ink3.opacity(0.4) : Monsoon.accent) }
                Text(candidate?.startedAt.formatted(date: .omitted, time: .shortened) ?? (previous ? "Earlier" : "Later"))
                    .font(.caption).foregroundStyle(Monsoon.ink3).lineLimit(1)
                if !previous { Image(systemName: "arrow.right").font(.system(size: 20, weight: .light)).foregroundStyle(candidate == nil ? Monsoon.ink3.opacity(0.4) : Monsoon.accent) }
            }
        }
        .buttonStyle(.glyph).disabled(candidate == nil)
        .accessibilityLabel(candidate.map { "\(previous ? "Previous" : "Next") conversation, \($0.sourceTitle), \($0.startedAt.formatted(date: .omitted, time: .shortened))" } ?? (previous ? "No previous conversation" : "No next conversation"))
    }

    private var liveButton: some View {
        Button(action: onBack) {
            VStack(spacing: 0) {
                Image(systemName: "arrow.up").font(.system(size: 22, weight: .light)).foregroundStyle(Monsoon.accent).monsoonGlow()
                Text("Live").font(.caption2).foregroundStyle(Monsoon.ink3)
            }
        }
        .buttonStyle(.glyph).accessibilityLabel("Live")
    }

    private var emptyBand: some View {
        Text("Nothing yet — conversations you caption appear here")
            .font(.system(size: textSize, weight: .bold)).foregroundStyle(Monsoon.ink)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
            .monsoonBand()
    }

    private func correctionSheet(word: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Replacement", text: $correctionText)
                    .font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                    .padding(.horizontal, 4).frame(minHeight: 48).underlineField()
                Button { correctingWord = nil } label: { Image(systemName: "xmark").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Cancel correction")
            }
            HStack {
                correctionAction(symbol: "text.line.first.and.arrowtriangle.forward", caption: "this line", label: "Correct only this line") { applyLineCorrection(word: word) }
                Spacer()
                correctionAction(symbol: "checkmark", caption: "everywhere", label: "Correct everywhere") {
                    services.corrections.add(heard: word, replacement: correctionText); correctingWord = nil
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity)
        .monsoonBand().padding(.top, 10)
    }

    private func correctionAction(symbol: String, caption: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular)).foregroundStyle(Monsoon.accent)
                Text(caption).font(.caption2).foregroundStyle(Monsoon.ink3)
            }
        }
        .buttonStyle(.glyph).accessibilityLabel(label)
    }

    private func importAudio(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let id = try services.voiceNotes.transcribe(url)
            selectedSessionID = id
            importError = nil
        } catch { importError = error.localizedDescription }
    }

    private func search(_ text: String) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        for candidate in sessions {
            if let match = candidate.lines.first(where: { display($0).localizedCaseInsensitiveContains(needle) }) {
                selectedSessionID = candidate.id; selectedLineID = match.id; return
            }
        }
    }

    private func hasMatches(_ text: String) -> Bool { sessions.contains { $0.lines.contains { display($0).localizedCaseInsensitiveContains(text) } } }
    private func selectInitial() { selectedSessionID = selectedSessionID ?? sessions.first?.id; selectedLineID = selectedLineID ?? session?.lines.first?.id }
    private func select(_ line: TranscriptLine) { selectedLineID = line.id }
    private func stepLine(_ amount: Int) {
        guard !lines.isEmpty else { return }
        selectedLineID = lines[min(lines.count - 1, max(0, selectedIndex + amount))].id
    }
    private func applyLineCorrection(word: String) {
        guard let session, let line = selectedLine else { correctingWord = nil; return }
        let source = display(line)
        guard let range = source.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { correctingWord = nil; return }
        var edited = source; edited.replaceSubrange(range, with: correctionText)
        services.transcripts.setEdited(edited, line: line.id, in: session.id); correctingWord = nil
    }
    private func deleteCurrent() {
        guard let session else { return }
        services.transcripts.delete(session.id)
        selectedSessionID = services.transcripts.sessions.first?.id
        selectedLineID = services.transcripts.sessions.first?.lines.first?.id
    }
    private func copy(_ session: TranscriptSession) { UIPasteboard.general.string = conversationText(session) }
    private func conversationText(_ session: TranscriptSession) -> String { session.lines.map { "\($0.time.formatted(date: .omitted, time: .shortened))  \(display($0))" }.joined(separator: "\n") }
    private func durationMinutes(of session: TranscriptSession) -> Int {
        let seconds = Int(max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)))
        return max(1, Int((Double(seconds) / 60).rounded()))
    }
    private func errorBanner(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(Monsoon.ink2).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { LightRule(colour: Monsoon.lightning) }
    }
}

private extension View {
    func underlineField() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Monsoon.accent).frame(height: 2) }
    }
}

private struct CorrectionWord: Identifiable { let word: String; var id: String { word } }

private struct WordToken {
    let word: String
    let rendered: String
    static func tokens(in text: String) -> [WordToken] {
        text.split(whereSeparator: \.isWhitespace).map { part in
            let value = String(part)
            let word = value.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return WordToken(word: word.isEmpty ? value : word, rendered: value + " ")
        }
    }
}

private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    ReplayView(services: PhoneCaptionEngine.makePreviewServices(), onBack: {}, onOpenSettings: {})
}
