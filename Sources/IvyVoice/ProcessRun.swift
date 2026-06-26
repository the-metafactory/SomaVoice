import Foundation

/// Run a subprocess to completion, draining stdout/stderr CONTINUOUSLY (so a
/// chatty child never deadlocks on a full pipe), with a hard timeout. Returns
/// stdout on success; throws on spawn failure, nonzero-exit-with-stderr, or
/// timeout. Shared by CodexBrain (and available to others).
func runProcess(_ exec: String, _ args: [String], cwd: String? = nil,
                timeout: TimeInterval) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        proc.environment = Config.childEnvironment()

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let drain = ProcDrain()
        outPipe.fileHandleForReading.readabilityHandler = { drain.appendOut($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { drain.appendErr($0.availableData) }

        let once = ResumeGuard(cont)
        let killer = DispatchWorkItem {
            proc.terminate()
            once.resume(.failure(NSError(domain: "Proc", code: -1, userInfo:
                [NSLocalizedDescriptionKey: "timed out after \(Int(timeout))s"])))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        proc.terminationHandler = { p in
            killer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let (out, err) = drain.finish(outPipe, errPipe)
            if p.terminationStatus != 0, out.isEmpty, !err.isEmpty {
                once.resume(.failure(NSError(domain: "Proc", code: Int(p.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(err.prefix(200))])))
            } else {
                once.resume(.success(out))
            }
        }
        do { try proc.run() } catch { once.resume(.failure(error)) }
    }
}

private final class ProcDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func appendOut(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); err.append(d); lock.unlock() }
    func finish(_ o: Pipe, _ e: Pipe) -> (String, String) {
        let oR = o.fileHandleForReading.readDataToEndOfFile()
        let eR = e.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); out.append(oR); err.append(eR)
        let os = String(data: out, encoding: .utf8) ?? ""
        let es = String(data: err, encoding: .utf8) ?? ""
        lock.unlock()
        return (os, es)
    }
}

private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<String, Error>
    init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }
    func resume(_ r: Result<String, Error>) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { cont.resume(with: r) }
    }
}
