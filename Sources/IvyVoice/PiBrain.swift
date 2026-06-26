import Foundation

/// pi.dev brain: spawns the `pi` agent CLI, which Soma projects Ivy into
/// (~/.pi/agent/extensions/soma.ts). So this is *the Soma projection of Ivy* —
/// the same portable identity, not a re-typed system prompt — and pi routes to
/// any provider (OpenRouter, local Ollama, Codex), so it subsumes the OpenRouter
/// path while staying provider-flexible.
///
/// Measured ~7s/turn cold (vs ~24s for the PAI `claude` harness): pi is a
/// lighter agent. Memory across turns via a stable per-persona `--session-id`.
/// Set `model` to override pi's default (e.g. "ollama/gemma4" for fully local,
/// "openrouter/anthropic/claude-fable-latest" for hosted).
final class PiBrain: Brain {
    var model: String? = nil   // nil → pi's own default (Soma config)

    func warmUp(_ persona: Persona) { /* spawn-per-turn; nothing to pre-warm */ }

    func ask(_ text: String, persona: Persona) async throws -> String {
        var args = [
            "-p",
            "--mode", "json",
            "--session-id", "ivy-voice-\(persona.id)",
        ]
        if let model, !model.isEmpty { args.append(contentsOf: ["--model", model]) }
        args.append(text)

        let out = try await run(args: args)
        return parseAssistant(from: out)
    }

    /// Pull the final assistant text out of pi's JSON event stream.
    private func parseAssistant(from stream: String) -> String {
        var last = ""
        for line in stream.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ev["type"] as? String == "message_end",
                  let msg = ev["message"] as? [String: Any],
                  msg["role"] as? String == "assistant",
                  let content = msg["content"] as? [[String: Any]]
            else { continue }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty { last = text }
        }
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no reply)" : trimmed
    }

    private func run(args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Config.piPath)
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:/usr/local/bin"
            env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            proc.environment = env

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.terminationHandler = { p in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if out.isEmpty && p.terminationStatus != 0 {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(p.terminationStatus)"
                    cont.resume(throwing: NSError(domain: "PiBrain", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: err]))
                } else {
                    cont.resume(returning: out)
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}
