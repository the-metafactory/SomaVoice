import Foundation

/// Adaptive voice-activity detector. Triggers when the level rises `margin` dB
/// above a continuously-estimated noise floor, so it self-calibrates to the mic,
/// its gain, the AEC path, and the capture method — one setting works for both
/// the AVAudioRecorder (push) path and the AVAudioEngine (barge-in) path, and
/// across input devices. Hysteresis on the way down plus a silence `hang` ends
/// an utterance.
final class VadDetector {
    var margin: Float = 8        // dB over noise floor that counts as speech
    var hang: Double = 1.2       // silence (s) that ends an utterance

    enum Event { case none, onset, offset }

    private var noiseFloor: Float = -50
    private var speaking = false
    private var silence = 0.0

    /// Live onset threshold, for the meter marker.
    var threshold: Float { noiseFloor + margin }
    var floor: Float { noiseFloor }

    func reset() { speaking = false; silence = 0 }   // keep the learned floor

    func feed(_ db: Float, dt: Double) -> Event {
        if !speaking {
            // Min-follower noise floor: drops fast to quiet, rises slowly (~0.5 dB/s).
            if db < noiseFloor { noiseFloor = db } else { noiseFloor += Float(0.5 * dt) }
            noiseFloor = max(-70, min(-25, noiseFloor))
            if db > noiseFloor + margin { speaking = true; silence = 0; return .onset }
            return .none
        } else {
            if db < noiseFloor + margin * 0.5 {   // hysteresis
                silence += dt
                if silence >= hang { speaking = false; silence = 0; return .offset }
            } else {
                silence = 0
            }
            return .none
        }
    }
}
