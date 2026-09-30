import AppKit
import SapthamCore
import SwiftUI

struct CaptionWindowView: View {
    let controller: any CaptionControlling
    let onHide: () -> Void
    @AppStorage("captionTextSize") private var textSize = 30.0
    @AppStorage("captionWindowVisible") private var isVisible = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovered = false

    private var needsOpaqueSurface: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            surface

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ActivityIndicator(level: controller.feed.level, reduceMotion: reduceMotion)
                    Text(windowStatus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    controls
                }
                .padding(.bottom, 12)

                captionScrollView
            }
            .padding(22)
        }
        .frame(minWidth: 340, minHeight: 170)
        // The hidden title bar still reserves a safe area; captions use it.
        .ignoresSafeArea()
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var surface: some View {
        if needsOpaqueSurface {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                }
        } else {
            // The window itself is Liquid Glass (NSGlassEffectView in
            // CaptionWindowController); the frost keeps captions readable
            // over any background.
            GlassFrost()
        }
    }

    private var captionScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if controller.feed.lines.isEmpty && controller.feed.partial.isEmpty {
                        Text(emptyState)
                            .font(.system(size: textSize, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(Array(controller.feed.lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: textSize, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary.opacity(opacity(for: index)))
                                .lineSpacing(textSize * 0.16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }

                        Text(controller.feed.partial.isEmpty ? " " : controller.feed.partial)
                            .font(.system(size: textSize, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineSpacing(textSize * 0.16)
                            // Never truncate: the newest words are at the end. A minimum
                            // height keeps the layout steady as the sentence grows.
                            .frame(maxWidth: .infinity, minHeight: textSize * 1.4, alignment: .topLeading)
                            .id("current-caption-partial")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: controller.feed.lines.count) { _, _ in scrollToLatest(using: proxy) }
            .onChange(of: controller.feed.partial) { _, _ in scrollToLatest(using: proxy) }
            .onChange(of: controller.feed.state) { _, _ in scrollToLatest(using: proxy) }
        }
        .accessibilityLabel("Live captions")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .help("Stop captioning")
            .accessibilityLabel("Stop captioning")

            Button {
                controller.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear captions")
            .accessibilityLabel("Clear captions")

            Menu {
                sizeButton("Small", value: 22)
                sizeButton("Large", value: 30)
                sizeButton("Larger", value: 38)
                sizeButton("Very large", value: 46)
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("Caption text size")
            .accessibilityLabel("Caption text size")

            Button {
                isVisible = false
                onHide()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Hide caption window")
            .accessibilityLabel("Hide caption window")
        }
        .buttonStyle(.glass)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered)
    }

    private func sizeButton(_ title: String, value: Double) -> some View {
        Button(title) { textSize = value }
            .accessibilityLabel("Set caption text size to \(title.lowercased())")
            .accessibilityAddTraits(textSize == value ? .isSelected : [])
    }

    private var windowStatus: String {
        switch controller.feed.state {
        case .idle:
            "Not captioning"
        case .preparing:
            "Getting captions ready"
        case .listening:
            activeSource?.id == "calls" ? (isHearingSpeech ? "Call in progress" : "Waiting for a call") : "Listening"
        case .failed(let message):
            message
        }
    }

    private var emptyState: String {
        switch controller.feed.state {
        case .idle:
            "Not captioning"
        case .preparing:
            "Getting captions ready"
        case .listening:
            activeSource?.id == "calls"
                ? "Waiting for a call"
                : "Listening — captions will appear when someone speaks"
        case .failed:
            "Captions stopped. Open the menu bar control to try again."
        }
    }

    private var activeSource: CaptionSourceOption? {
        controller.sources.first { $0.id == controller.activeSourceID }
    }

    /// Older lines recede a little, but never below readable contrast.
    private func opacity(for lineIndex: Int) -> Double {
        guard colorSchemeContrast != .increased else { return 1 }
        let age = controller.feed.lines.count - lineIndex - 1
        return max(0.6, 1 - Double(age) * 0.06)
    }

    private var isHearingSpeech: Bool {
        controller.feed.isReceivingAudio
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = reduceMotion ? nil : .easeOut(duration: 0.18)
        withTransaction(transaction) {
            proxy.scrollTo("current-caption-partial", anchor: .bottom)
        }
    }
}

private struct ActivityIndicator: View {
    let level: Float
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(level > 0.08 ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(width: 20, height: 18)
        .accessibilityLabel(level > 0.08 ? "Audio arriving" : "No recent audio")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: Float = [0.35, 0.65, 0.9, 0.5][index]
        guard level > 0.08 else { return 4 }
        return CGFloat(reduceMotion ? 5 + base * 7 : 4 + min(level, 1) * base * 13)
    }
}

#Preview("Captions") {
    CaptionWindowView(controller: PreviewCaptionController(), onHide: {})
        .frame(width: 680, height: 300)
}
