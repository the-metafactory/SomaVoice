import AVFoundation
import Speech

/// Always-on listening with barge-in. One continuous AVAudioEngine with
/// voice-processing (acoustic echo cancellation) so the mic doesn't hear Ivy's
/// own TTS — that's what makes interrupting her possible without feedback.
///
/// Segmentation is VAD-driven, NOT SFSpeech `isFinal`: with a continuous stream
/// `isFinal` only fires on endAudio(), so we watch the mic level ourselves —
/// speech onset fires `onSpeechStart` (instant, for barge-in); a silence gap
/// after speech emits the latest partial transcript as `onUtterance` and swaps
/// in a fresh recognizer for the next utterance. The engine/tap stay up the
/// whole time (truly always listening); only the recognition request cycles.
final class ContinuousListener {
    var localeID = "en-US"
    var useAEC = true         // voice-processing (echo cancellation) — toggle to diagnose
    let vad = VadDetector()   // set vad.margin / vad.hang from outside
    var onSpeechStart: () -> Void = {}
    var onUtterance: (String) -> Void = { _ in }
    var onLevel: (Float, Float, Float) -> Void = { _, _, _ in }   // (level, threshold, floor)
    var onPartial: (String) -> Void = { _ in }   // live transcript / recognition errors (debug)

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var configObserver: NSObjectProtocol?

    // Latest partial transcript (written by the recognition handler).
    private let textLock = NSLock()
    private var latestText = ""

    var isRunning: Bool { running }

    func start() {
        guard !running, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        guard recognizer?.isAvailable == true else { return }
        running = true
        // Rebuild on input/output device changes (e.g. plugging in headphones) —
        // the engine stops and the tap format goes stale otherwise.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.bringUp()
        }
        bringUp()
    }

    /// (Re)install the tap on the current input device and start the engine.
    private func bringUp() {
        guard running else { return }
        let node = engine.inputNode
        try? node.setVoiceProcessingEnabled(useAEC)   // AEC — toggleable for diagnosis
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }
        vad.reset()
        engine.prepare()
        do { try engine.start() } catch { return }
        newRecognition()
    }

    func stop() {
        running = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        vad.reset()
        setText("")
    }

    // MARK: - audio

    private func handleBuffer(_ buf: AVAudioPCMBuffer) {
        request?.append(buf)
        let db = Self.levelDB(buf)
        let dur = Double(buf.frameLength) / buf.format.sampleRate

        DispatchQueue.main.async { self.onLevel(db, self.vad.threshold, self.vad.floor) }

        switch vad.feed(db, dt: dur) {
        case .onset:  DispatchQueue.main.async { self.onSpeechStart() }
        case .offset: endUtterance()
        case .none:   break
        }
    }

    /// Pause after speech → emit the latest transcript, reset, fresh recognizer.
    private func endUtterance() {
        let text = getText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard running else { return }
        // swap recognizer first so the next words start clean
        newRecognition()
        if !text.isEmpty { DispatchQueue.main.async { self.onUtterance(text) } }
    }

    // MARK: - recognition (cycled per utterance; engine keeps running)

    private func newRecognition() {
        task?.cancel(); task = nil
        request?.endAudio()
        setText("")

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let t = result.bestTranscription.formattedString
                self.setText(t)
                DispatchQueue.main.async { self.onPartial(t) }
            } else if let error {
                DispatchQueue.main.async { self.onPartial("⚠︎ \(error.localizedDescription)") }
            }
        }
    }

    private func setText(_ s: String) { textLock.lock(); latestText = s; textLock.unlock() }
    private func getText() -> String { textLock.lock(); defer { textLock.unlock() }; return latestText }

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
