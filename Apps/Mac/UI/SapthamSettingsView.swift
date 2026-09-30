import AppKit
import SapthamCore
import SwiftUI

struct SapthamSettingsView: View {
    let transcripts: TranscriptLibrary
    @AppStorage(SapthamSettings.recordCalls) private var recordCalls = SapthamSettings.recordCallsDefault
    @AppStorage(SapthamSettings.autoCaptionCalls) private var autoCaptionCalls = SapthamSettings.autoCaptionCallsDefault
    @AppStorage(SapthamSettings.keepDays) private var keepDays = SapthamSettings.keepDaysDefault
    @State private var confirmsDeleteAll = false

    var body: some View {
        Form {
            Section("Calls") {
                Toggle("Caption calls automatically", isOn: $autoCaptionCalls)
                Text("When you answer a call on this Mac, captions and the caption window start by themselves, and the window hides again after the call.")
                    .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Call recording") {
                Toggle("Record phone calls", isOn: $recordCalls)
                Text("Recordings of phone calls stay on this Mac and are used to review calls and, later, to teach Saptham your callers' voices. Takes effect from the next call.")
                    .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Storage") {
                Picker("Keep transcripts and recordings for", selection: $keepDays) {
                    ForEach(SapthamSettings.keepDaysChoices, id: \.self) { days in
                        Text(keepDaysName(days)).tag(days)
                    }
                }
                Button("Delete all transcripts and recordings…", role: .destructive) {
                    confirmsDeleteAll = true
                }
                .confirmationDialog("Delete all transcripts and recordings?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                    Button("Delete Everything", role: .destructive) { transcripts.deleteAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }
                Button("Show in Finder", systemImage: "folder") {
                    let folder = MacCaptionEngine.dataFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        }
        .formStyle(.grouped)
        // Drop the form's opaque page so the glass shows between the
        // grouped sections; each section keeps its own readable card.
        .scrollContentBackground(.hidden)
        .glassWindowBackground()
        .frame(width: 520)
        .padding()
    }

    private func keepDaysName(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 7: "1 week"
        case 30: "30 days"
        case 90: "90 days"
        case 365: "1 year"
        default: "Forever"
        }
    }
}

#Preview {
    let services = MacCaptionEngine.makePreviewServices()
    SapthamSettingsView(transcripts: services.transcripts)
}
