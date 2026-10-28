import AVFoundation

/// Plays one sign clip on a loop, always muted (ADR 0003 §2.9: signs are
/// silent). Shared by the iPhone sign sheet and the Mac sign view; each draws
/// it with its own player layer.
@MainActor
final class SignClipPlayer {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper
    /// The speed the user chose: 1, or 0.5 for half speed. Read whenever
    /// playback starts or restarts.
    var rate: Float = 1 {
        didSet { if isPlaying { play() } }
    }

    init(clip: URL) {
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: clip))
    }

    var isPlaying: Bool { player.rate != 0 }

    func play() {
        player.defaultRate = rate
        player.rate = rate
    }

    func restart() {
        player.seek(to: .zero)
        play()
    }

    func pause() {
        player.pause()
    }
}
