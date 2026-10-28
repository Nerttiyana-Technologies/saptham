import SapthamCore
import SwiftUI

/// Live captions as a reading band, drawn in light, line and letter: no
/// buttons with shapes. The newest sentence sits large in the band; each
/// sentence that settles rises onto a thread of light above it. When
/// captions are off, the band folds into a single horizon line.
///
/// Gestures, each with a visible glyph and a VoiceOver action as well:
/// pull the horizon down to start · push the band up to stop · tap த or A
/// for language · tap or pull down the thread for earlier · the tuner
/// strokes for settings · hold the band to keep it still · pinch to resize.
struct LiveBandView: View {
    let captions: any CaptionControlling
    /// Which side voices come from (experimental, off unless chosen).
    var direction: SoundDirection? = nil
    let onEarlier: () -> Void
    let onSettings: () -> Void

    @AppStorage("captionTextSize") private var textSize = Monsoon.defaultCaptionSize
    /// Whether the user has stopped captions by pushing the band yet; until
    /// then a streak of light shows the push.
    @AppStorage("learnedPushToStop") private var learnedPushToStop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var lineSpace
    @State private var frozen: (lines: [CaptionLine], partial: String)?
    @State private var pinchStartSize: Double?
    @State private var drag: CGFloat = 0

    private var feed: CaptionFeed { captions.feed }
    private var isRunning: Bool { captions.activeSourceID != nil }
    private var shownLines: [CaptionLine] { frozen?.lines ?? feed.lines }
    private var shownPartial: String { frozen?.partial ?? feed.partial }
    private var bandLine: CaptionLine? { shownLines.last }
    /// Older sentences on the thread; oldest first.
    private var threadLines: [CaptionLine] { Array(shownLines.dropLast().suffix(4)) }

    var body: some View {
        ZStack {
            if isRunning || !shownLines.isEmpty {
                live
                    .transition(.opacity)
            } else {
                HorizonView(languageID: captions.activeLanguageID, onStart: start, onSettings: onSettings)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.86), value: bandLine?.id)
        .animation(.easeInOut(duration: 0.35), value: isRunning)
        .simultaneousGesture(pinch)
    }

    // MARK: Live

    private var live: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                thread
                    .frame(height: proxy.size.height * 0.36, alignment: .bottom)
                band
                    .offset(y: min(0, drag))
                if !learnedPushToStop && isRunning {
                    PushStreak().padding(.top, 26)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Earlier sentences as beads on a thread of light rising from the band.
    private var thread: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, Monsoon.accent], startPoint: .top, endPoint: .bottom)
                .frame(width: 1)
                .padding(.leading, 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(threadLines.enumerated()), id: \.element.id) { index, line in
                    let depth = threadLines.count - 1 - index
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Rectangle().fill(Monsoon.accent).frame(width: 7, height: 7)
                            .rotationEffect(.degrees(45))
                            .opacity(0.8)
                            .accessibilityHidden(true)
                        ToneText(text: line.text, tone: line.tone,
                                 size: max(16, textSize * (0.7 - Double(depth) * 0.06)),
                                 colour: depth < 2 ? Monsoon.ink2 : Monsoon.ink3)
                            .blur(radius: reduceMotion ? 0 : Double(depth) * 0.4)
                    }
                    .matchedGeometryEffect(id: line.id, in: lineSpace)
                    .transition(.opacity)
                }
            }
            .padding(.leading, 27)
            .padding(.trailing, 28)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onEarlier)
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 80 { onEarlier() }
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Earlier captions")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens earlier conversations")
    }

    private var band: some View {
        HStack(alignment: .center, spacing: 0) {
            LanguageLetters(captions: captions)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 14) {
                bandBody
            }
            .padding(.vertical, 34)
            .padding(.trailing, 26)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        }
        .overlay(alignment: .top) {
            HStack(alignment: .bottom, spacing: 8) {
                SoundEdge(level: feed.level, isListening: feed.state == .listening)
                Button(action: onSettings) { TunerGlyph() }
                    .buttonStyle(.glyph)
                    .accessibilityLabel("Settings")
            }
            .padding(.leading, 64)
            .padding(.trailing, 10)
            .offset(y: -22)
        }
        .monsoonBand()
        .overlay { DirectionGlow(balance: direction?.balance) }
        .contentShape(Rectangle())
        .gesture(pushToStop)
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            frozen = pressing ? (feed.lines, feed.partial) : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Stop captions") { stop() }
        .accessibilityAction(named: frozen == nil ? "Hold captions still" : "Let captions move") {
            frozen = frozen == nil ? (feed.lines, feed.partial) : nil
        }
    }

    @ViewBuilder
    private var bandBody: some View {
        switch feed.state {
        case .preparing:
            ProgressView().tint(Monsoon.accent).accessibilityLabel("Getting captions ready")
        case .failed(let message):
            Text(message)
                .font(.system(size: textSize * 0.6, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        default:
            if feed.isAudioStalled {
                Label("No sound from the microphone — restarting", systemImage: "mic.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Monsoon.violet)
            }
            if feed.soundScene.isMusical {
                Image(systemName: feed.soundScene == .singing ? "music.mic" : "music.note")
                    .font(.system(size: textSize * 0.9))
                    .foregroundStyle(Monsoon.accent)
                    .monsoonGlow()
                    .accessibilityLabel(feed.soundScene == .singing ? "Singing" : "Music")
            }
            if let line = bandLine {
                ToneText(text: line.text, tone: line.tone, size: textSize, colour: Monsoon.ink, weight: .bold)
                    .matchedGeometryEffect(id: line.id, in: lineSpace)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !shownPartial.isEmpty {
                (Text(shownPartial) + Text(" ▍").foregroundStyle(Monsoon.accent))
                    .font(.system(size: textSize * 0.8, weight: .medium))
                    .foregroundStyle(Monsoon.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
    }

    // MARK: Gestures

    private var pushToStop: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in drag = value.translation.height }
            .onEnded { value in
                if value.translation.height < -90 { stop() }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { drag = 0 }
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartSize ?? textSize
                pinchStartSize = start
                textSize = min(max(start * value.magnification, Monsoon.captionSizes.lowerBound), Monsoon.captionSizes.upperBound)
            }
            .onEnded { _ in pinchStartSize = nil }
    }

    private func start() {
        guard let source = captions.sources.first else { return }
        captions.clear()
        captions.start(source.id)
    }

    private func stop() {
        learnedPushToStop = true
        captions.stop()
        captions.clear()
    }
}

// MARK: - Pieces

/// Captions off: one glowing horizon line. Pull it down, or tap the streak
/// beneath it, and the band opens.
private struct HorizonView: View {
    let languageID: String
    let onStart: () -> Void
    /// The band's tuner glyph, so Settings opens before the first caption.
    let onSettings: () -> Void
    @State private var pulled: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Monsoon.accent)
                    .frame(height: 2)
                    .monsoonGlow(radius: breathe ? 18 : 10)
                    .padding(.leading, 60)
                    .padding(.trailing, 20)
                Text(languageID == CaptionRecognisers.LanguageID.english ? "A" : "த")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Monsoon.ink3)
                    .padding(.leading, 22)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onSettings) { TunerGlyph() }
                    .buttonStyle(.glyph)
                    .accessibilityLabel("Settings")
                    .padding(.trailing, 10)
                    .offset(y: -48)
            }
            .offset(y: pulled)
            Button(action: onStart) {
                StreakArrow(length: 44, direction: .down, colour: Monsoon.accent)
                    .opacity(0.75)
            }
            .buttonStyle(.glyph)
            .padding(.top, 10 + pulled)
            .accessibilityLabel("Start captions")
            Spacer()
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 10)
            .onChanged { value in pulled = max(0, min(value.translation.height, 140)) }
            .onEnded { value in
                if value.translation.height > 90 { onStart() }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { pulled = 0 }
            })
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captions are off")
    }
}

/// த and A on the band's edge. Tap one to caption in that language alone;
/// tap it again to go back to both. Lit = glow and a bar of light beneath.
private struct LanguageLetters: View {
    let captions: any CaptionControlling
    private typealias ID = CaptionRecognisers.LanguageID

    var body: some View {
        let active = captions.activeLanguageID
        let tamilLit = active == ID.tamil || active == ID.tamilAndEnglish
        let englishLit = active == ID.english || active == ID.tamilAndEnglish
        VStack(spacing: 2) {
            letter("த", lit: tamilLit, solo: ID.tamil, label: "Tamil")
            Rectangle().fill(Monsoon.dim).frame(width: 1, height: 12).accessibilityHidden(true)
            letter("A", lit: englishLit, solo: ID.english, label: "English")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Caption language")
    }

    private func letter(_ glyph: String, lit: Bool, solo: String, label: String) -> some View {
        Button {
            captions.setLanguage(captions.activeLanguageID == solo ? ID.tamilAndEnglish : solo)
        } label: {
            VStack(spacing: 3) {
                Text(glyph)
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(lit ? Monsoon.accent : Monsoon.ink3)
                    .monsoonGlow(lit ? Monsoon.accent : .clear, radius: 8)
                LitBar(isLit: lit, width: 20)
            }
        }
        .buttonStyle(.glyph)
        .sensoryFeedback(.selection, trigger: lit)
        .accessibilityLabel(label)
        .accessibilityValue(lit ? "On" : "Off")
    }
}

/// Experimental: the band's edge on the side a voice comes from glows.
private struct DirectionGlow: View {
    let balance: Double?

    var body: some View {
        HStack(spacing: 0) {
            edge(strength: max(0, -(balance ?? 0)))
            Spacer()
            edge(strength: max(0, balance ?? 0))
        }
        .animation(.easeOut(duration: 0.3), value: balance)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edge(strength: Double) -> some View {
        Rectangle()
            .fill(Monsoon.accent)
            .frame(width: 5)
            .opacity(strength)
            .monsoonGlow(radius: 14)
    }
}

/// Three strokes of light: settings.
private struct TunerGlyph: View {
    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Rectangle().frame(width: 22, height: 2.4)
            Rectangle().frame(width: 14, height: 2.4)
            Rectangle().frame(width: 6, height: 2.4)
        }
        .foregroundStyle(Monsoon.accent)
        .monsoonGlow(radius: 5)
    }
}

/// A long thin arrow of light: the app's only drawn "button" shape.
struct StreakArrow: View {
    enum Direction { case up, down, left, right }
    var length: CGFloat
    var direction: Direction
    var colour: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            switch direction {
            case .down, .up:
                path.move(to: CGPoint(x: mid.x, y: 2))
                path.addLine(to: CGPoint(x: mid.x, y: size.height - 2))
                let tip = direction == .down ? size.height - 2 : 2
                let back = direction == .down ? tip - 9 : tip + 9
                path.move(to: CGPoint(x: mid.x - 7, y: back)); path.addLine(to: CGPoint(x: mid.x, y: tip))
                path.addLine(to: CGPoint(x: mid.x + 7, y: back))
            case .left, .right:
                path.move(to: CGPoint(x: 2, y: mid.y))
                path.addLine(to: CGPoint(x: size.width - 2, y: mid.y))
                let tip = direction == .right ? size.width - 2 : 2
                let back = direction == .right ? tip - 9 : tip + 9
                path.move(to: CGPoint(x: back, y: mid.y - 7)); path.addLine(to: CGPoint(x: tip, y: mid.y))
                path.addLine(to: CGPoint(x: back, y: mid.y + 7))
            }
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: direction == .left || direction == .right ? length : 20,
               height: direction == .up || direction == .down ? length : 20)
        .monsoonGlow(colour, radius: 6)
        .accessibilityHidden(true)
    }
}

/// Shown until the user has once pushed the band up: a streak rising from
/// below it, breathing, then never again.
private struct PushStreak: View {
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StreakArrow(length: 90, direction: .up, colour: Monsoon.accent)
            .opacity(lifted ? 0.25 : 0.7)
            .offset(y: lifted ? -14 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { lifted = true }
            }
            .frame(maxWidth: .infinity)
    }
}

/// A caption set the way it was said: a shout is heavy and shakes with an
/// echo, raised speech is heavier, a whisper is light and spaced, and a
/// question's last words rise.
struct ToneText: View {
    let text: String
    let tone: SpeechTone
    let size: Double
    var colour: Color = Monsoon.ink
    var weight: Font.Weight = .semibold

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shaking = false

    var body: some View {
        styled
            .font(.system(size: size * scale, weight: toneWeight))
            .italic(tone == .whisper)
            .tracking(tone == .whisper ? 1.2 : (tone == .shout ? -0.3 : 0))
            .foregroundStyle(tone == .whisper ? Monsoon.ink2 : colour)
            .lineSpacing(size * 0.12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                if tone == .shout {
                    styled
                        .font(.system(size: size * scale, weight: toneWeight))
                        .foregroundStyle(Monsoon.violet.opacity(0.55))
                        .offset(x: -3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: tone == .whisper ? Monsoon.ink.opacity(0.35) : .clear, radius: 8)
            .offset(x: tone == .shout && shaking ? 1.5 : 0)
            .onAppear {
                guard tone == .shout, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.06).repeatCount(9, autoreverses: true)) { shaking = true }
            }
            .accessibilityLabel(accessibilityText)
    }

    private var scale: Double {
        switch tone {
        case .shout: 1.16
        case .raised: 1.06
        case .whisper: 0.86
        case .normal: 1
        }
    }

    private var toneWeight: Font.Weight {
        switch tone {
        case .shout: .black
        case .raised: .heavy
        case .whisper: .light
        case .normal: weight
        }
    }

    /// A question (ends in "?") lifts its last three words, a step each.
    private var styled: Text {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("?") else { return Text(text) }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = Text("")
        for (index, word) in words.enumerated() {
            let lift = max(0, index - (words.count - 3)) * Int(size * 0.12)
            result = result + Text(index == 0 ? word : " " + word).baselineOffset(CGFloat(lift))
        }
        return result
    }

    private var accessibilityText: String {
        switch tone {
        case .shout: "Shouted: \(text)"
        case .raised: "Loudly: \(text)"
        case .whisper: "Whispered: \(text)"
        case .normal: text
        }
    }
}

/// The band's top edge as a sound meter: recent loudness as a row of bars
/// that light up while sound arrives.
struct SoundEdge: View {
    let level: Float
    let isListening: Bool
    @State private var history = Array(repeating: Float(0), count: 48)

    var body: some View {
        Canvas { context, size in
            let gap = size.width / CGFloat(history.count)
            for (index, value) in history.enumerated() {
                let height = max(2, CGFloat(min(value * 2.5, 1)) * size.height)
                let rect = CGRect(x: CGFloat(index) * gap, y: size.height - height, width: 3, height: height)
                context.fill(Path(rect), with: .color(value > 0.02 ? Monsoon.accent : Monsoon.dim))
            }
        }
        .frame(height: 22)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(isListening ? newLevel : 0)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Live band") {
    let services = PhoneCaptionEngine.makePreviewServices()
    ZStack {
        MonsoonBackdrop()
        LiveBandView(captions: services.captions, onEarlier: {}, onSettings: {})
    }
    .preferredColorScheme(.dark)
}
