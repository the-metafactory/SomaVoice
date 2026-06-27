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
    var speechDB: Float = -30
    var silenceHang: Double = 1.2
    var onSpeechStart: () -> Void = {}
    var onUtterance: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false

    // VAD state (touched only from the serial tap callback).
    private var speaking = false
    private var silenceAccum = 0.0

    // Latest partial transcript (written by the recognition handler).
    private let textLock = NSLock()
    private var latestText = ""

    var isRunning: Bool { running }

    func start() {
        guard !running, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        guard recognizer?.isAvailable == true else { return }

        let node = engine.inputNode
        try? node.setVoiceProcessingEnabled(true)   // AEC — best effort

        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { return }

        running = true
        newRecognition()
    }

    func stop() {
        running = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        speaking = false; silenceAccum = 0
        setText("")
    }

    // MARK: - audio

    private func handleBuffer(_ buf: AVAudioPCMBuffer) {
        request?.append(buf)
        let db = Self.levelDB(buf)
        let dur = Double(buf.frameLength) / buf.format.sampleRate

        DispatchQueue.main.async { self.onLevel(db) }

        if db > speechDB {
            silenceAccum = 0
            if !speaking {
                speaking = true
                DispatchQueue.main.async { self.onSpeechStart() }
            }
        } else if speaking {
            silenceAccum += dur
            if silenceAccum >= silenceHang {
                endUtterance()
            }
        }
    }

    /// Pause after speech → emit the latest transcript, reset, fresh recognizer.
    private func endUtterance() {
        speaking = false
        silenceAccum = 0
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
        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            self.setText(result.bestTranscription.formattedString)
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
