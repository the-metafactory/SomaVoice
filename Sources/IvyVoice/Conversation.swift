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

    @Published var state: State = .idle
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
    /// Hands-free back-and-forth: listen → respond → auto-listen, until toggled off.
    @Published var conversationActive = false

    // VAD tuning — live-adjustable via sliders, persisted across launches.
    @Published var speechDB: Float = Float(UserDefaults.standard.object(forKey: "vad.speechDB") as? Double ?? -30) {
        didSet { UserDefaults.standard.set(Double(speechDB), forKey: "vad.speechDB") }
    }
    @Published var silenceHang: Double = UserDefaults.standard.object(forKey: "vad.silenceHang") as? Double ?? 1.2 {
        didSet { UserDefaults.standard.set(silenceHang, forKey: "vad.silenceHang") }
    }
    @Published var maxListen: Double = UserDefaults.standard.object(forKey: "vad.maxListen") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(maxListen, forKey: "vad.maxListen") }
    }
    /// Live mic level (dBFS) for the tuning meter; -160 when not listening.
    @Published var micLevel: Float = -160

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
        conversationActive = true
        listenCycle()
    }

    private func stopConversation() {
        conversationActive = false
        vadTask?.cancel()
        deepReassure?.cancel()
        recorder.stop()
        player.stop()
        state = .idle
    }

    /// One hands-free listen: record with VAD, end on a pause, then process. If
    /// no speech is heard, just listen again (stay online). The post-answer
    /// relisten is wired in stopAndProcess's completion.
    private func listenCycle() {
        guard conversationActive else { return }
        deepReassure?.cancel()
        player.stop()
        do { try recorder.start() } catch { state = .error(error.localizedDescription); return }
        state = .listening

        vadTask?.cancel()
        vadTask = Task { @MainActor in
            let dt = 0.1
            let noSpeechReset = 8.0        // re-listen if nothing said
            var spoke = false, silence = 0.0, elapsed = 0.0

            while !Task.isCancelled, case .listening = state {
                try? await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
                guard case .listening = state else { return }
                elapsed += dt
                let lvl = recorder.currentLevel()
                micLevel = lvl
                if lvl > speechDB { spoke = true; silence = 0 } else if spoke { silence += dt }

                if spoke, silence >= silenceHang { stopAndProcess(); return }
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
        deepReassure?.cancel() // barge-in cancels any pending deep wait
        player.stop() // barge-in
        do {
            try recorder.start()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func stopAndProcess() {
        guard let fileURL = recorder.stop() else {
            idleOrRelisten()
            return
        }
        state = .thinking
        let persona = self.persona
        Task {
            do {
                let el = try ElevenLabs()
                let heard = try await stt.transcribe(fileURL: fileURL, localeID: sttLanguage.rawValue)
                try? FileManager.default.removeItem(at: fileURL)
                guard !heard.isEmpty else { idleOrRelisten(); return }
                transcript.append(Turn(speaker: "You", text: heard))

                // Voice "stop" — end the conversation with a short spoken confirm.
                if conversationActive, isStopCommand(heard) {
                    conversationActive = false
                    deepReassure?.cancel()
                    try await speakAndIdle("Okay, stopping. Tap to start again.", el)
                    return
                }

                let text = try await brain.ask(heard, persona: persona)
                deepReassure?.cancel() // answer's here — stop reassuring
                transcript.append(Turn(speaker: persona.name, text: text))

                let mp3 = try await el.synthesize(text: text, voiceId: persona.voiceId)
                state = .speaking
                player.play(mp3) { [weak self] in
                    Task { @MainActor in
                        guard let self, case .speaking = self.state else { return }
                        self.state = .idle
                        if self.conversationActive { self.listenCycle() } // next turn
                    }
                }
            } catch {
                deepReassure?.cancel()
                state = .error(error.localizedDescription)
            }
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
