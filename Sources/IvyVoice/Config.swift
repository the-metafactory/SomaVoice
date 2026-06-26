import Foundation

/// Loads configuration from `~/.env` (KEY=VALUE lines), the same file the PAI
/// voice server reads. We never hardcode the ElevenLabs key.
enum Config {
    private static let env: [String: String] = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".env")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
                (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }()

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? env[key]
    }

    static var elevenLabsKey: String? { value("ELEVENLABS_API_KEY") }

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

    /// Working directory for the brain — `~/.claude` so the full PAI config
    /// (CLAUDE.md → Ivy identity, all skills) loads for every turn.
    static var brainWorkingDir: String { "\(NSHomeDirectory())/.claude" }
}
