import Foundation
import SwiftUI

struct Turn: Identifiable {
    let id = UUID()
    let speaker: String   // "You" or persona name
    let text: String
}

@MainActor
final class Conversation: ObservableObject {
    enum State: Equatable {
        case idle, listening, thinking, speaking, error(String)
        var label: String {
            switch self {
            case .idle: return "Ready"
            case .listening: return "Listening…"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking…"
            case let .error(m): return "Error: \(m)"
            }
        }
    }

    enum BrainKind: String, CaseIterable, Identifiable {
        case router      // fast reflex + self-delegation to deep Ivy (skills/memory)
        case pi          // pi.dev lean — Soma projection of Ivy, ~7s
        case fast        // Anthropic API — ~1-3s/turn, personality, no skills
        case openrouter  // OpenRouter API — any model, ~1-3s, personality, no skills
        case skilled     // warm claude (PAI) session — full skills, ~20s/turn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .router: return "Router (fast + deep)"
            case .pi: return "pi.dev lean (Soma Ivy)"
            case .fast: return "Fast (Anthropic)"
            case .openrouter: return "OpenRouter"
            case .skilled: return "Skilled (PAI)"
            }
        }
    }

    /// Speech-recognition language (per-locale; Apple Speech has no auto-detect).
    enum SttLanguage: String, CaseIterable, Identifiable {
        case enUS = "en-US"     // on-device
        case deCH = "de-CH"     // Swiss German, on-device
        case deDE = "de-DE"     // High German, server unless asset downloaded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .enUS: return "EN"
            case .deCH: return "DE-CH"
            case .deDE: return "DE"
            }
        }
    }

    /// Deep-thinking substrate the Router escalates to.
    enum DeepSubstrate: String, CaseIterable, Identifiable {
        case piDev, codex, claudeCode
        var id: String { rawValue }
        var label: String {
            switch self {
            case .piDev: return "pi.dev"
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            }
        }
    }

    @Published var state: State = .idle {
        didSet {
            // Wake listener owns the mic only while fully idle.
            if case .idle = state {
                if wakeEnabled, !conversationActive { startWake() }
            } else {
                wakeListener.stop()
            }
        }
    }
    @Published var transcript: [Turn] = []
    @Published var persona: Persona = .ivy
    @Published var brainKind: BrainKind = .router
    @Published var deepSubstrate: DeepSubstrate =
        DeepSubstrate(rawValue: UserDefaults.standard.string(forKey: "deepSubstrate") ?? "") ?? .piDev {
        didSet { UserDefaults.standard.set(deepSubstrate.rawValue, forKey: "deepSubstrate") }
    }
    @Published var sttLanguage: SttLanguage =
        SttLanguage(rawValue: UserDefaults.standard.string(forKey: "sttLanguage") ?? "") ?? .enUS {
        didSet { UserDefaults.standard.set(sttLanguage.rawValue, forKey: "sttLanguage") }
    }
    /// Always-on wake word (continuous on-device Speech).
    @Published var wakeEnabled = UserDefaults.standard.bool(forKey: "wakeEnabled") {
        didSet { UserDefaults.standard.set(wakeEnabled, forKey: "wakeEnabled") }
    }
    @Published var wakePhrase = UserDefaults.standard.string(forKey: "wakePhrase") ?? "hey ivy" {
        didSet { UserDefaults.standard.set(wakePhrase, forKey: "wakePhrase") }
    }
    /// Always-on listening with echo-cancelled barge-in (interrupt Ivy by voice).
    @Published var bargeIn = UserDefaults.standard.object(forKey: "bargeIn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bargeIn, forKey: "bargeIn") }
    }
    /// Hands-free back-and-forth: listen → respond → auto-listen, until toggled off.
    @Published var conversationActive = false

    // VAD tuning — live-adjustable via sliders, persisted across launches.
    /// Adaptive trigger: speech = level this many dB above the live noise floor.
    @Published var vadMargin: Float = Float(UserDefaults.standard.object(forKey: "vad.margin") as? Double ?? 8) {
        didSet { UserDefaults.standard.set(Double(vadMargin), forKey: "vad.margin") }
    }
    @Published var silenceHang: Double = UserDefaults.standard.object(forKey: "vad.silenceHang") as? Double ?? 1.2 {
        didSet { UserDefaults.standard.set(silenceHang, forKey: "vad.silenceHang") }
    }
    @Published var maxListen: Double = UserDefaults.standard.object(forKey: "vad.maxListen") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(maxListen, forKey: "vad.maxListen") }
    }
    /// Live mic level + current trigger threshold + noise floor (dBFS) for the meter/readout.
    @Published var micLevel: Float = -160
    @Published var micThreshold: Float = -42
    @Published var micFloor: Float = -50
    @Published var partialText = ""   // live continuous transcript / recognition error (debug)
    /// Echo cancellation (voice-processing) for barge-in. Toggle to diagnose AGC issues.
    @Published var aecEnabled = UserDefaults.standard.object(forKey: "aecEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aecEnabled, forKey: "aecEnabled") }
    }

    private let recorder = AudioRecorder()
    private let player = AudioPlayer()
    private let routerBrain = RouterBrain()
    private let piBrain = PiBrain()
    private let fastBrain = ApiBrain()
    private let openRouterBrain = OpenRouterBrain()
    private let skilledBrain = WarmBrain()
    // Deep substrates the router can escalate to.
    private let deepPi = PiBrain(lean: false)
    private let deepCodex = CodexBrain()
    private let stt = SpeechTranscriber()
    private var hotKey: ModifierHotKey?
    private var deepReassure: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    private var turnSeq = 0   // bumped per listen and on stop/barge-in; gates stale deep answers
    private lazy var wakeListener = WakeListener { [weak self] in self?.onWakeDetected() }
    private lazy var continuous = ContinuousListener()

    private var brain: Brain {
        switch brainKind {
        case .router: return routerBrain
        case .pi: return piBrain
        case .fast: return fastBrain
        case .openrouter: return openRouterBrain
        case .skilled: return skilledBrain
        }
    }

    /// Push-to-talk toggle. First press starts listening (barge-in: cuts off any
    /// current speech). Second press stops and runs the turn.
    func toggleTalk() {
        switch state {
        case .listening:
            stopAndProcess()
        case .speaking, .idle, .error:
            startListening()
        case .thinking:
            break // ignore while the brain is working
        }
    }

    /// Ask for mic + speech permission once. The .app bundle's Info.plist must
    /// carry NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription.
    func requestPermissions() {
        Task {
            _ = await AudioRecorder.requestPermission()
            _ = await SpeechTranscriber.requestPermission()
            startWake()   // begin always-on listening if it's enabled
        }
        // Spoken bridge + periodic reassurance while the router escalates to deep Ivy.
        routerBrain.onInterim = { [weak self] text in
            Task { @MainActor in self?.beginDeepWait(text) }
        }
        routerBrain.deep = currentDeep() // honor the persisted deep substrate
        brain.warmUp(persona) // no-op for HTTP brains; pays cold start for pi/CLI

        // System-wide hotkey: tap Control+Option to toggle hands-free conversation.
        if hotKey == nil {
            ModifierHotKey.requestAccessibility() // needed for the global monitor
            hotKey = ModifierHotKey(
                onStart: { [weak self] in self?.toggleConversation() },
                onStop: {})
        }
    }

    // MARK: - Conversation mode (hands-free)

    /// Tap-toggle from the hotkey: start a back-and-forth session, or end it.
    func toggleConversation() {
        if conversationActive { stopConversation() } else { startConversation() }
    }

    private func startConversation() {
        wakeListener.stop()        // conversation owns the mic now
        conversationActive = true
        startContinuous()          // one reliable capture path for all conversation
    }

    /// Toggle barge-in live — restarts the listener so AEC (on only for barge-in)
    /// is applied.
    func setBargeIn(_ on: Bool) {
        bargeIn = on
        if conversationActive { continuous.stop(); startContinuous() }
    }

    /// Always-on mode: one echo-cancelled stream, utterances + instant barge-in.
    private func startContinuous() {
        continuous.localeID = sttLanguage.rawValue
        continuous.useAEC = bargeIn   // AEC needed only when listening through her speech
        continuous.vad.margin = vadMargin
        continuous.vad.hang = silenceHang
        continuous.onLevel = { [weak self] l, t, f in
            self?.micLevel = l; self?.micThreshold = t; self?.micFloor = f
        }
        // Only barge-in mode reacts to speech while Ivy is talking/thinking.
        continuous.onSpeechStart = { [weak self] in
            guard let self, self.bargeIn else { return }
            self.handleSpeechStart()
        }
        // Process an utterance only when we're actually listening — in half-duplex
        // this drops anything captured while she speaks (incl. her own voice).
        continuous.onUtterance = { [weak self] t in
            guard let self, case .listening = self.state else { return }
            self.processUtterance(t)
        }
        continuous.onPartial = { [weak self] t in self?.partialText = t }
        continuous.start()
        state = .listening
    }

    /// Toggle echo cancellation live (restarts the continuous listener to apply it).
    func setAec(_ on: Bool) {
        aecEnabled = on
        if bargeIn, conversationActive {
            continuous.stop()
            startContinuous()
        }
    }

    /// User started talking — if Ivy is speaking or thinking, cut her off (barge-in)
    /// and invalidate the in-flight turn.
    private func handleSpeechStart() {
        switch state {
        case .speaking, .thinking:
            turnSeq += 1
            deepReassure?.cancel()
            player.stop()
            state = .listening
        default:
            if case .listening = state {} else { state = .listening }
        }
    }

    // MARK: - Wake word

    private func onWakeDetected() {
        guard !conversationActive else { return }
        startConversation()
    }

    /// Start the always-on listener (idempotent; only when enabled and idle).
    private func startWake() {
        guard wakeEnabled, !conversationActive, !wakeListener.isRunning else { return }
        wakeListener.phrase = wakePhrase
        wakeListener.localeID = sttLanguage.rawValue
        wakeListener.start()
    }

    func setWakeEnabled(_ on: Bool) {
        wakeEnabled = on
        if on { startWake() } else { wakeListener.stop() }
    }

    /// "Learn" the wake phrase: record ~2.5s, transcribe, store it.
    func learnWakePhrase() {
        wakeListener.stop()
        state = .listening
        Task { @MainActor in
            do {
                try recorder.start()
                try await Task.sleep(nanoseconds: 2_500_000_000)
                guard let url = recorder.stop() else { state = .idle; return }
                let p = try await stt.transcribe(fileURL: url, localeID: sttLanguage.rawValue)
                try? FileManager.default.removeItem(at: url)
                let clean = p.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { wakePhrase = clean }
                state = .idle  // didSet restarts wake if enabled
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func stopConversation() {
        conversationActive = false
        turnSeq += 1   // invalidate any in-flight deep turn
        vadTask?.cancel()
        deepReassure?.cancel()
        continuous.stop()
        recorder.stop()
        player.stop()
        state = .idle
    }

    /// One hands-free listen: record with VAD, end on a pause, then process. If
    /// no speech is heard, just listen again (stay online). The post-answer
    /// relisten is wired in stopAndProcess's completion.
    private func listenCycle() {
        guard conversationActive else { return }
        turnSeq += 1
        deepReassure?.cancel()
        player.stop()
        do { try recorder.start() } catch { state = .error(error.localizedDescription); return }
        state = .listening

        vadTask?.cancel()
        vadTask = Task { @MainActor in
            let dt = 0.1
            let noSpeechReset = 8.0        // re-listen if nothing said
            let vad = VadDetector()
            vad.margin = vadMargin; vad.hang = silenceHang
            var spoke = false, elapsed = 0.0

            while !Task.isCancelled, case .listening = state {
                try? await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
                guard case .listening = state else { return }
                elapsed += dt
                let lvl = recorder.currentLevel()
                micLevel = lvl; micThreshold = vad.threshold; micFloor = vad.floor
                switch vad.feed(lvl, dt: dt) {
                case .onset:  spoke = true
                case .offset: stopAndProcess(); return
                case .none:   break
                }
                if spoke, elapsed >= maxListen { stopAndProcess(); return }
                if !spoke, elapsed >= noSpeechReset {
                    recorder.stop()
                    if conversationActive { listenCycle() }   // keep waiting
                    return
                }
            }
            micLevel = -160
        }
    }

    /// Chord pressed — begin listening (barge-in over any current speech).
    func holdStart() {
        switch state {
        case .listening, .thinking: return
        default: startListening()
        }
    }

    /// Chord released — send what was captured.
    func holdEnd() {
        if state == .listening { stopAndProcess() }
    }

    /// Deep turns (skills/tools) can take 60-90s. Speak a bridge, then reassure
    /// every ~22s so the silence never reads as a hang. Cancelled when the real
    /// answer arrives (see stopAndProcess).
    func beginDeepWait(_ bridge: String) {
        speakInterim(bridge)
        deepReassure?.cancel()
        deepReassure = Task { @MainActor in
            let lines = ["Still working on it.", "Almost there, hang on.", "Still on it, one moment."]
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 22_000_000_000)
                guard !Task.isCancelled, case .thinking = state else { break }
                speakInterim(lines[i % lines.count]); i += 1
            }
        }
    }

    /// Speak a short line while still thinking — won't talk over the real answer.
    func speakInterim(_ text: String) {
        Task { @MainActor in
            guard case .thinking = state, let el = try? ElevenLabs(),
                  let mp3 = try? await el.synthesize(text: text, voiceId: persona.voiceId)
            else { return }
            if case .thinking = state { player.play(mp3) {} }
        }
    }

    func setBrainKind(_ kind: BrainKind) {
        brainKind = kind
        brain.warmUp(persona)
    }

    /// Live-apply VAD sliders to the running continuous listener (the long-lived
    /// detector was set only once at start, so the sliders looked dead).
    func setVadMargin(_ v: Float) { vadMargin = v; continuous.vad.margin = v }
    func setSilenceHang(_ v: Double) { silenceHang = v; continuous.vad.hang = v }

    /// The Router's escalation target for the current deep-substrate setting.
    private func currentDeep() -> Brain {
        switch deepSubstrate {
        case .piDev: return deepPi
        case .codex: return deepCodex
        case .claudeCode: return skilledBrain
        }
    }

    func setDeepSubstrate(_ s: DeepSubstrate) {
        deepSubstrate = s
        routerBrain.deep = currentDeep()
    }

    func switchPersona(_ p: Persona) {
        persona = p
        player.stop()
        state = .idle
        brain.warmUp(p)
    }

    private func startListening() {
        turnSeq += 1           // invalidate any in-flight turn (barge-in)
        deepReassure?.cancel() // barge-in cancels any pending deep wait
        player.stop() // barge-in
        do {
            try recorder.start()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// One-shot (push-style) capture: record → transcribe → process.
    private func stopAndProcess() {
        guard let fileURL = recorder.stop() else { idleOrRelisten(); return }
        state = .thinking
        let token = turnSeq
        Task {
            let heard = (try? await stt.transcribe(fileURL: fileURL, localeID: sttLanguage.rawValue)) ?? ""
            try? FileManager.default.removeItem(at: fileURL)
            guard token == turnSeq else { return }
            if heard.isEmpty { idleOrRelisten(); return }
            processUtterance(heard)
        }
    }

    /// Unified turn: used by one-shot capture AND the continuous listener. Handles
    /// stop-commands, runs the brain, speaks, and returns to listening. A per-turn
    /// token lets a barge-in / stop discard a stale (e.g. deep) answer.
    private func processUtterance(_ heard: String) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { afterSpeak(); return }
        transcript.append(Turn(speaker: "You", text: h))

        if conversationActive, isStopCommand(h) {
            stopConversation()
            Task { if let el = try? ElevenLabs() { try? await speakAndIdle("Okay, stopping.", el) } }
            return
        }

        state = .thinking
        let token = turnSeq
        let persona = self.persona
        Task {
            do {
                let el = try ElevenLabs()
                let text = try await brain.ask(h, persona: persona)
                deepReassure?.cancel()
                guard token == turnSeq else { return }   // barged / stopped while running
                transcript.append(Turn(speaker: persona.name, text: text))
                let mp3 = try await el.synthesize(text: text, voiceId: persona.voiceId)
                guard token == turnSeq else { return }
                state = .speaking
                player.play(mp3) { [weak self] in
                    Task { @MainActor in
                        guard let self, case .speaking = self.state else { return }
                        self.afterSpeak()
                    }
                }
            } catch {
                deepReassure?.cancel()
                guard token == turnSeq else { return }
                transcript.append(Turn(speaker: persona.name, text: "Sorry — that didn't go through."))
                afterSpeak()
            }
        }
    }

    /// After speaking (or a recoverable error): keep the right listening mode alive.
    private func afterSpeak() {
        if conversationActive {
            state = .listening   // continuous listener is already running
        } else {
            state = .idle        // didSet restarts the wake listener
        }
    }

    /// Recognize a spoken "stop the conversation" command (EN + DE).
    private func isStopCommand(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n"))
        if ["stop", "stopp", "halt", "schluss"].contains(t) { return true }
        let phrases = [
            "stop listening", "stop the conversation", "stop conversation", "stop ivy",
            "that's all", "thats all", "goodbye ivy", "we're done", "were done", "that's enough",
            "hör auf", "hoer auf", "beende", "das war's", "das wars", "danke das war",
        ]
        return phrases.contains { t.contains($0) }
    }

    /// Speak a one-off line then go idle (used for the stop confirmation).
    private func speakAndIdle(_ text: String, _ el: ElevenLabs) async throws {
        transcript.append(Turn(speaker: persona.name, text: text))
        let mp3 = try await el.synthesize(text: text, voiceId: persona.voiceId)
        state = .speaking
        player.play(mp3) { [weak self] in
            Task { @MainActor in if case .speaking = self?.state { self?.state = .idle } }
        }
    }

    /// In conversation mode, keep the loop alive; otherwise go idle.
    private func idleOrRelisten() {
        if conversationActive { listenCycle() } else { state = .idle }
    }
}
