import AVFoundation
import Speech

/// Always-on listening with barge-in. One continuous AVAudioEngine with
/// voice-processing (acoustic echo cancellation) so the mic doesn't hear Ivy's
/// own TTS — that's what makes interrupting her possible without a feedback loop.
///
/// Two signals out:
///  • onSpeechStart — fired the instant the user's level crosses threshold
///    (immediate, for barge-in: stop playback / cancel a deep turn).
///  • onUtterance — the finalized transcript when SFSpeech endpoints a pause.
///
/// onLevel drives the tuning meter. Segments by restarting the recognition task
/// at each final result (also dodges Apple's ~1-min task limit).
final class ContinuousListener {
    var localeID = "en-US"
    var speechDB: Float = -30
    var onSpeechStart: () -> Void = {}
    var onUtterance: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cycleTimer: Task<Void, Never>?
    private var running = false
    private var speaking = false   // user is mid-utterance (onSpeechStart already fired)

    var isRunning: Bool { running }

    func start() {
        guard !running, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        guard recognizer?.isAvailable == true else { return }

        // Acoustic echo cancellation — the whole point. Best-effort.
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        running = true
        beginTask()
    }

    func stop() {
        running = false
        cycleTimer?.cancel(); cycleTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        speaking = false
    }

    private func beginTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        speaking = false

        let node = engine.inputNode
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            guard let self else { return }
            self.request?.append(buf)
            let db = Self.levelDB(buf)
            DispatchQueue.main.async {
                self.onLevel(db)
                if db > self.speechDB, !self.speaking {
                    self.speaking = true
                    self.onSpeechStart()
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { running = false; return }

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { DispatchQueue.main.async { self.onUtterance(text) } }
                if self.running { self.cycle() }
            } else if error != nil {
                if self.running { self.cycle() }
            }
        }

        cycleTimer?.cancel()
        cycleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            self?.cycle()
        }
    }

    private func cycle() {
        guard running else { return }
        cycleTimer?.cancel(); cycleTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if running { beginTask() }
    }

    /// RMS level of a buffer in dBFS.
    private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return -160 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -160 }
        let data = ch[0]
        var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    deinit { stop() }
}
