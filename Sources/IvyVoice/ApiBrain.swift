import Foundation

/// Fast conversational brain over the Anthropic Messages API. Keeps an
/// in-process message history per persona (the "warm" state — nothing reloads
/// between turns) and prompt-caches the system prompt so each turn is just a
/// short model call. No skills; personality lives in the system prompt.
final class ApiBrain: Brain {
    /// Default to the fastest model for a snappy voice loop.
    var model = "claude-haiku-4-5-20251001"
    private let maxTokens = 400

    private var histories: [String: [[String: Any]]] = [:]

    func warmUp(_ persona: Persona) { /* no process to spawn; nothing to warm */ }

    func ask(_ text: String, persona: Persona) async throws -> String {
        guard let key = Config.anthropicKey, !key.isEmpty else {
            throw ApiBrainError.noKey
        }

        var history = histories[persona.id] ?? []
        history.append(["role": "user", "content": text])

        let system: [[String: Any]] = [[
            "type": "text",
            "text": Self.systemPrompt(for: persona),
            "cache_control": ["type": "ephemeral"],
        ]]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": history,
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApiBrainError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let b = String(data: data, encoding: .utf8) ?? ""
            throw ApiBrainError.http(http.statusCode, String(b.prefix(300)))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw ApiBrainError.badResponse
        }
        let reply = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        history.append(["role": "assistant", "content": reply])
        histories[persona.id] = history
        return reply.isEmpty ? "(no reply)" : reply
    }

    func reset(_ persona: Persona) { histories[persona.id] = nil }

    /// Ivy's personality, compact, with the voice-output constraints baked in.
    private static func systemPrompt(for persona: Persona) -> String {
        """
        You are \(persona.name), Jens-Christian Fischer's personal AI assistant — \
        a peer collaborator, not a servant. Curious, precise, warm, direct. \
        Speak in the first person as \(persona.name).

        This is a spoken voice conversation. Reply in one or two short, natural \
        sentences. No markdown, no bullet lists, no code blocks, no headers — your \
        text is read aloud by text-to-speech. German for personal chat, English \
        for technical topics, matching how Jens-Christian speaks to you.

        \(persona.preamble)
        """
    }
}

enum ApiBrainError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .noKey: return "ANTHROPIC_API_KEY not in ~/.env (the fast brain needs an API key)"
        case let .http(c, b): return "Anthropic HTTP \(c): \(b)"
        case .badResponse: return "Unexpected Anthropic response"
        }
    }
}
