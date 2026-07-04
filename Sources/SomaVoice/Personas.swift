import Foundation

/// A named being you can talk to. Personality + skills come from the real
/// Claude Code session (cwd `~/.claude`); the preamble only nudges *which*
/// assistant is answering and the voice it speaks in.
struct Persona: Identifiable, Hashable {
    let id: String
    let name: String
    let voiceId: String
    /// Appended to the Claude Code system prompt via `--append-system-prompt`.
    let preamble: String

    /// A copy of this persona under a principal-chosen name. The preamble's
    /// self-reference is rewritten too, so she introduces herself by the new
    /// name. Empty or unchanged names return self.
    func renamed(_ newName: String) -> Persona {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != name else { return self }
        return Persona(id: id, name: clean, voiceId: voiceId,
                       preamble: preamble.replacingOccurrences(of: name, with: clean))
    }

    static let ivy = Persona(
        id: "ivy",
        name: "Ivy",
        voiceId: Config.ivyVoiceId,   // ~/.env ELEVENLABS_VOICE_ID (DA-identity fallback) — single source of truth
        preamble: """
        You are Ivy, speaking out loud over a voice interface. Keep replies short, \
        conversational, and natural — one or two sentences unless asked for more. \
        No markdown, no bullet lists, no code blocks: this will be read aloud by \
        text-to-speech. Speak in the first person as Ivy.
        """
    )

    /// "and others" — additional beings from the cortex roster. Voice ids are
    /// ElevenLabs presets; swap for the real cortex assistant voices later.
    static let echo = Persona(
        id: "echo",
        name: "Echo",
        voiceId: "JBFqnCBsd6RMkjVDRZzb",
        preamble: """
        You are Echo, a focused engineering assistant, speaking out loud over a \
        voice interface. Keep replies short and conversational — this is read aloud \
        by text-to-speech, so no markdown or code blocks. Speak in the first person.
        """
    )

    static let all: [Persona] = [.ivy, .echo]
}
