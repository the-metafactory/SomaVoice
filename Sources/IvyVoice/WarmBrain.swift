import Foundation

/// Warm brain: ONE long-lived `claude` process per persona, driven over stdin in
/// streaming-JSON mode. The expensive part of a turn — process spawn, PAI hooks,
/// MCP servers, skill discovery (~16s measured) — happens ONCE when the process
/// starts. Every turn after that is just inference (~2-4s), because the session
/// stays resident and keeps its context, skills, and personality loaded.
///
/// This is the warm path that still gives full Claude Code (skills + Ivy
/// personality) — unlike a raw Messages-API loop, which would be faster still
/// but would drop the skills. It uses subscription auth; no API key needed.
final class BrainSession {
    private let persona: Persona
    private var proc: Process?
    private var stdinHandle: FileHandle?
    private let lock = NSLock()
    private var pending: ((Result<String, Error>) -> Void)?
    private var assembled = ""
    private var lineBuffer = Data()

    init(persona: Persona) { self.persona = persona }

    var isRunning: Bool { proc?.isRunning ?? false }

    /// Spawn the resident process and start reading its output. Idempotent.
    func start() {
        guard proc == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.claudePath)
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--append-system-prompt", persona.preamble,
        ]
        p.currentDirectoryURL = URL(fileURLWithPath: Config.brainWorkingDir)
        var env = ProcessInfo.processInfo.environment
        let extra = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in self?.fail(BrainError.processEnded) }

        do { try p.run() } catch { fail(error); return }
        proc = p
        stdinHandle = inPipe.fileHandleForWriting
    }

    /// Send one turn; resolves when the session emits its `result` event.
    func ask(_ text: String) async throws -> String {
        start()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if pending != nil {
                lock.unlock()
                cont.resume(throwing: BrainError.busy)
                return
            }
            pending = { cont.resume(with: $0) }
            assembled = ""
            lock.unlock()
            send(text)
        }
    }

    func stop() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
        stdinHandle = nil
    }

    // MARK: - internals

    private func send(_ text: String) {
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              var line = String(data: data, encoding: .utf8) else {
            fail(BrainError.encode); return
        }
        line += "\n"
        do { try stdinHandle?.write(contentsOf: Data(line.utf8)) }
        catch { fail(error) }
    }

    /// Accumulate bytes, split into JSON lines, react to each event.
    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<nl]
            lineBuffer.removeSubrange(...nl)
            guard !lineData.isEmpty,
                  let ev = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }
            handle(ev)
        }
    }

    private func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "assistant":
            // Accumulate streamed assistant text as a fallback for the result.
            if let message = ev["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let t = block["text"] as? String { assembled += t }
                }
            }
        case "result":
            let text = (ev["result"] as? String) ?? assembled
            succeed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            break
        }
    }

    private func succeed(_ text: String) {
        lock.lock(); let cb = pending; pending = nil; lock.unlock()
        cb?(.success(text.isEmpty ? "(no reply)" : text))
    }

    private func fail(_ error: Error) {
        lock.lock(); let cb = pending; pending = nil; lock.unlock()
        cb?(.failure(error))
    }
}

enum BrainError: LocalizedError {
    case busy, encode, processEnded
    var errorDescription: String? {
        switch self {
        case .busy: return "Brain is still answering the previous turn"
        case .encode: return "Failed to encode turn"
        case .processEnded: return "Claude session ended unexpectedly"
        }
    }
}

/// Holds one warm session per persona so switching being keeps separate,
/// already-warm threads.
final class WarmBrain {
    private var sessions: [String: BrainSession] = [:]

    private func session(for persona: Persona) -> BrainSession {
        if let s = sessions[persona.id] { return s }
        let s = BrainSession(persona: persona)
        sessions[persona.id] = s
        return s
    }

    /// Pre-spawn a persona's process so the ~16s startup happens before the
    /// first turn, not during it.
    func warmUp(_ persona: Persona) { session(for: persona).start() }

    func ask(_ text: String, persona: Persona) async throws -> String {
        try await session(for: persona).ask(text)
    }
}
