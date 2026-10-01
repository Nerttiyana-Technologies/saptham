import SapthamCore
import SwiftUI

/// An alert takes over the screen: its edges pulse in the accent colour
/// (seen out of the corner of the eye) and the reading band becomes the
/// alert. For a name alert the band shows the line that was heard, with
/// the name lit.
struct AlertBandView: View {
    let alert: SoundAlert
    /// The newest caption, for a name alert.
    let heardLine: String?
    let onDismiss: () -> Void
    let onShow: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var appeared = false

    private var isNameAlert: Bool { alert.kind.id == NameAlerts.kind.id }

    var body: some View {
        ZStack {
            Monsoon.ground.opacity(0.82).ignoresSafeArea()
            // The glowing edge.
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .strokeBorder(Monsoon.accent, lineWidth: pulse ? 7 : 4)
                .shadow(color: Monsoon.accent.opacity(pulse ? 0.9 : 0.4), radius: pulse ? 40 : 18)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer()
                band
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                    .opacity(appeared ? 1 : 0)
                Spacer()
                // No drawn buttons: a streak left wipes the alert away, a
                // streak down goes to the captions. Both are real buttons,
                // and swiping the screen the same way does the same.
                HStack(alignment: .bottom) {
                    Button(action: onDismiss) {
                        StreakArrow(length: 130, direction: .left, colour: Monsoon.ink2)
                    }
                    .buttonStyle(.glyph)
                    .accessibilityLabel("Dismiss")
                    Spacer()
                    Button(action: onShow) {
                        StreakArrow(length: 130, direction: .down, colour: Monsoon.accent)
                    }
                    .buttonStyle(.glyph)
                    .accessibilityLabel(isNameAlert ? "Show the captions" : "Caption now")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            if value.translation.width < -100 { onDismiss() } else if value.translation.height > 100 { onShow() }
        })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var band: some View {
        VStack(spacing: 18) {
            Image(systemName: alert.kind.systemImage)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Monsoon.accent)
                .symbolEffect(.bounce, options: .repeat(3), value: appeared)
            Text(isNameAlert ? spokenName : alert.kind.title)
                .font(.system(size: isNameAlert ? 60 : 44, weight: .heavy))
                .foregroundStyle(isNameAlert ? Monsoon.accent : Monsoon.ink)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
            if isNameAlert, let heardLine {
                Text(highlighted(heardLine))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Monsoon.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Just now · \(alert.time.formatted(date: .omitted, time: .shortened))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Monsoon.ink2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .monsoonBand()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNameAlert ? "Someone said your name. \(heardLine ?? "")" : "\(alert.kind.title), just now")
    }

    /// The first of the user's names found in the heard line, as typed in Settings.
    private var spokenName: String {
        guard let heardLine else { return "Your name" }
        return NameSpotter(list: SapthamSettings.alertNamesValue).firstName(in: heardLine) ?? "Your name"
    }

    /// The heard line with each saved name lit in the accent colour.
    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        let names = SapthamSettings.alertNamesValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for name in names {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].foregroundColor = Monsoon.accent
                text[range].font = .system(size: 24, weight: .heavy)
                searchStart = range.upperBound
            }
        }
        return text
    }
}

#Preview("Name alert") {
    ZStack {
        MonsoonBackdrop()
        AlertBandView(alert: SoundAlert(kind: NameAlerts.kind, confidence: 1),
                      heardLine: "வணக்கம் Suresh, எப்படி இருக்கீங்க?", onDismiss: {}, onShow: {})
    }
}
