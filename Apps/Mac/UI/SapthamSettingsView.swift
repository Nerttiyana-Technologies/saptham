import AppKit
import SapthamCore
import SwiftUI

struct SapthamSettingsView: View {
    let transcripts: TranscriptLibrary
    let soundAlerts: SoundAlertListener
    /// Nil in demo mode.
    var nameListener: NameListener? = nil
    /// Nil in previews.
    var signs: SignDictionary? = nil
    /// Asked when the user turns alerts on (notification permission).
    var alertsTurnedOn: () -> Void = {}
    @AppStorage(SapthamSettings.soundAlerts) private var alertsOn = SapthamSettings.soundAlertsDefault
    @AppStorage(SapthamSettings.soundAlertKinds) private var alertKinds = SapthamSettings.soundAlertKindsDefault
    @AppStorage(SapthamSettings.alertNames) private var alertNames = SapthamSettings.alertNamesDefault
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
            Section("Sound alerts") {
                Toggle("Alert me to sounds around this Mac", isOn: $alertsOn)
                    .onChange(of: alertsOn) { _, on in if on { alertsTurnedOn() } }
                Text("Saptham listens through the microphone and flashes the screen for the sounds you choose. The microphone stays on while this is on, so the orange microphone light shows. Nothing is recorded or sent anywhere.")
                    .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
                if alertsOn {
                    ForEach(SoundAlertKind.all) { kind in
                        Toggle(isOn: alertKindBinding(kind.id)) {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                    if let problem = soundAlerts.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if !soundAlerts.recent.isEmpty {
                        LabeledContent("Recent") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(soundAlerts.recent.prefix(5)) { alert in
                                    Text("\(alert.kind.title) · \(alert.time.formatted(date: .omitted, time: .shortened))")
                                }
                            }
                        }
                    }
                }
                Button("Show a test alert", systemImage: "bell.badge") { soundAlerts.showTest() }
            }
            Section("Name alerts") {
                TextField("Your names", text: $alertNames, prompt: Text("e.g. Priya, பிரியா, Amma"))
                Text("Saptham flashes the screen when someone near this Mac, or a caller, says one of these, whatever it is captioning. Videos and other sound playing never alert. Separate names with commas, and add the Tamil spelling and any nickname people call you. Leave empty to turn name alerts off.")
                    .font(.callout).foregroundStyle(.glassSecondary).fixedSize(horizontal: false, vertical: true)
                if let problem = nameListener?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if nameListener?.isListening == true {
                    Label("Listening for your name in every mode", systemImage: "ear")
                        .font(.callout).foregroundStyle(.glassSecondary)
                }
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
            if let signs { SignLanguageSettingsSection(signs: signs) }
            #if DEBUG
            Section("Sign packs (Debug)") {
                DebugSignPackSection(folder: MacCaptionEngine.dataFolder.appending(path: SignDictionary.folderName), showsTitle: false)
            }
            #endif
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

    private func alertKindBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { alertKinds.split(separator: ",").contains(Substring(id)) },
            set: { on in
                var ids = Set(alertKinds.split(separator: ",").map(String.init))
                if on { ids.insert(id) } else { ids.remove(id) }
                // Kept in catalogue order so the saved value is stable.
                alertKinds = SoundAlertKind.all.map(\.id).filter(ids.contains).joined(separator: ",")
            })
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
    SapthamSettingsView(transcripts: services.transcripts, soundAlerts: SoundAlertListener(present: { _ in }))
}
