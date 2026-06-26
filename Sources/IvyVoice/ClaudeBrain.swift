import Foundation

/// The brain is a real Claude Code session, invoked via the `claude` CLI from
/// `~/.claude`. That's deliberate: running the actual CLI means the full PAI
/// config loads — Ivy's identity, every skill — so personality and capability
/// come for free instead of being reimplemented here.
///
/// Continuity is via `--resume <sessionId>`: the first turn of a persona starts
/// a fresh session, later turns resume it so the conversation has memory.
///
/// NOTE (latency): `claude -p --resume` spawns a fresh process each turn and
/// reloads the session transcript + MCP/skills. That's seconds, not the warm
/// sub-second loop a direct Messages-API path would give. Acceptable for this
/// prototype because personality + skills were the stated priority; the warm
/// path is the documented next step.
actor ClaudeBrain {
    /// session id per persona, so switching being keeps separate threads.
    private var sessions: [String: String] = [:]

    struct Reply { let text: String; let sessionId: String? }

    func ask(_ prompt: String, persona: Persona) async throws -> Reply {
        var args = [
            "-p", prompt,
            "--output-format", "json",
            "--append-system-prompt", persona.preamble,
        ]
        if let sid = sessions[persona.id] {
            args.append(contentsOf: ["--resume", sid])
        }

        let out = try await runClaude(args: args)
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Fall back to raw stdout if it wasn't JSON.
            return Reply(text: out.trimmingCharacters(in: .whitespacesAndNewlines), sessionId: nil)
        }
        let text = (obj["result"] as? String)
            ?? (obj["text"] as? String)
            ?? ""
        if let sid = obj["session_id"] as? String { sessions[persona.id] = sid }
        return Reply(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                     sessionId: sessions[persona.id])
    }

    /// Forget a persona's thread (start fresh next turn).
    func reset(persona: Persona) { sessions[persona.id] = nil }

    private func runClaude(args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Config.claudePath)
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath: Config.brainWorkingDir)
            var env = ProcessInfo.processInfo.environment
            let extra = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
            env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 && out.isEmpty {
                    let err = String(data: errData, encoding: .utf8) ?? "exit \(p.terminationStatus)"
                    cont.resume(throwing: NSError(domain: "ClaudeBrain", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: err]))
                } else {
                    cont.resume(returning: out)
                }
            }

            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}
