import AppKit
import SapthamCore
import SwiftUI

struct SapthamSettingsView: View {
    let transcripts: TranscriptLibrary
    @AppStorage(SapthamSettings.recordCalls) private var recordCalls = SapthamSettings.recordCallsDefault
    @AppStorage(SapthamSettings.autoCaptionCalls) private var autoCaptionCalls = SapthamSettings.autoCaptionCallsDefault
    @AppStorage(SapthamSettings.keepDays) private var keepDays = SapthamSettings.keepDaysDefault
    @State private var confirmsDeleteAll = false
    @State private var showsNotices = false

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
            Section("About") {
                Button("Third-party notices…", systemImage: "doc.text") { showsNotices = true }
                Text("Tamil captions use AI4Bhārat's IndicConformer speech model, running on this Mac.")
                    .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNotices) { ThirdPartyNoticesView() }
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

/// The generated Support/ThirdPartyNotices.txt, as shipped in the app.
private struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private let text: String = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "The notices file is missing from this copy of Saptham."

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 620, height: 520)
    }
}

#Preview {
    let services = MacCaptionEngine.makePreviewServices()
    SapthamSettingsView(transcripts: services.transcripts)
}
