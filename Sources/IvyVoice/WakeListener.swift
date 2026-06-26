import AVFoundation
import Speech

/// Always-on wake-word listener. Streams the mic through on-device
/// SFSpeechRecognizer and fires `onWake` when the phrase is heard. Restarts the
/// recognition task periodically to dodge Apple's ~1-minute task limit. Holds
/// the mic only while idle; conversation mode stops it (see Conversation).
final class WakeListener {
    var phrase = "hey ivy"
    var localeID = "en-US"
    private let onWake: () -> Void

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restart: Task<Void, Never>?
    private var running = false

    init(onWake: @escaping () -> Void) { self.onWake = onWake }

    var isRunning: Bool { running }

    func start() {
        guard !running, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        guard recognizer?.isAvailable == true else { return }
        running = true
        beginTask()
    }

    func stop() {
        running = false
        restart?.cancel(); restart = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func beginTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req

        let node = engine.inputNode
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { running = false; return }

        let needle = phrase.lowercased()
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let said = result.bestTranscription.formattedString.lowercased()
                if !needle.isEmpty, said.contains(needle) {
                    self.stop()
                    DispatchQueue.main.async { self.onWake() }
                    return
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                if self.running { self.cycle() }
            }
        }

        // Periodic restart so the cumulative transcript stays short and the task
        // doesn't hit the ~1-min ceiling.
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            self?.cycle()
        }
    }

    /// Tear down the current task/engine and start a fresh one (if still running).
    private func cycle() {
        guard running else { return }
        restart?.cancel(); restart = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if running { beginTask() }
    }

    deinit { stop() }
}
