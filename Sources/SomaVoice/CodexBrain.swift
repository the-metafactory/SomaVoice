import Foundation

/// Deep tier via the `codex` CLI (`codex exec`). Soma projects Ivy into codex
/// too, so it answers as Ivy with its own skills/tools. One-shot per turn;
/// `-o <file>` captures the final message cleanly. Runs read-only sandboxed.
final class CodexBrain: Brain {
    var model: String? = nil   // nil → codex default; e.g. "gpt-5.5"

    func warmUp(_ persona: Persona) { /* one-shot; nothing to warm */ }

    func ask(_ text: String, persona: Persona) async throws -> String {
        let outFile = NSTemporaryDirectory() + "codex-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: outFile, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: outFile) }

        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "-o", outFile]
        if let model, !model.isEmpty { args.append(contentsOf: ["-m", model]) }
        // codex has no system-prompt flag — prepend the voice constraint.
        let voice = "Reply in one or two short, natural spoken sentences. No markdown, no lists, no headers — read aloud."
        args.append("\(voice)\n\n\(text)")

        _ = try await runProcess(Config.codexPath, args, cwd: NSHomeDirectory(), timeout: 180)
        let ans = (try? String(contentsOfFile: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ans.isEmpty ? "(no reply)" : ans
    }
}
