import AVFoundation
import Foundation

/// Records the mic to a temporary m4a file (AAC). ElevenLabs scribe accepts it
/// directly. AVAudioRecorder keeps this far simpler than tapping AVAudioEngine.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    /// Request mic permission up front (the .app bundle's Info.plist must carry
    /// NSMicrophoneUsageDescription or the prompt is suppressed).
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: cont.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            default: cont.resume(returning: false)
            }
        }
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivy-turn-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true   // for voice-activity detection
        rec.record()
        recorder = rec
        fileURL = url
    }

    /// Current input level in dBFS (-160 = silence, 0 = max). Used for VAD.
    func currentLevel() -> Float {
        guard let rec = recorder else { return -160 }
        rec.updateMeters()
        return rec.averagePower(forChannel: 0)
    }

    /// Stop and return the recorded file (nil if nothing usable was captured).
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        guard let url = fileURL,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 1_000 else { return nil }
        return url
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}
