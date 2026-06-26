import Foundation

/// Loads configuration from `~/.env` (KEY=VALUE lines), the same file the PAI
/// voice server reads. We never hardcode the ElevenLabs key.
enum Config {
    // Read both ~/.env and ~/.zshenv. A GUI .app launched via `open` does NOT
    // inherit the shell environment, so keys living in ~/.zshenv (e.g.
    // OPENROUTER_API_KEY) would otherwise be invisible. ~/.env wins on conflict.
    private static let env: [String: String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [String: String] = [:]
        for name in [".zshenv", ".env"] {   // .env last → wins on overlap
            guard let text = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            for raw in text.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
                    (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                out[key] = val
            }
        }
        return out
    }()

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? env[key]
    }

    static var elevenLabsKey: String? { value("ELEVENLABS_API_KEY") }

    static var anthropicKey: String? { value("ANTHROPIC_API_KEY") }

    static var openRouterKey: String? { value("OPENROUTER_API_KEY") }

    /// Default (Ivy) voice id — `~/.env` first, then DA_IDENTITY fallback.
    static var ivyVoiceId: String {
        value("ELEVENLABS_VOICE_ID") ?? "s3TPKV1kjDlVtZbl4Ksh"
    }

    /// Path to the `claude` CLI binary.
    static var claudePath: String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "claude"
    }

    /// Path to the `pi` (pi.dev) CLI binary.
    static var piPath: String {
        let candidates = ["/opt/homebrew/bin/pi", "/usr/local/bin/pi", "\(NSHomeDirectory())/.local/bin/pi"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "pi"
    }

    /// Working directory for the brain — `~/.claude` so the full PAI config
    /// (CLAUDE.md → Ivy identity, all skills) loads for every turn.
    static var brainWorkingDir: String { "\(NSHomeDirectory())/.claude" }
}
