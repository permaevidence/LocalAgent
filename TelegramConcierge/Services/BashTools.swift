import Foundation

/// The `bash` tool family.
///
/// - `runForeground` spawns a subshell, waits, returns the full result.
/// - `runBackground` spawns detached, returns a handle immediately.
/// - `output(handle:)` reads accumulated output for a background handle.
/// - `kill(handle:)` terminates a background handle (SIGTERM then SIGKILL).
///
/// When a background process exits, ConversationManager polls
/// `BackgroundProcessRegistry.shared.drainCompletions()` and injects a synthetic user
/// message so the agent can react to the completion.
enum BashTools {

    static let foregroundDefaultTimeoutMs: Int = 120_000
    static let foregroundMaxTimeoutMs: Int = 600_000
    static let outputCapBytes = 30_000

    struct OpResult {
        let content: String
    }

    // MARK: - Foreground

    static func runForeground(
        command: String,
        timeoutMs: Int? = nil,
        workdir: String? = nil,
        description: String? = nil
    ) async -> OpResult {
        let timeout = min(max(timeoutMs ?? foregroundDefaultTimeoutMs, 100), foregroundMaxTimeoutMs)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let workdir {
            let expanded = FilesystemTools.normalizePath(workdir)
            guard FileManager.default.fileExists(atPath: expanded) else {
                return OpResult(content: jsonError("workdir does not exist: \(expanded)"))
            }
            process.currentDirectoryURL = URL(fileURLWithPath: expanded)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return OpResult(content: jsonError("failed to spawn subprocess: \(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let stdoutData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let (stdoutText, stdoutTruncated) = truncate(data: stdoutData)
        let (stderrText, stderrTruncated) = truncate(data: stderrData)

        return OpResult(content: jsonString([
            "success": !timedOut,
            "command": command,
            "exit_code": Int(process.terminationStatus),
            "timed_out": timedOut,
            "stdout": stdoutText,
            "stderr": stderrText,
            "stdout_truncated": stdoutTruncated,
            "stderr_truncated": stderrTruncated,
            "timeout_ms": timeout,
            "description": description ?? ""
        ]))
    }

    // MARK: - Background

    static func runBackground(
        command: String,
        workdir: String? = nil,
        description: String? = nil
    ) async -> OpResult {
        do {
            let handle = try await BackgroundProcessRegistry.shared.start(
                command: command,
                workdir: workdir,
                description: description
            )
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle.id,
                "pid": handle.pid,
                "status": "running",
                "command": command,
                "description": description ?? "",
                "message": "Process started in background. Use bash_output(\"\(handle.id)\") to peek at output, bash_kill(\"\(handle.id)\") to stop. You will be notified automatically when it exits."
            ]))
        } catch {
            return OpResult(content: jsonError("failed to spawn background process: \(error.localizedDescription)"))
        }
    }

    static func output(handle: String, since: Int = 0) async -> OpResult {
        guard let snapshot = await BackgroundProcessRegistry.shared.snapshot(handleId: handle) else {
            return OpResult(content: jsonError("unknown background handle: \(handle)"))
        }
        let newStdout = snapshot.stdout.suffixFromByte(since)
        let (outText, outTrunc) = truncate(data: Data(newStdout.utf8))
        let (errText, errTrunc) = truncate(data: Data(snapshot.stderr.utf8))
        var payload: [String: Any] = [
            "success": true,
            "handle": handle,
            "status": snapshot.status.rawValue,
            "stdout": outText,
            "stderr": errText,
            "stdout_truncated": outTrunc,
            "stderr_truncated": errTrunc,
            "stdout_total_bytes": snapshot.stdout.utf8.count,
            "running_for_seconds": Int(snapshot.runningFor),
            "command": snapshot.command
        ]
        if let code = snapshot.exitCode { payload["exit_code"] = code }
        return OpResult(content: jsonString(payload))
    }

    static func kill(handle: String) async -> OpResult {
        let ok = await BackgroundProcessRegistry.shared.kill(handleId: handle)
        if ok {
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle,
                "message": "Sent SIGTERM (then SIGKILL if still running)."
            ]))
        }
        return OpResult(content: jsonError("unknown or already-stopped handle: \(handle)"))
    }

    // MARK: - Helpers

    private static func truncate(data: Data) -> (String, Bool) {
        if data.count <= outputCapBytes {
            return (String(data: data, encoding: .utf8) ?? "", false)
        }
        let trimmed = data.prefix(outputCapBytes)
        let text = (String(data: trimmed, encoding: .utf8) ?? "") + "\n… [output capped at \(outputCapBytes) bytes]"
        return (text, true)
    }

    private static func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}

// MARK: - Background process registry

/// Owns all currently-running background processes started via `bash(run_in_background: true)`.
/// ConversationManager calls `drainCompletions()` once per poll cycle to pull exit events and
/// inject them as synthetic user messages, triggering a new agent turn.
actor BackgroundProcessRegistry {
    static let shared = BackgroundProcessRegistry()

    struct Handle {
        let id: String
        let pid: Int32
    }

    enum Status: String {
        case running
        case exited
        case killed
        case crashed
    }

    struct Snapshot {
        let id: String
        let command: String
        let description: String?
        let stdout: String
        let stderr: String
        let status: Status
        let exitCode: Int?
        let runningFor: TimeInterval
        let workdir: String?
    }

    struct Completion {
        let handleId: String
        let command: String
        let description: String?
        let exitCode: Int32
        let status: Status
        let stdoutTail: String
        let stderrTail: String
        let durationSeconds: Int
    }

    fileprivate final class Entry: @unchecked Sendable {
        let id: String
        let command: String
        let description: String?
        let workdir: String?
        let process: Process
        var stdout: String = ""
        var stderr: String = ""
        var status: Status = .running
        var exitCode: Int?
        let startedAt: Date
        var completionDelivered = false

        init(id: String, command: String, description: String?, workdir: String?, process: Process) {
            self.id = id
            self.command = command
            self.description = description
            self.workdir = workdir
            self.process = process
            self.startedAt = Date()
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextCounter: Int = 1
    private var pendingCompletions: [Completion] = []

    /// Serial queue coordinating writes to Entry buffers from pipe readability handlers.
    private let ioQueue = DispatchQueue(label: "LocalAgent.background-process-io")

    private init() {}

    // MARK: Start

    func start(command: String, workdir: String?, description: String?) throws -> Handle {
        let id = "bash_\(nextCounter)"
        nextCounter += 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let workdir {
            let expanded = FilesystemTools.normalizePath(workdir)
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw NSError(domain: "BackgroundProcessRegistry", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "workdir does not exist: \(expanded)"])
            }
            process.currentDirectoryURL = URL(fileURLWithPath: expanded)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let entry = Entry(id: id, command: command, description: description, workdir: workdir, process: process)

        let ioQ = self.ioQueue
        // Strong capture of `entry` is fine: the entry is retained by the registry dictionary
        // until termination, at which point we nil out the readability handlers.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            ioQ.async {
                entry.stdout.append(s)
                let cap = BashTools.outputCapBytes * 4
                if entry.stdout.utf8.count > cap {
                    entry.stdout = String(entry.stdout.suffix(cap))
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            ioQ.async {
                entry.stderr.append(s)
                let cap = BashTools.outputCapBytes * 4
                if entry.stderr.utf8.count > cap {
                    entry.stderr = String(entry.stderr.suffix(cap))
                }
            }
        }

        // Termination handler runs on a background thread. Drain residual data, then hop into
        // the actor to mark the entry terminated and append a completion.
        process.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let residualOut = outPipe.fileHandleForReading.availableData
            let residualErr = errPipe.fileHandleForReading.availableData
            ioQ.async {
                if !residualOut.isEmpty, let s = String(data: residualOut, encoding: .utf8) {
                    entry.stdout.append(s)
                }
                if !residualErr.isEmpty, let s = String(data: residualErr, encoding: .utf8) {
                    entry.stderr.append(s)
                }
                let code = proc.terminationStatus
                let reason = proc.terminationReason
                Task {
                    await BackgroundProcessRegistry.shared.markTerminated(id: entry.id, exitCode: code, reason: reason)
                }
            }
        }

        try process.run()
        entries[id] = entry
        return Handle(id: id, pid: process.processIdentifier)
    }

    // MARK: Inspect / mutate

    func snapshot(handleId: String) -> Snapshot? {
        guard let e = entries[handleId] else { return nil }
        var out = ""
        var err = ""
        let sema = DispatchSemaphore(value: 0)
        ioQueue.async {
            out = e.stdout
            err = e.stderr
            sema.signal()
        }
        sema.wait()
        return Snapshot(
            id: e.id,
            command: e.command,
            description: e.description,
            stdout: out,
            stderr: err,
            status: e.status,
            exitCode: e.exitCode,
            runningFor: Date().timeIntervalSince(e.startedAt),
            workdir: e.workdir
        )
    }

    /// Compact summary of running processes, used by the system prompt.
    func liveSummary() -> [(id: String, command: String, description: String?, runningFor: Int)] {
        entries.values
            .filter { $0.status == .running }
            .sorted { $0.startedAt < $1.startedAt }
            .map { e in
                (id: e.id,
                 command: e.command,
                 description: e.description,
                 runningFor: Int(Date().timeIntervalSince(e.startedAt)))
            }
    }

    /// Pre-formatted multi-line string summary suitable for direct injection
    /// into the system prompt. Returns `nil` when there are no running bash
    /// processes so the section can be skipped entirely.
    func liveSummaryText() -> String? {
        let rows = liveSummary()
        guard !rows.isEmpty else { return nil }
        var lines: [String] = ["Running background bash:"]
        for r in rows {
            let secs = r.runningFor
            let dur: String
            if secs < 60 {
                dur = "\(secs)s"
            } else {
                let m = secs / 60
                let s = secs % 60
                dur = "\(m)m \(s)s"
            }
            let cmd = r.command.count > 60
                ? String(r.command.prefix(60)) + "…"
                : r.command
            if let desc = r.description, !desc.isEmpty {
                lines.append("- \(r.id) [\"\(cmd)\", \(desc), running \(dur)]")
            } else {
                lines.append("- \(r.id) [\"\(cmd)\", running \(dur)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    func kill(handleId: String) async -> Bool {
        guard let e = entries[handleId] else { return false }
        guard e.status == .running else { return false }
        e.process.terminate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if e.process.isRunning {
            _ = Darwin.kill(e.process.processIdentifier, SIGKILL)
        }
        e.status = .killed
        return true
    }

    private func markTerminated(id: String, exitCode: Int32, reason: Process.TerminationReason) {
        guard let e = entries[id] else { return }
        // Don't double-deliver if already processed.
        if e.completionDelivered { return }

        let statusAfter: Status
        switch reason {
        case .exit:
            statusAfter = (e.status == .killed) ? .killed : .exited
        case .uncaughtSignal:
            statusAfter = (e.status == .killed) ? .killed : .crashed
        @unknown default:
            statusAfter = (e.status == .killed) ? .killed : .exited
        }
        e.status = statusAfter
        e.exitCode = Int(exitCode)
        e.completionDelivered = true

        let duration = Int(Date().timeIntervalSince(e.startedAt))
        let tailBytes = 4000
        let outTail: String = e.stdout.utf8.count <= tailBytes
            ? e.stdout
            : "…[earlier output truncated]\n" + String(e.stdout.suffix(tailBytes))
        let errTail: String = e.stderr.utf8.count <= tailBytes
            ? e.stderr
            : "…[earlier output truncated]\n" + String(e.stderr.suffix(tailBytes))

        pendingCompletions.append(Completion(
            handleId: e.id,
            command: e.command,
            description: e.description,
            exitCode: exitCode,
            status: statusAfter,
            stdoutTail: outTail,
            stderrTail: errTail,
            durationSeconds: duration
        ))
    }

    /// Called by the ConversationManager poll loop. Returns and clears pending completions.
    func drainCompletions() -> [Completion] {
        let out = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: true)
        return out
    }

    /// Terminate all background processes. Called on app shutdown.
    func terminateAll() async {
        for entry in entries.values where entry.status == .running {
            entry.process.terminate()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        for entry in entries.values where entry.process.isRunning {
            _ = Darwin.kill(entry.process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - String utility

private extension String {
    /// Return a suffix starting at the given UTF-8 byte offset. Returns "" if offset is beyond end.
    func suffixFromByte(_ offset: Int) -> String {
        let bytes = Array(self.utf8)
        guard offset >= 0, offset < bytes.count else { return "" }
        return String(bytes: bytes[offset..<bytes.count], encoding: .utf8) ?? ""
    }
}
