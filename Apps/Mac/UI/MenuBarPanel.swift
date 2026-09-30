import AppKit
import SapthamCore
import SwiftUI

struct MenuBarPanel: View {
    let controller: any CaptionControlling
    let captionWindow: CaptionWindowController
    @Binding var isCaptionWindowVisible: Bool
    @AppStorage("captionTextSize") private var textSize = 30.0
    @AppStorage("lastCaptionSourceID") private var lastSourceID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusSection

            VStack(alignment: .leading, spacing: 8) {
                Text("CAPTION SOURCE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                ForEach(controller.sources) { source in
                    sourceRow(source)
                }
            }

            Toggle(isOn: $isCaptionWindowVisible) {
                Label("Show caption window", systemImage: "rectangle.inset.filled")
            }
            .accessibilityLabel("Show caption window")
            .onChange(of: isCaptionWindowVisible) { _, visible in
                if visible {
                    captionWindow.show(controller: controller)
                } else {
                    captionWindow.hide()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Caption text size")
                    Spacer()
                    Text(sizeName)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Slider(value: $textSize, in: 22...46, step: 8)
                    .accessibilityLabel("Caption text size")
                    .accessibilityValue(sizeName)
                    .accessibilityHint("Small to very large")
            }

            HStack {
                Button {
                    controller.clear()
                } label: {
                    Label("Clear captions", systemImage: "eraser")
                }
                .accessibilityLabel("Clear captions")

                Spacer()

                Button {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(controller.activeSourceID == nil)
                .accessibilityLabel("Stop captioning")
            }

            Divider()

            Button("Quit Saptham") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .accessibilityLabel("Quit Saptham")
        }
        .padding(18)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(8)
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed = controller.feed.state {
                Spacer(minLength: 0)
                Button("Retry") {
                    let sourceID = controller.sources.first { $0.id == lastSourceID }?.id
                        ?? controller.activeSourceID
                        ?? controller.sources.first?.id
                    if let sourceID {
                        controller.start(sourceID)
                    }
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Retry captioning")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceRow(_ source: CaptionSourceOption) -> some View {
        let isActive = controller.activeSourceID == source.id
        return Button {
            lastSourceID = source.id
            controller.start(source.id)
            // Captions nobody can see are useless: starting a source always
            // brings the caption window up.
            isCaptionWindowVisible = true
            captionWindow.show(controller: controller)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.body.weight(.medium))
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.tint.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.title), \(source.detail)")
        .accessibilityValue(isActive ? "Selected" : "Not selected")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var statusTitle: String {
        switch controller.feed.state {
        case .failed(let message):
            message
        case .preparing:
            "Getting captions ready"
        case .listening:
            "Captioning \(activeSource?.title.lowercased() ?? "audio")"
        case .idle:
            "Not captioning"
        }
    }

    private var statusDetail: String {
        if case .failed = controller.feed.state { return "Choose Retry to try again." }
        guard controller.feed.state == .listening else { return "Choose a source to begin." }
        guard activeSource?.id == "calls" else { return "Listening for speech" }
        let recentSpeech = controller.feed.lastSpeechAt.map { Date().timeIntervalSince($0) < 15 } ?? false
        return recentSpeech ? "Call in progress" : "Waiting for a call"
    }

    private var activeSource: CaptionSourceOption? {
        controller.sources.first { $0.id == controller.activeSourceID }
    }

    private var statusSymbol: String {
        switch controller.feed.state {
        case .failed: "exclamationmark.triangle.fill"
        case .preparing: "ellipsis.circle.fill"
        case .listening: "captions.bubble.fill"
        case .idle: "captions.bubble"
        }
    }

    private var statusColor: Color {
        if case .failed = controller.feed.state { return .orange }
        return .accentColor
    }

    private var sizeName: String {
        switch textSize {
        case ..<26: "Small"
        case ..<34: "Large"
        case ..<42: "Larger"
        default: "Very large"
        }
    }
}
