import SwiftUI

private struct TranscriptCopyKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var transcriptCopy: (() -> Void)? {
        get { self[TranscriptCopyKey.self] }
        set { self[TranscriptCopyKey.self] = newValue }
    }
}

struct TranscriptCommands: Commands {
    @FocusedValue(\.transcriptCopy) private var copyTranscript

    var body: some Commands {
        // Added beside the standard pasteboard commands, not replacing Copy,
        // so ⌘C keeps working in text fields such as the correction editor.
        CommandGroup(after: .pasteboard) {
            Button("Copy Transcript") { copyTranscript?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyTranscript == nil)
        }
    }
}
