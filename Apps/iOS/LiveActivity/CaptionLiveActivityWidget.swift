import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SapthamLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        CaptionLiveActivity()
    }
}

struct CaptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptionActivityAttributes.self) { context in
            CaptionLockScreen(state: context.state)
                .activityBackgroundTint(Monsoon.ground)
                .widgetURL(URL(string: "saptham://live"))
                .accessibilityLabel(activityAccessibilityLabel(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LanguageMark(languageID: context.state.languageID)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.alertTitle == nil {
                        SoundMeter(level: context.state.level, count: 5, height: 20)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let title = context.state.alertTitle {
                        HStack(spacing: 8) {
                            Image(systemName: context.state.alertSymbol ?? "exclamationmark.triangle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Monsoon.accent)
                                .monsoonGlow()
                            Text(title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Monsoon.ink)
                                .lineLimit(2)
                                .truncationMode(.head)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                    } else {
                        CaptionText(state: context.state, lineLimit: 2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Live captions: \(context.state.line)")
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.alertTitle == nil ? "waveform" : (context.state.alertSymbol ?? "exclamationmark.triangle"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Monsoon.accent)
                    .monsoonGlow()
                    .accessibilityHidden(true)
            } compactTrailing: {
                if context.state.alertTitle == nil {
                    Text(compactCaption(from: context.state.partial.isEmpty ? context.state.line : context.state.partial))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Monsoon.ink)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 66)
                        .accessibilityLabel("Live captions: \(context.state.line)")
                } else {
                    Image(systemName: context.state.alertSymbol ?? "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Monsoon.accent)
                        .monsoonGlow()
                        .accessibilityLabel(context.state.alertTitle ?? "Alert")
                }
            } minimal: {
                Image(systemName: context.state.alertTitle == nil ? "waveform" : (context.state.alertSymbol ?? "exclamationmark.triangle"))
                    .foregroundStyle(Monsoon.accent)
                    .monsoonGlow()
                    .accessibilityLabel(activityAccessibilityLabel(context.state))
            }
            .keylineTint(Monsoon.accent)
            .widgetURL(URL(string: "saptham://live"))
        }
    }
}

private struct CaptionLockScreen: View {
    let state: CaptionActivityAttributes.ContentState

    var body: some View {
        Group {
            if let title = state.alertTitle {
                VStack(alignment: .leading, spacing: 12) {
                    SoundEdge(level: state.level, lit: true)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: state.alertSymbol ?? "exclamationmark.triangle")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Monsoon.accent)
                            .monsoonGlow()
                        Text(title)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Monsoon.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center) {
                        SoundEdge(level: state.level)
                        Spacer(minLength: 12)
                        LanguageMark(languageID: state.languageID)
                    }
                    CaptionText(state: state, lineLimit: 3)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live captions: \(state.line)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct CaptionText: View {
    let state: CaptionActivityAttributes.ContentState
    let lineLimit: Int

    private var lineFont: Font {
        switch state.tone {
        case "shout": .system(size: 22, weight: .heavy)
        case "whisper": .system(size: 20, weight: .light).italic()
        default: .system(size: 20, weight: .bold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.line)
                .font(lineFont)
                .foregroundStyle(Monsoon.ink)
                .lineLimit(lineLimit)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
            if !state.partial.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("▍")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Monsoon.accent)
                        .monsoonGlow()
                    Text(state.partial)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Monsoon.ink2)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LanguageMark: View {
    let languageID: String

    private var mark: String {
        switch languageID {
        case "ta+en": "த + A"
        case "ta": "த"
        default: "A"
        }
    }

    var body: some View {
        Text(mark)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Monsoon.label)
            .fixedSize()
            .accessibilityLabel(mark)
    }
}

private struct SoundEdge: View {
    let level: Double
    var lit = false

    var body: some View {
        SoundMeter(level: level, count: 24, height: 18, lit: lit)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityHidden(true)
    }
}

private struct SoundMeter: View {
    let level: Double
    let count: Int
    let height: CGFloat
    var lit = false

    var body: some View {
        HStack(alignment: .center, spacing: count > 10 ? 2 : 3) {
            ForEach(0..<count, id: \.self) { index in
                let wave = 0.28 + 0.72 * abs(sin(Double(index) * 0.67))
                let scaledLevel = min(max(level, 0.08), 1)
                Rectangle()
                    .fill(Monsoon.accent)
                    .frame(width: count > 10 ? 2 : 3,
                           height: max(2, height * CGFloat(scaledLevel * wave)))
                    .monsoonGlow(radius: lit ? 5 : 3)
            }
        }
        .frame(height: height, alignment: .center)
    }
}

private func compactCaption(from text: String) -> String {
    let words = text.split(whereSeparator: \.isWhitespace)
    var result = ""
    for word in words.reversed().prefix(2).reversed() {
        let candidate = result.isEmpty ? String(word) : "\(result) \(word)"
        if candidate.count > 12 { break }
        result = candidate
    }
    return result.isEmpty ? String(text.suffix(12)) : result
}

private func activityAccessibilityLabel(_ state: CaptionActivityAttributes.ContentState) -> String {
    if let title = state.alertTitle { return title }
    return "Live captions: \(state.line)"
}

#Preview(as: .content, using: CaptionActivityAttributes(startedAt: .now)) {
    CaptionLiveActivity()
} contentStates: {
    CaptionActivityAttributes.ContentState(
        line: "சரி, நாளைக்கு காலை பதினொரு மணிக்கு டாக்டர் அப்பாயின்ட்மென்ட் இருக்கு.",
        partial: "I will be there on time",
        tone: "normal",
        languageID: "ta+en",
        alertTitle: nil,
        alertSymbol: nil,
        level: 0.62
    )
    CaptionActivityAttributes.ContentState(
        line: "",
        partial: "",
        tone: "normal",
        languageID: "ta",
        alertTitle: "Doorbell",
        alertSymbol: "bell",
        level: 0.9
    )
}
