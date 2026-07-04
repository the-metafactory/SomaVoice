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
    enum SttMode { case apple, elevenLabs }
    var sttMode: SttMode = .apple
    var localeID = "en-US"
    var useAEC = true         // voice-processing (echo cancellation) — toggle to diagnose
    let vad = VadDetector()   // set vad.margin / vad.hang from outside
    var onSpeechStart: () -> Void = {}
    var onUtterance: (String) -> Void = { _ in }           // Apple mode: text
    var onUtteranceAudio: (Data) -> Void = { _ in }        // ElevenLabs mode: captured WAV
    var onLevel: (Float, Float, Float) -> Void = { _, _, _ in }   // (level, threshold, floor)
    var onPartial: (String) -> Void = { _ in }   // live transcript / recognition errors (debug)

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var converter: AVAudioConverter?
    private let sttFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000, channels: 1, interleaved: false)!

    // Latest partial transcript (written by the recognition handler).
    private let textLock = NSLock()
    private var latestText = ""

    // ElevenLabs mode: accumulate the utterance's 16k mono samples between onset/offset.
    private var capturing = false
    private var captureSamples = [Float]()

    var isRunning: Bool { running }
    private(set) var muted = false

    /// Half-duplex gate: while muted, ignore the mic entirely (don't feed STT or
    /// run VAD) so Ivy's own playback never becomes input. Reopening starts a
    /// fresh recognizer so no residual (her) words leak into the next turn.
    func setMuted(_ m: Bool) {
        guard m != muted else { return }
        muted = m
        if !m, running {
            vad.reset()
            capturing = false; captureSamples.removeAll()
            if sttMode == .apple { newRecognition() }
        }
    }

    func start() {
        guard !running else { return }
        if sttMode == .apple {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
            guard recognizer?.isAvailable == true else { return }
        }
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
        let inFormat = node.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: sttFormat)
        node.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }
        vad.reset()
        capturing = false; captureSamples.removeAll()
        engine.prepare()
        do { try engine.start() } catch { return }
        if sttMode == .apple { newRecognition() }
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
        if muted { return }   // half-duplex: don't capture Ivy's own playback
        let db = Self.levelDB(buf)
        let dur = Double(buf.frameLength) / buf.format.sampleRate
        let converted = convertTo16k(buf)

        DispatchQueue.main.async { self.onLevel(db, self.vad.threshold, self.vad.floor) }
        let ev = vad.feed(db, dt: dur)

        switch sttMode {
        case .apple:
            // Stream 16k mono to SFSpeech (raw 48k doesn't reliably transcribe).
            request?.append(converted ?? buf)
            switch ev {
            case .onset:  DispatchQueue.main.async { self.onSpeechStart() }
            case .offset: endUtterance()
            case .none:   break
            }
        case .elevenLabs:
            // Capture the utterance's samples; POST the WAV on the closing pause.
            if ev == .onset {
                capturing = true; captureSamples.removeAll()
                DispatchQueue.main.async { self.onSpeechStart() }
            }
            if capturing, let c = converted, let ch = c.floatChannelData {
                captureSamples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(c.frameLength)))
            }
            if ev == .offset {
                capturing = false
                let wav = Self.makeWav(captureSamples)
                captureSamples.removeAll()
                if wav.count > 64 { DispatchQueue.main.async { self.onUtteranceAudio(wav) } }
            }
        }
    }

    /// 16k mono 16-bit PCM WAV from captured float samples.
    private static func makeWav(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        var d = Data()
        let dataSize = samples.count * 2
        func a32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func a16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); a32(UInt32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); a32(16); a16(1); a16(1)
        a32(UInt32(sampleRate)); a32(UInt32(sampleRate * 2)); a16(2); a16(16)
        d.append("data".data(using: .ascii)!); a32(UInt32(dataSize))
        for s in samples { let c = max(-1, min(1, s)); a16(UInt16(bitPattern: Int16(c * 32767))) }
        return d
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
        // NOTE: do NOT force on-device for the streaming request — it gets canceled
        // immediately on this setup. Let SFSpeech pick (server) so we get results.
        req.requiresOnDeviceRecognition = false
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

    /// Resample/downmix a tap buffer to 16k mono Float32 for SFSpeech.
    private func convertTo16k(_ inBuf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = sttFormat.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: sttFormat, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        return err == nil && out.frameLength > 0 ? out : nil
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
