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
        case pi          // pi.dev agent — Soma projection of Ivy, ~7s, multi-provider
        case fast        // Anthropic API — ~1-3s/turn, personality, no skills
        case openrouter  // OpenRouter API — any model, ~1-3s, personality, no skills
        case skilled     // warm claude (PAI) session — full skills, ~20s/turn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pi: return "pi.dev (Soma Ivy)"
            case .fast: return "Fast (Anthropic)"
            case .openrouter: return "OpenRouter"
            case .skilled: return "Skilled (PAI)"
            }
        }
    }

    @Published var state: State = .idle
    @Published var transcript: [Turn] = []
    @Published var persona: Persona = .ivy
    @Published var brainKind: BrainKind = .pi

    private let recorder = AudioRecorder()
    private let player = AudioPlayer()
    private let piBrain = PiBrain()
    private let fastBrain = ApiBrain()
    private let openRouterBrain = OpenRouterBrain()
    private let skilledBrain = WarmBrain()
    private let stt = SpeechTranscriber()

    private var brain: Brain {
        switch brainKind {
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
        // Only the skilled (CLI) brain has a costly spawn worth pre-warming.
        if brainKind == .skilled { skilledBrain.warmUp(persona) }
    }

    func setBrainKind(_ kind: BrainKind) {
        brainKind = kind
        if kind == .skilled { skilledBrain.warmUp(persona) }
    }

    func switchPersona(_ p: Persona) {
        persona = p
        player.stop()
        state = .idle
        if brainKind == .skilled { skilledBrain.warmUp(p) }
    }

    private func startListening() {
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
            state = .idle
            return
        }
        state = .thinking
        let persona = self.persona
        Task {
            do {
                let el = try ElevenLabs()
                let heard = try await stt.transcribe(fileURL: fileURL)
                try? FileManager.default.removeItem(at: fileURL)
                guard !heard.isEmpty else { state = .idle; return }
                transcript.append(Turn(speaker: "You", text: heard))

                let text = try await brain.ask(heard, persona: persona)
                transcript.append(Turn(speaker: persona.name, text: text))

                let mp3 = try await el.synthesize(text: text, voiceId: persona.voiceId)
                state = .speaking
                player.play(mp3) { [weak self] in
                    Task { @MainActor in
                        if case .speaking = self?.state { self?.state = .idle }
                    }
                }
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
