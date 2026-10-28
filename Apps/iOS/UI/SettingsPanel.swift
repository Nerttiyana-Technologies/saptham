import SapthamCore
import SwiftUI

struct SettingsPanel: View {
    let services: PhoneAppServices

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SapthamSettings.soundAlerts) private var alertsOn = SapthamSettings.soundAlertsDefault
    @AppStorage(SapthamSettings.soundAlertKinds) private var alertKinds = SapthamSettings.soundAlertKindsDefault
    @AppStorage(SapthamSettings.alertNames) private var alertNames = SapthamSettings.alertNamesDefault
    @AppStorage(SapthamSettings.keepDays) private var keepDays = SapthamSettings.keepDaysDefault
    @AppStorage(PhoneSettings.liveActivity) private var liveActivityOn = PhoneSettings.liveActivityDefault
    @AppStorage(PhoneSettings.soundDirection) private var soundDirectionOn = PhoneSettings.soundDirectionDefault
    @State private var confirmsDeleteAll = false
    @State private var showsNotices = false
    @State private var editingRuleID: CorrectionRule.ID?
    @State private var heard = ""
    @State private var replacement = ""
    @State private var addingCorrection = false
    @State private var newHeard = ""
    @State private var newReplacement = ""
    @State private var recentlyToggledKind: String?

    var body: some View {
        ZStack {
            MonsoonBackdrop()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark").foregroundStyle(Monsoon.accent)
                        }
                        .buttonStyle(.glyph).accessibilityLabel("Done with settings")
                    }
                    soundGroup
                    LightRule().padding(.vertical, 18)
                    namesGroup
                    LightRule().padding(.vertical, 18)
                    correctionsGroup
                    LightRule().padding(.vertical, 18)
                    transcriptGroup
                    LightRule().padding(.vertical, 18)
                    liveActivityGroup
                    LightRule().padding(.vertical, 18)
                    batteryGroup
                    LightRule().padding(.vertical, 18)
                    directionGroup
                    LightRule().padding(.vertical, 18)
                    SignLanguageSettingsGroup(signs: services.signs)
                    #if DEBUG
                    LightRule().padding(.vertical, 18)
                    DebugSignPackSection(folder: PhoneCaptionEngine.dataFolder.appending(path: SignDictionary.folderName))
                        .foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                    #endif
                    LightRule().padding(.vertical, 18)
                    aboutGroup
                }
                .padding(.horizontal, 18).padding(.bottom, 22)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onChange(of: alertsOn) { _, enabled in if enabled { services.alerts.requestNotificationPermission() } }
        .confirmationDialog("Delete all transcripts and recordings?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { services.transcripts.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .sheet(isPresented: $showsNotices) { ThirdPartyNoticesView() }
    }

    private var soundGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                // The whole row is the switch: the ear, the title and the
                // state all toggle it (the ear alone was too small a target
                // to find, 2026-10-02).
                Button { alertsOn.toggle() } label: {
                    HStack(alignment: .center, spacing: 14) {
                        LitGlyph(systemImage: "ear", isLit: alertsOn, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sound alerts").font(.headline).foregroundStyle(Monsoon.ink)
                            Text(alertsOn ? "On · listening" : "Off · tap to turn on")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(alertsOn ? Monsoon.accent : Monsoon.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.glyph)
                .sensoryFeedback(.selection, trigger: alertsOn)
                .accessibilityLabel("Sound alerts")
                .accessibilityValue(alertsOn ? "On" : "Off")
                .accessibilityHint("Double-tap to turn \(alertsOn ? "off" : "on")")
                Button { services.alerts.showTest() } label: {
                    Image(systemName: "bell.badge").foregroundStyle(Monsoon.ink3)
                }
                .buttonStyle(.glyph).accessibilityLabel("Show a test sound alert")
            }
            if alertsOn {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 8) {
                    ForEach(SoundAlertKind.all) { kind in
                        Button {
                            let enabled = !isAlertKindOn(kind.id)
                            alertKindBinding(kind.id).wrappedValue = enabled
                            recentlyToggledKind = kind.id
                        } label: {
                            LitGlyph(systemImage: kind.systemImage, isLit: isAlertKindOn(kind.id), size: 25)
                                .frame(maxWidth: .infinity, minHeight: 62)
                        }
                        .buttonStyle(.glyph)
                        .accessibilityLabel("\(kind.title), \(isAlertKindOn(kind.id) ? "on" : "off")")
                    }
                }
                if let kind = SoundAlertKind.all.first(where: { $0.id == recentlyToggledKind }) {
                    Text(kind.title).font(.caption).foregroundStyle(Monsoon.ink3)
                }
                if let problem = services.alerts.problem {
                    Text(problem).font(.caption).foregroundStyle(Monsoon.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Monsoon.lightning).frame(height: 1) }
                        .accessibilityLabel("Sound alert issue: \(problem)")
                }
                if !services.alerts.recent.isEmpty {
                    LightRule(colour: Monsoon.dim).padding(.vertical, 2)
                    ForEach(services.alerts.recent.prefix(5)) { alert in
                        HStack(spacing: 8) {
                            Image(systemName: alert.kind.systemImage).foregroundStyle(Monsoon.ink3).accessibilityHidden(true)
                            Text(alert.kind.title).font(.caption).foregroundStyle(Monsoon.ink2)
                            Spacer()
                            Text(alert.time.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(Monsoon.ink3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monsoonBand()
    }

    private var namesGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person").foregroundStyle(Monsoon.ink3).accessibilityHidden(true)
                TextField("Name and spellings", text: $alertNames)
                    .font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                    .frame(minHeight: 44).settingsUnderline()
                    .accessibilityLabel("Your names and other spellings")
            }
            Text("Separate names and spellings with commas.").font(.caption).foregroundStyle(Monsoon.ink3)
        }
    }

    private var correctionsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(services.corrections.rules) { rule in
                HStack(spacing: 8) {
                    correctionThreadBead
                    if editingRuleID == rule.id {
                        TextField("Heard", text: $heard).font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                            .settingsUnderline().accessibilityLabel("Heard word")
                        Text("→").foregroundStyle(Monsoon.ink3)
                        TextField("Replacement", text: $replacement).font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                            .settingsUnderline().accessibilityLabel("Replacement word")
                        Button { saveRule(rule) } label: { Image(systemName: "checkmark").foregroundStyle(Monsoon.accent) }
                            .buttonStyle(.glyph).accessibilityLabel("Save correction")
                    } else {
                        Button { beginEditing(rule) } label: {
                            Text("\(rule.heard) → \(rule.replacement)").font(.body).foregroundStyle(Monsoon.ink)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Edit correction, \(rule.heard) to \(rule.replacement)")
                        Button(role: .destructive) { services.corrections.remove(rule.id) } label: {
                            Image(systemName: "xmark").foregroundStyle(Monsoon.ink3)
                        }
                        .buttonStyle(.glyph).accessibilityLabel("Delete correction for \(rule.heard)")
                    }
                }
            }
            if addingCorrection {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        correctionThreadBead
                        TextField("Heard", text: $newHeard).font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                            .settingsUnderline().accessibilityLabel("When the caption hears")
                        Text("→").foregroundStyle(Monsoon.ink3)
                        TextField("Replacement", text: $newReplacement).font(.body).foregroundStyle(Monsoon.ink).tint(Monsoon.accent)
                            .settingsUnderline().accessibilityLabel("Show instead")
                    }
                    HStack {
                        Spacer()
                        Button { addingCorrection = false; newHeard = ""; newReplacement = "" } label: {
                            Image(systemName: "xmark").foregroundStyle(Monsoon.ink3)
                        }.buttonStyle(.glyph).accessibilityLabel("Cancel new correction")
                        Button { addRule() } label: { Image(systemName: "checkmark").foregroundStyle(Monsoon.accent) }
                            .buttonStyle(.glyph)
                            .disabled(newHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Add correction")
                    }
                }
            } else {
                Button { addingCorrection = true } label: { Image(systemName: "plus").foregroundStyle(Monsoon.accent) }
                    .buttonStyle(.glyph).accessibilityLabel("Add correction")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var correctionThreadBead: some View {
        Rectangle().fill(Monsoon.accent.opacity(0.6)).frame(width: 6, height: 6).rotationEffect(.degrees(45))
            .frame(width: 10).accessibilityHidden(true)
    }

    private var transcriptGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep transcripts for").font(.caption).foregroundStyle(Monsoon.ink3)
            keepRuler
            HStack {
                Spacer()
                Button { confirmsDeleteAll = true } label: { Image(systemName: "trash").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Delete all transcripts and recordings")
            }
        }
    }

    private var keepRuler: some View {
        let choices = SapthamSettings.keepDaysChoices
        return HStack(spacing: 0) {
            ForEach(choices, id: \.self) { days in
                Button { keepDays = days } label: {
                    VStack(spacing: 5) {
                        Rectangle().fill(keepDays == days ? Monsoon.accent : Monsoon.ink3)
                            .frame(width: 1, height: keepDays == days ? 16 : 9)
                            .monsoonGlow(keepDays == days ? Monsoon.accent : .clear, radius: 5)
                        Text(keepDaysShortName(days)).font(.caption2)
                            .foregroundStyle(keepDays == days ? Monsoon.accent : Monsoon.ink3)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .overlay(alignment: .top) { Rectangle().fill(Monsoon.ink3.opacity(0.55)).frame(height: 1).offset(y: 7) }
                }
                .buttonStyle(.plain).accessibilityLabel("Keep transcripts for \(keepDaysName(days))")
                .accessibilityAddTraits(keepDays == days ? .isSelected : [])
            }
        }
    }

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showsNotices = true } label: { Image(systemName: "doc.text").foregroundStyle(Monsoon.ink3) }
                .buttonStyle(.glyph).accessibilityLabel("Open third-party notices")
            Text("On-device speech recognition. Audio stays on this iPhone.")
                .font(.caption).foregroundStyle(Monsoon.ink3)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption2).foregroundStyle(Monsoon.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveActivityGroup: some View {
        Button { liveActivityOn.toggle() } label: {
            HStack(alignment: .center, spacing: 14) {
                LitGlyph(systemImage: "lock.rectangle.on.rectangle", isLit: liveActivityOn, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock Screen captions").font(.headline).foregroundStyle(Monsoon.ink)
                    Text(liveActivityOn ? "On" : "Off · tap to turn on")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(liveActivityOn ? Monsoon.accent : Monsoon.ink3)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.glyph)
        .sensoryFeedback(.selection, trigger: liveActivityOn)
        .accessibilityLabel("Lock Screen captions")
        .accessibilityValue(liveActivityOn ? "On" : "Off")
        .accessibilityHint("Double-tap to turn \(liveActivityOn ? "off" : "on")")
    }

    private var batteryGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "battery.75percent").font(.system(size: 22)).foregroundStyle(Monsoon.ink3)
                    .accessibilityHidden(true)
                if let newest = services.battery.readings.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(newest.percentPerHour, specifier: "%.1f") % per hour")
                            .font(.system(size: 25, weight: .light)).foregroundStyle(Monsoon.ink)
                        Text("last session · \(Int(newest.minutes.rounded())) min")
                            .font(.caption).foregroundStyle(Monsoon.ink3)
                    }
                } else {
                    Text("Caption for 10 minutes or more on battery to measure what Saptham uses.")
                        .font(.caption).foregroundStyle(Monsoon.ink3)
                }
                Spacer(minLength: 0)
            }
            if services.battery.readings.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(services.battery.readings.dropFirst().prefix(4))) { reading in
                        Text("\(reading.startedAt.formatted(.dateTime.day().month(.abbreviated))) · \(reading.percentPerHour, specifier: "%.1f") % per hour · \(Int(reading.minutes.rounded())) min")
                            .font(.caption).foregroundStyle(Monsoon.ink3)
                    }
                }
                .padding(.leading, 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Battery use")
    }

    private var directionGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { soundDirectionOn.toggle() } label: {
                HStack(alignment: .center, spacing: 14) {
                    LitGlyph(systemImage: "ear.and.waveform", isLit: soundDirectionOn && services.direction.isAvailable, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound direction (experimental)").font(.headline).foregroundStyle(Monsoon.ink)
                        Text(soundDirectionOn ? "On" : "Off · tap to turn on")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(soundDirectionOn ? Monsoon.accent : Monsoon.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.glyph)
            .disabled(!services.direction.isAvailable)
            .sensoryFeedback(.selection, trigger: soundDirectionOn)
            .accessibilityLabel("Sound direction (experimental)")
            .accessibilityValue(soundDirectionOn ? "On" : "Off")
            .accessibilityHint(services.direction.isAvailable ? "Double-tap to turn \(soundDirectionOn ? "off" : "on")" : "Unavailable on this iPhone")

            if !services.direction.isAvailable {
                Text("This iPhone's microphone cannot tell left from right.")
                    .font(.caption).foregroundStyle(Monsoon.ink3)
            } else if soundDirectionOn {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Monsoon.ink3).frame(height: 1)
                        if let balance = services.direction.balance {
                            Circle().fill(Monsoon.accent).frame(width: 9, height: 9)
                                .monsoonGlow(radius: 6)
                                .offset(x: CGFloat((balance + 1) / 2) * max(0, geometry.size.width - 9))
                        }
                    }
                    .frame(height: 10)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)
                .accessibilityLabel("Live sound direction")
                Text("Speak from one side to try it")
                    .font(.caption).foregroundStyle(Monsoon.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alertKindBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { isAlertKindOn(id) }, set: { enabled in
            var ids = Set(alertKinds.split(separator: ",").map(String.init))
            if enabled { ids.insert(id) } else { ids.remove(id) }
            alertKinds = SoundAlertKind.all.map(\.id).filter(ids.contains).joined(separator: ",")
        })
    }

    private func isAlertKindOn(_ id: String) -> Bool { alertKinds.split(separator: ",").contains(Substring(id)) }
    private func keepDaysName(_ days: Int) -> String {
        switch days { case 1: "1 day"; case 7: "1 week"; case 30: "30 days"; case 90: "90 days"; case 365: "1 year"; default: "Forever" }
    }
    private func keepDaysShortName(_ days: Int) -> String {
        switch days { case 1: "1d"; case 7: "1w"; case 30: "30d"; case 90: "90d"; case 365: "1y"; default: "∞" }
    }
    private func beginEditing(_ rule: CorrectionRule) { editingRuleID = rule.id; heard = rule.heard; replacement = rule.replacement }
    private func saveRule(_ rule: CorrectionRule) {
        var updated = rule; updated.heard = heard; updated.replacement = replacement
        services.corrections.update(updated); editingRuleID = nil
    }
    private func addRule() {
        guard !newHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        services.corrections.add(heard: newHeard, replacement: newReplacement)
        newHeard = ""; newReplacement = ""; addingCorrection = false
    }
}

private extension View {
    func settingsUnderline() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Monsoon.accent).frame(height: 2) }
    }
}

private struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "The notices file is missing from this copy."

    var body: some View {
        ZStack {
            MonsoonBackdrop()
            VStack(alignment: .trailing, spacing: 8) {
                ScrollView {
                    Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(Monsoon.ink).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                }
                LightRule()
                Button { dismiss() } label: { Image(systemName: "checkmark").foregroundStyle(Monsoon.accent) }
                    .buttonStyle(.glyph).accessibilityLabel("Close notices")
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview { SettingsPanel(services: PhoneCaptionEngine.makePreviewServices()) }
