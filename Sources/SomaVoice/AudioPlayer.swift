import AVFoundation
import Foundation

/// Plays TTS mp3 data. Exposes `stop()` for barge-in: starting a new turn cuts
/// off whatever the assistant is currently saying.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    func play(_ mp3: Data, onFinish: @escaping () -> Void) {
        stop()
        do {
            let p = try AVAudioPlayer(data: mp3)
            p.delegate = self
            self.onFinish = onFinish
            player = p
            p.play()
        } catch {
            onFinish()
        }
    }

    /// Barge-in: silence the assistant immediately.
    func stop() {
        player?.stop()
        player = nil
        onFinish = nil
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let cb = onFinish
        self.player = nil
        self.onFinish = nil
        cb?()
    }
}
