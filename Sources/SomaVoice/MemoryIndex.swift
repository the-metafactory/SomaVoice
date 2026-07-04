import Foundation

/// Fast, read-only memory lookup for the reflex tier's `recall` tool. Greps the
/// markdown memory trees (PAI auto-memory, Soma memory + profile) via ripgrep
/// and returns compact snippets — no embeddings, no write access. The deep tier
/// gets real memory (read+write) through its skills; this is just enough for the
/// fast tier to answer "what do we know about X" without escalating.
struct MemoryIndex {
    private var dirs: [String] {
        [
            "\(NSHomeDirectory())/.claude/projects/-Users-fischer--claude/memory",
            "\(NSHomeDirectory())/.soma/memory",
            "\(NSHomeDirectory())/.soma/profile",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Common words that would otherwise dominate an OR-pattern and surface
    /// irrelevant files. Distinctive nouns (project names, people) are kept.
    private static let stop: Set<String> = [
        "the", "and", "for", "with", "what", "whats", "this", "that", "about",
        "relate", "related", "thing", "things", "working", "work", "have", "has",
        "how", "does", "did", "you", "your", "from", "into", "was", "were", "are",
        "can", "could", "would", "should", "its", "but", "not", "who", "which",
        "when", "where", "why", "then", "than", "them", "they", "our", "out",
        "get", "got", "want", "need", "know", "tell", "show", "look", "looking",
        "any", "all", "some", "more", "much", "very", "just", "like", "about",
    ]

    /// Return up to ~1500 chars of matching snippets for `query`, or a miss note.
    func search(_ query: String) async -> String {
        var words = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.stop.contains($0) }
        // If stopword filtering emptied it, fall back to the raw words.
        if words.isEmpty {
            words = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        }
        let picked = Array(words.prefix(6))
        guard !picked.isEmpty, !dirs.isEmpty else { return "No memory matches." }
        let pattern = picked.joined(separator: "|")

        let rg = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "rg"

        // --hidden --no-ignore: memory lives under the hidden ~/.claude tree and
        // may be gitignored; without these rg silently skips it.
        let out = await runCapture(rg, [
            "-i", "--hidden", "--no-ignore", "--no-heading", "--with-filename",
            "-m", "4", "-e", pattern,
        ] + dirs)

        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No memory matches for \(query)." }
        return String(trimmed.prefix(1500))
    }

    private func runCapture(_ exec: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exec)
            proc.arguments = args
            proc.environment = Config.childEnvironment()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            proc.terminationHandler = { _ in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: d, encoding: .utf8) ?? "")
            }
            do { try proc.run() } catch { cont.resume(returning: "") }
        }
    }
}
