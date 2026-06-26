import Foundation

/// Fast conversational brain over OpenRouter (OpenAI-compatible chat
/// completions). One key, any model — route Ivy to a Claude, GPT, Llama, or
/// local model by changing the slug. Same shape as `ApiBrain`: per-persona
/// in-process history, system prompt carrying the personality, no skills.
final class OpenRouterBrain: Brain {
    /// OpenRouter model slug. Must match a model in OpenRouter's catalog;
    /// change to taste (e.g. "openai/gpt-4o-mini", "google/gemini-2.0-flash").
    var model = "anthropic/claude-haiku-4.5"
    private let maxTokens = 400

    private var histories: [String: [[String: String]]] = [:]

    func warmUp(_ persona: Persona) { /* stateless HTTP; nothing to warm */ }

    func ask(_ text: String, persona: Persona) async throws -> String {
        guard let key = Config.openRouterKey, !key.isEmpty else {
            throw OpenRouterError.noKey
        }

        var history = histories[persona.id] ?? []
        history.append(["role": "user", "content": text])

        // System message first, then the running conversation.
        var messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt(for: persona)]
        ]
        messages.append(contentsOf: history)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional attribution headers OpenRouter recommends.
        req.setValue("https://github.com/the-metafactory/ivy-voice", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Ivy Voice", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OpenRouterError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let b = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(http.statusCode, String(b.prefix(300)))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let reply = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw OpenRouterError.badResponse }

        history.append(["role": "assistant", "content": reply])
        histories[persona.id] = history
        return reply.isEmpty ? "(no reply)" : reply
    }

    func reset(_ persona: Persona) { histories[persona.id] = nil }

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

enum OpenRouterError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .noKey: return "OPENROUTER_API_KEY not in ~/.env"
        case let .http(c, b): return "OpenRouter HTTP \(c): \(b)"
        case .badResponse: return "Unexpected OpenRouter response"
        }
    }
}
