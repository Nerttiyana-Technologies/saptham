import SapthamCore
import SwiftUI

/// The iPhone lies flat between two people: the screen splits along a line
/// of live sound, and the half nearest the other person turns to face them,
/// so they can see what Saptham understood of them.
struct SharedFlatView: View {
    let captions: any CaptionControlling
    @AppStorage("captionTextSize") private var textSize = Monsoon.defaultCaptionSize

    private var feed: CaptionFeed { captions.feed }

    var body: some View {
        VStack(spacing: 0) {
            half
                .rotationEffect(.degrees(180))
                .accessibilityHidden(true)   // the same words as below, for the other person
            SoundEdge(level: feed.level, isListening: feed.state == .listening)
                .padding(.horizontal, 20)
            half
                .monsoonBand()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Live captions, shared")
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var half: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            if let line = feed.lines.last {
                ToneText(text: line.text, tone: line.tone, size: textSize * 0.95, weight: .bold)
            }
            if !feed.partial.isEmpty {
                Text(feed.partial)
                    .font(.system(size: textSize * 0.72, weight: .medium))
                    .foregroundStyle(Monsoon.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Picked up after lying face down: what Saptham heard meanwhile, as marks
/// on a line of time. The newest is lit in the band. Any touch goes on.
struct MissedView: View {
    let alerts: [SoundAlert]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            GeometryReader { proxy in
                let marks = alerts.sorted { $0.time < $1.time }
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Monsoon.ink3).frame(height: 1).offset(y: 52)
                        .accessibilityHidden(true)
                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, alert in
                        VStack(spacing: 10) {
                            Image(systemName: alert.kind.systemImage)
                                .font(.system(size: 28))
                                .foregroundStyle(Monsoon.accent)
                                .monsoonGlow(radius: 6)
                            Rectangle().fill(Monsoon.accent).frame(width: 2, height: 22).monsoonGlow(radius: 5)
                            Text(alert.time.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 16, weight: .heavy))
                        }
                        .position(x: x(for: index, of: marks.count, width: proxy.size.width), y: 52)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(alert.kind.title), \(alert.time.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .frame(height: 120)
            .padding(.horizontal, 20)

            if let newest = alerts.max(by: { $0.time < $1.time }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(newest.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Monsoon.accent)
                    Text(newest.kind.title)
                        .font(.system(size: 30, weight: .bold))
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .monsoonBand()
                .padding(.top, 50)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDone)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("While the iPhone was face down")
        .accessibilityAction(named: "Done", onDone)
    }

    private func x(for index: Int, of count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return 30 + (width - 60) * CGFloat(index) / CGFloat(count - 1)
    }
}
