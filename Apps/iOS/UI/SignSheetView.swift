import AVFoundation
import SapthamSigns
import SwiftUI
import UIKit

/// "Show sign" for a word in a saved transcript (ADR 0003 §2.9): a recorded
/// signer's dictionary sign, looping and silent, with its gloss, sense, sign
/// language and signer credit. A word that isn't in the pack gets a plain "no
/// sign" line, never a near match.
struct SignSheetView: View {
    let word: String
    let dictionary: SignDictionary
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil while looking up.
    @State private var matches: [SignMatch]?
    @State private var selected = 0
    @State private var slow = false
    @State private var replays = 0
    @State private var showsCredits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(word).font(.title3.weight(.semibold)).foregroundStyle(Monsoon.ink)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(Monsoon.ink3) }
                    .buttonStyle(.glyph).accessibilityLabel("Close sign")
            }
            if let pack = dictionary.activePack, let matches {
                if matches.isEmpty {
                    Text("No sign for \u{201C}\(word)\u{201D} in \(pack.manifest.signLanguageName) yet.")
                        .font(.body).foregroundStyle(Monsoon.ink2).fixedSize(horizontal: false, vertical: true)
                } else {
                    sign(matches[min(selected, matches.count - 1)], all: matches, in: pack)
                }
            } else {
                ProgressView().tint(Monsoon.accent).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monsoonBand().padding(.top, 10)
        .task(id: word) {
            selected = 0
            matches = await dictionary.signs(for: word)
        }
        .sheet(isPresented: $showsCredits) {
            if let pack = dictionary.activePack { SignPackCreditsView(pack: pack) }
        }
    }

    @ViewBuilder
    private func sign(_ match: SignMatch, all matches: [SignMatch], in pack: SignPack) -> some View {
        if matches.count > 1 {
            HStack(spacing: 8) {
                ForEach(matches.indices, id: \.self) { index in
                    Button { selected = index } label: {
                        Text(matches[index].note ?? matches[index].entry.idGloss)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(index == selected ? Monsoon.accentInk : Monsoon.ink2)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(Capsule().fill(index == selected ? Monsoon.accent : Monsoon.accentSoft))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sense: \(matches[index].note ?? matches[index].entry.idGloss)")
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                }
            }
        }
        SignClipView(clip: pack.url(for: match.entry.media.file),
                     poster: match.entry.media.poster.map { pack.url(for: $0) },
                     rate: slow ? 0.5 : 1, autoplay: !reduceMotion, replays: replays)
            .id(match.entry.media.file)
            .aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement()
            .accessibilityLabel("Sign for \(word): \(match.entry.idGloss)\(match.note.map { ", \($0)" } ?? "")")
        VStack(alignment: .leading, spacing: 3) {
            Text([match.entry.idGloss, match.note].compactMap { $0 }.joined(separator: " · "))
                .font(.headline).foregroundStyle(Monsoon.ink)
            Text(pack.manifest.signLanguageName).font(.subheadline).foregroundStyle(Monsoon.ink2)
            Text(match.entry.signerCredit).font(.subheadline).foregroundStyle(Monsoon.ink2)
            Text("Dictionary sign, not a translation.").font(.caption).foregroundStyle(Monsoon.ink3)
        }
        HStack {
            Button { slow.toggle() } label: {
                Image(systemName: "tortoise").foregroundStyle(slow ? Monsoon.accent : Monsoon.ink3)
            }
            .buttonStyle(.glyph).accessibilityLabel("Half speed").accessibilityValue(slow ? "On" : "Off")
            Spacer()
            Button { replays += 1 } label: { Image(systemName: "arrow.counterclockwise").foregroundStyle(Monsoon.ink3) }
                .buttonStyle(.glyph).accessibilityLabel("Play the sign again")
            Spacer()
            Button { showsCredits = true } label: { Image(systemName: "info.circle").foregroundStyle(Monsoon.ink3) }
                .buttonStyle(.glyph).accessibilityLabel("Credits for this sign pack")
        }
    }
}

/// A pack's own credits.txt, as the pack ships it (ADR 0003 §2.8).
private struct SignPackCreditsView: View {
    let pack: SignPack
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = (try? String(contentsOf: pack.url(for: "credits.txt"), encoding: .utf8)) ?? "This pack has no credits file."
        ZStack {
            MonsoonBackdrop()
            VStack(alignment: .trailing, spacing: 8) {
                ScrollView {
                    Text(text).font(.body).textSelection(.enabled).foregroundStyle(Monsoon.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                }
                LightRule()
                Button { dismiss() } label: { Image(systemName: "checkmark").foregroundStyle(Monsoon.accent) }
                    .buttonStyle(.glyph).accessibilityLabel("Close credits")
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

/// A silent, looping clip. With Reduce Motion on it shows the poster until
/// the user starts it, and it never plays sound.
private struct SignClipView: UIViewRepresentable {
    let clip: URL
    let poster: URL?
    let rate: Float
    let autoplay: Bool
    /// Bumped to play the sign again from the start.
    let replays: Int

    func makeCoordinator() -> Coordinator { Coordinator(clip: clip) }

    func makeUIView(context: Context) -> ClipUIView {
        let clip = context.coordinator.clip
        let view = ClipUIView()
        view.playerLayer.player = clip.player
        view.poster.image = poster.flatMap { UIImage(contentsOfFile: $0.path(percentEncoded: false)) }
        clip.rate = rate
        view.onPlay = { [weak clip, weak view] in
            view?.showsPoster = false
            clip?.play()
        }
        view.showsPoster = !autoplay
        if autoplay { clip.play() }
        return view
    }

    func updateUIView(_ view: ClipUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.clip.rate = rate
        if coordinator.replays != replays {
            coordinator.replays = replays
            view.showsPoster = false
            coordinator.clip.restart()
        }
    }

    static func dismantleUIView(_ view: ClipUIView, coordinator: Coordinator) {
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

    final class ClipUIView: UIView {
        let playerLayer = AVPlayerLayer()
        let poster = UIImageView()
        private let playButton = UIButton(type: .system)
        var onPlay: () -> Void = {}

        var showsPoster = false {
            didSet { poster.isHidden = !showsPoster; playButton.isHidden = !showsPoster }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            playerLayer.videoGravity = .resizeAspect
            layer.addSublayer(playerLayer)
            poster.contentMode = .scaleAspectFit
            playButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)), for: .normal)
            playButton.tintColor = .white
            playButton.accessibilityLabel = "Play the sign"
            playButton.addAction(UIAction { [weak self] _ in self?.onPlay() }, for: .primaryActionTriggered)
            for subview in [poster, playButton] as [UIView] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                addSubview(subview)
            }
            NSLayoutConstraint.activate([
                poster.leadingAnchor.constraint(equalTo: leadingAnchor), poster.trailingAnchor.constraint(equalTo: trailingAnchor),
                poster.topAnchor.constraint(equalTo: topAnchor), poster.bottomAnchor.constraint(equalTo: bottomAnchor),
                playButton.centerXAnchor.constraint(equalTo: centerXAnchor), playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }

        required init?(coder: NSCoder) { nil }
    }
}
