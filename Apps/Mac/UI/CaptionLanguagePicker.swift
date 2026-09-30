import SapthamCore
import SwiftUI

/// Switches the caption language. Shows each language in its own script, so
/// Tamil reads as "தமிழ்".
struct CaptionLanguagePicker: View {
    enum Style { case segmented, compact }

    let controller: any CaptionControlling
    var style: Style = .segmented

    private var selection: Binding<CaptionLanguageOption.ID> {
        Binding(get: { controller.activeLanguageID }, set: { controller.setLanguage($0) })
    }

    private var active: CaptionLanguageOption? {
        controller.languages.first { $0.id == controller.activeLanguageID }
    }

    var body: some View {
        switch style {
        case .segmented:
            Picker("Caption language", selection: selection) {
                ForEach(controller.languages) { language in
                    Text(language.nativeTitle)
                        .accessibilityLabel(language.title)
                        .tag(language.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("The language people are speaking")
            .accessibilityLabel("Caption language")
        case .compact:
            Menu {
                Picker("Caption language", selection: selection) {
                    ForEach(controller.languages) { language in
                        Text(language.nativeTitle == language.title ? language.title : "\(language.nativeTitle) — \(language.title)")
                            .tag(language.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(active?.nativeTitle ?? "")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.glass)
            .help("Caption language")
            .accessibilityLabel("Caption language")
            .accessibilityValue(active?.title ?? "")
        }
    }
}
