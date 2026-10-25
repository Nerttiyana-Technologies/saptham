import AppKit
import SapthamCore
import SwiftUI
import UniformTypeIdentifiers

/// Which transcript the Transcripts window shows, and the way voice notes
/// get in: shared by the window and the menu-bar panel, so either can open a
/// note and the window selects its transcript.
@MainActor
@Observable
final class TranscriptNavigation {
    var selectedSessionID: TranscriptSession.ID?
    /// Why the last voice note could not be opened; the window shows it.
    var error: String?
    @ObservationIgnored private let voiceNotes: VoiceNotes

    init(voiceNotes: VoiceNotes) {
        self.voiceNotes = voiceNotes
    }

    func isTranscribing(_ sessionID: TranscriptSession.ID) -> Bool {
        voiceNotes.jobs.contains { $0.id == sessionID && $0.status == .transcribing }
    }

    func openVoiceNote(_ file: URL) {
        do {
            selectedSessionID = try voiceNotes.transcribe(file)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Asks for sound files and opens each. Returns false when cancelled.
    @discardableResult
    func chooseVoiceNotes() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Transcribe Voice Notes"
        panel.message = "Choose voice messages or recordings. They are transcribed on this Mac."
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return false }
        for file in panel.urls { openVoiceNote(file) }
        return true
    }
}

/// The Transcripts window: the review view, plus errors from voice notes.
/// Files opened with Saptham reach SapthamAppDelegate, which opens this
/// window through its `saptham://transcripts` URL (see SapthamMacApp).
struct TranscriptsWindow: View {
    let transcripts: TranscriptLibrary
    let corrections: CorrectionBook
    let declinedSuggestions: DeclinedSuggestions
    @Bindable var navigation: TranscriptNavigation

    var body: some View {
        TranscriptReviewView(transcripts: transcripts, corrections: corrections, declinedSuggestions: declinedSuggestions,
                             selectedSessionID: $navigation.selectedSessionID,
                             isTranscribing: navigation.isTranscribing)
            .alert("Could not transcribe", isPresented: Binding(
                get: { navigation.error != nil },
                set: { if !$0 { navigation.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(navigation.error ?? "")
            }
    }
}
