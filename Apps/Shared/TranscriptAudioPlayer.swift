import AVFoundation
import Foundation
import SapthamCore

/// Plays one transcript span and stops at its end without exposing audio state to the view.
@MainActor
final class TranscriptAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(_ span: AudioSpan, from url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.currentTime = max(0, span.start)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { self.player = nil; return }
        stopTask = Task { [weak self] in
            let duration = max(0, span.end - span.start)
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTask?.cancel()
        stopTask = nil
        self.player = nil
    }
}
