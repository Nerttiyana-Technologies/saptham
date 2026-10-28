import AppKit
import AVKit
import SapthamSigns
import SwiftUI

/// "Show sign" for words picked in transcript review (ADR 0003 §2.9, P10-S14):
/// a recorded signer's dictionary sign, looping and silent, with its gloss,
/// sense, sign language and signer credit. A word that isn't in the pack gets
/// a plain "no sign" line, never a near match.
struct SignSheet: View {
    let word: String
    let dictionary: SignDictionary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil while looking up.
    @State private var matches: [SignMatch]?
    @State private var selected = 0
    @State private var slow = false
    @State private var replays = 0
    /// With Reduce Motion on, the poster shows until the user starts the clip.
    @State private var started = false
    @State private var showsCredits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign for \u{201C}\(word)\u{201D}").font(.headline)
            if let pack = dictionary.activePack, let matches {
                if matches.isEmpty {
                    Text("No sign for \u{201C}\(word)\u{201D} in \(pack.manifest.signLanguageName) yet.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    sign(matches[min(selected, matches.count - 1)], all: matches, in: pack)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                if dictionary.activePack != nil {
                    Button { showsCredits = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("Credits for this sign pack")
                        .accessibilityLabel("Credits for this sign pack")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task(id: word) {
            selected = 0
            matches = await dictionary.signs(for: word)
        }
        .sheet(isPresented: $showsCredits) {
            if let pack = dictionary.activePack { SignPackCreditsSheet(pack: pack) }
        }
    }

    @ViewBuilder
    private func sign(_ match: SignMatch, all matches: [SignMatch], in pack: SignPack) -> some View {
        if matches.count > 1 {
            Picker("Sense", selection: $selected) {
                ForEach(matches.indices, id: \.self) { index in
                    Text(matches[index].note ?? matches[index].entry.idGloss).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sense")
        }
        let playing = !reduceMotion || started
        SignClipView(clip: pack.url(for: match.entry.media.file), rate: slow ? 0.5 : 1,
                     playing: playing, replays: replays)
            .id(match.entry.media.file)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 300)
            .overlay {
                if !playing { poster(match.entry.media.poster.map { pack.url(for: $0) }) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sign for \(word): \(match.entry.idGloss)\(match.note.map { ", \($0)" } ?? "")")
        VStack(alignment: .leading, spacing: 3) {
            Text([match.entry.idGloss, match.note].compactMap { $0 }.joined(separator: " · "))
                .font(.body.weight(.semibold))
            Text(pack.manifest.signLanguageName).foregroundStyle(.secondary)
            Text(match.entry.signerCredit).foregroundStyle(.secondary)
            Text("A dictionary sign for this word only.").font(.caption).foregroundStyle(.tertiary)
        }
        HStack(spacing: 14) {
            Button { slow.toggle() } label: {
                Image(systemName: "tortoise").foregroundStyle(slow ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(slow ? "Normal speed" : "Half speed")
            .accessibilityLabel("Half speed").accessibilityValue(slow ? "On" : "Off")
            Button { started = true; replays += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Play the sign again")
                .accessibilityLabel("Play the sign again")
        }
    }

    private func poster(_ url: URL?) -> some View {
        ZStack {
            Color.black
            if let image = url.flatMap({ NSImage(contentsOf: $0) }) {
                Image(nsImage: image).resizable().scaledToFit()
            }
            Button { started = true } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Play the sign")
            .accessibilityLabel("Play the sign")
        }
    }
}

/// A pack's own credits.txt, as the pack ships it (ADR 0003 §2.8).
struct SignPackCreditsSheet: View {
    let pack: SignPack
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = (try? String(contentsOf: pack.url(for: "credits.txt"), encoding: .utf8)) ?? "This pack has no credits file."
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 480, height: 360)
    }
}

/// A silent, looping clip with no controls; the sheet's own buttons drive it.
private struct SignClipView: NSViewRepresentable {
    let clip: URL
    let rate: Float
    let playing: Bool
    /// Bumped to play the sign again from the start.
    let replays: Int

    func makeCoordinator() -> Coordinator { Coordinator(clip: clip) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = context.coordinator.clip.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.clip.rate = rate
        if coordinator.replays != replays {
            coordinator.replays = replays
            coordinator.clip.restart()
        } else if playing, !coordinator.clip.isPlaying {
            coordinator.clip.play()
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.clip.pause()
    }

    @MainActor
    final class Coordinator {
        let clip: SignClipPlayer
        var replays = 0

        init(clip: URL) {
            self.clip = SignClipPlayer(clip: clip)
        }
    }
}
