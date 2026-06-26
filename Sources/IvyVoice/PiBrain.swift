import Foundation

/// Lean pi.dev brain: the `pi` agent stripped to a minimal initial context, with
/// Soma-Ivy's identity injected as *static system text* (from ~/.soma/profile)
/// instead of the heavy live soma extension + algorithm.
///
/// Measured: full pi ~11.7s, lean+live-extension ~6.6s, **lean+static-identity
/// ~2.8s warm** — competitive with the direct APIs while still being the Soma
/// projection of Ivy. The lean flags:
///   -ne  no extension discovery (drops soma-algorithm + others)
///   -ns  no skills
///   -nc  no AGENTS.md/CLAUDE.md context
///   -nt  no tools (it's a conversation, not a coding run)
///   --thinking off
/// Identity comes from --append-system-prompt on the compact Soma profile files;
/// memory from a per-persona --session-id.
///
/// First spawn pays pi's ~10s runtime cold start; `warmUp` fires a throwaway at
/// launch so the first real turn is fast.
final class PiBrain: Brain {
    var model: String? = nil   // nil → pi's default provider; set for fast/local

    /// lean = stripped minimal context (fast conversational Ivy).
    /// full = extensions + skills + tools + context (deep Ivy, the escalation target).
    let lean: Bool
    init(lean: Bool = true) { self.lean = lean }

    func warmUp(_ persona: Persona) {
        Task.detached { [weak self] in
            // Ephemeral throwaway to pay the runtime cold start; no session.
            _ = try? await self?.run(args: [
                "-p", "--mode", "json", "--no-session",
                "-ne", "-ns", "-nc", "-nt", "--thinking", "off",
                "hi",
            ])
        }
    }

    func ask(_ text: String, persona: Persona) async throws -> String {
        let voice = "Spoken voice reply: one or two short, natural sentences. No markdown, no lists, no headers — your text is read aloud."
        var args = ["-p", "--mode", "json", "--session-id", "ivy-voice-\(lean ? "" : "deep-")\(persona.id)"]

        if lean {
            // Stripped to minimal context; identity injected as static Soma text.
            args.append(contentsOf: ["-ne", "-ns", "-nc", "-nt", "--thinking", "off",
                                     "--system-prompt", voice])
            let somaFiles = Config.somaIdentityFiles
            if persona.id == "ivy", !somaFiles.isEmpty {
                for f in somaFiles { args.append(contentsOf: ["--append-system-prompt", f]) }
            } else {
                args.append(contentsOf: ["--append-system-prompt", persona.preamble])
            }
        } else {
            // Full: pi's own Soma projection + skills + tools + context. Just nudge
            // the output toward spoken form.
            args.append(contentsOf: ["--append-system-prompt", voice])
        }
        if let model, !model.isEmpty { args.append(contentsOf: ["--model", model]) }
        args.append(text)

        // Deep turns can run skills/tools — give them more headroom.
        return parseAssistant(from: try await run(args: args, timeout: lean ? 60 : 180))
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

    private func run(args: [String], timeout: TimeInterval = 60) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Config.piPath)
            proc.arguments = args
            proc.environment = Config.childEnvironment()

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Resume exactly once — whichever fires first (exit or timeout).
            let once = ResumeOnce(cont)

            // Watchdog: never let the UI spin on "thinking" forever.
            let killer = DispatchWorkItem {
                proc.terminate()
                once.resume(.failure(NSError(domain: "PiBrain", code: -1, userInfo:
                    [NSLocalizedDescriptionKey: "pi timed out after \(Int(timeout))s"])))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            proc.terminationHandler = { p in
                killer.cancel()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Surface auth/config failures instead of returning an empty turn.
                if p.terminationStatus != 0, !err.isEmpty {
                    once.resume(.failure(NSError(domain: "PiBrain", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: String(err.prefix(200))])))
                } else {
                    once.resume(.success(out))
                }
            }
            do { try proc.run() } catch { once.resume(.failure(error)) }
        }
    }
}

/// Resumes a continuation exactly once, from whichever concurrent callback fires
/// first (process exit or watchdog timeout). Lock-guarded → safe to share.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<String, Error>
    init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }
    func resume(_ r: Result<String, Error>) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { cont.resume(with: r) }
    }
}
