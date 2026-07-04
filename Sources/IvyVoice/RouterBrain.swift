import Foundation

/// The in-between brain: System 1 / System 2 Ivy.
///
/// A fast OpenRouter model answers directly (~2s) and routes ITSELF via two
/// tools:
///   • recall(query)  → fast read-only memory lookup, returned inline (stays fast)
///   • delegate(task) → hand off to deep Ivy (full pi: skills, tools, memory)
///
/// On delegate it speaks a short bridge ("let me look into that") via `onInterim`
/// so the voice never goes silent during the slow deep turn, then returns deep
/// Ivy's answer as the reply. One Ivy, two speeds.
final class RouterBrain: Brain {
    var model = "anthropic/claude-haiku-4.5"   // fast reflex tier (tool-capable)
    private let maxHops = 4

    private let memory = MemoryIndex()
    /// Escalation target — swappable deep substrate (pi.dev / Codex / Claude Code).
    var deep: Brain = PiBrain(lean: false)
    /// The eye. Wired by Conversation. nil until enrolled; `see` degrades gracefully.
    var sight: Sense?

    /// Spoken bridge while the deep tier works. Wired by Conversation to TTS.
    var onInterim: ((String) -> Void)?

    private var histories: [String: [[String: Any]]] = [:]

    func warmUp(_ persona: Persona) { deep.warmUp(persona) }

    func ask(_ text: String, persona: Persona) async throws -> String {
        guard let key = Config.openRouterKey, !key.isEmpty else { throw OpenRouterError.noKey }

        var history = histories[persona.id] ?? []
        history.append(["role": "user", "content": text])

        var messages: [[String: Any]] = [["role": "system", "content": Self.system(persona)]]
        messages.append(contentsOf: history)

        var hop = 0
        while hop < maxHops {
            hop += 1
            let msg = try await complete(messages, key: key, tools: Self.tools)

            // Tool calls? Handle them, then either loop (recall) or hand off (delegate/see).
            if let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                messages.append(msg)  // assistant turn carrying the tool_calls
                for call in calls {
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? ""
                    let args = decodeArgs(fn?["arguments"])
                    let id = call["id"] as? String ?? ""

                    switch name {
                    case "delegate":
                        let task = (args["task"] as? String) ?? text
                        onInterim?(Self.bridge)
                        let answer = try await deep.ask(task, persona: persona)
                        commit(&history, persona, user: text, assistant: answer)
                        return answer
                    case "recall":
                        let result = await memory.search((args["query"] as? String) ?? text)
                        messages.append(["role": "tool", "tool_call_id": id, "content": result])
                    case "see":
                        // Perception is TERMINAL (VISION.md invariants 1 & 2). The glance
                        // answer is returned directly and the turn ends — it is NEVER fed
                        // back through the broker, so a confidential frame's local answer
                        // never leaves the Mac (probe #5), and no `delegate` can run after a
                        // look: perception structurally cannot originate action (probe #3).
                        let q = (args["question"] as? String) ?? text
                        let (answer, note) = await lookAtScreen(question: q)
                        var stored = answer
                        if let note { stored += "\n(I looked at the screen: \(note))" }
                        commit(&history, persona, user: text, assistant: stored)
                        return answer
                    default:
                        messages.append(["role": "tool", "tool_call_id": id, "content": "unknown tool"])
                    }
                }
                continue  // re-ask the fast model with tool results in context
            }

            // Plain answer — the fast path.
            let reply = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            commit(&history, persona, user: text, assistant: reply.isEmpty ? "(no reply)" : reply)
            return reply.isEmpty ? "(no reply)" : reply
        }

        // Hop budget exhausted — escalate rather than loop forever.
        onInterim?(Self.bridge)
        let answer = try await deep.ask(text, persona: persona)
        commit(&history, persona, user: text, assistant: answer)
        return answer
    }

    // MARK: - Sight

    /// Capture the enrolled window and answer `question` about it. Routes through
    /// `Sense.describe`, which branches on the window's tier (confidential → local,
    /// zero egress; open → cloud). This method never decides tier or destination.
    /// Returns the spoken answer plus a sanitized "app — 5-word intent" note (the
    /// durable trace is intent, never screen content). All strings are phrased for
    /// the ear — the answer is spoken directly, not fed back to the router.
    private func lookAtScreen(question: String) async -> (answer: String, note: String?) {
        guard let sight else { return ("I can't see your screen right now.", nil) }
        // Distinguish "nothing enrolled" (nil) from "capture failed" (throw) so the
        // spoken message is honest and we can see the real error.
        let frame: SenseFrame?
        do {
            frame = try await sight.capture()
        } catch {
            return ("I couldn't capture that window — \(error.localizedDescription).", nil)
        }
        guard let frame else {
            return ("There's no window enrolled yet — say 'watch this window' and pick one.", nil)
        }
        // Only record the "I looked at the screen" note when the glance actually
        // produced an answer — a failed describe leaves no misleading trace.
        do {
            let answer = try await sight.describe(frame, question: question)
            let note = "\(frame.appName) — \(Self.fiveWordIntent(question))"
            return (answer, note)
        } catch {
            return ("I couldn't read that just now.", nil)
        }
    }

    /// First five words of the question — the durable note is intent, never content.
    private static func fiveWordIntent(_ q: String) -> String {
        q.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .prefix(5)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - OpenRouter call with tools

    private func complete(_ messages: [[String: Any]], key: String, tools: [[String: Any]]) async throws -> [String: Any] {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "messages": messages,
            "tools": tools,
        ]
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/the-metafactory/ivy-voice", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Ivy Voice", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let b = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(b.prefix(300)))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw OpenRouterError.badResponse
        }
        return msg
    }

    private func decodeArgs(_ raw: Any?) -> [String: Any] {
        guard let s = raw as? String, let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    private func commit(_ history: inout [[String: Any]], _ persona: Persona, user: String, assistant: String) {
        // Persist only clean turns (drop the tool scaffolding) for the next turn.
        history.append(["role": "assistant", "content": assistant])
        histories[persona.id] = history
    }

    // MARK: - prompt, tools, bridge

    private static let bridge = "Let me look into that, one second."

    private static func system(_ persona: Persona) -> String {
        """
        You are \(persona.name), Jens-Christian's personal AI assistant — a peer, \
        speaking out loud. Reply in one or two short, natural sentences. No markdown, \
        no lists, no headers — your text is read aloud.

        You are the fast reflex layer. Answer directly when you can. Use the `recall` \
        tool for anything about Jens-Christian's life, projects, people, decisions, or \
        past work. Use the `delegate` tool when the request needs real skills, tools, \
        files, code, the web, calendar, email, or any multi-step work — deep Ivy will \
        handle it. Prefer answering fast; only delegate when you genuinely cannot. \
        Use the `see` tool only when he explicitly asks you to look at or read \
        something on his screen.
        """
    }

    private static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "recall",
                "description": "Look up Jens-Christian's stored memories/notes/past work. Use for anything about his life, projects, people, decisions, or past sessions.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "What to look up"]],
                    "required": ["query"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "see",
                "description": "Look at the window Jens-Christian has enrolled on screen and answer a question about it. Use ONLY when he explicitly asks you to look at / read something on his screen (\"schau\", \"look\", \"see\", \"read this\").",
                "parameters": [
                    "type": "object",
                    "properties": ["question": ["type": "string", "description": "What he wants to know about the screen"]],
                    "required": ["question"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "delegate",
                "description": "Hand off to deep Ivy (full skills, tools, files, web, calendar, email, multi-step work). Use when you cannot answer from conversation or recall alone.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string", "description": "The task for deep Ivy, self-contained"],
                        "why": ["type": "string", "description": "Why it needs deep Ivy"],
                    ],
                    "required": ["task"],
                ],
            ],
        ],
    ]
}
