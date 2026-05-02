import Foundation

/// The `bash` tool family.
///
/// - `runForeground` spawns a subshell, waits, returns the full result.
/// - `runBackground` spawns detached, returns a handle immediately.
/// - `output(handle:)` reads accumulated output for a background handle.
/// - `input(handle:text:)` writes text to a running background handle's stdin.
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

        var env = ProcessInfo.processInfo.environment
        let serviceKeyEnv = KeychainHelper.serviceKeyEnvironment()
        for (k, v) in serviceKeyEnv { env[k] = v }
        process.environment = env

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
        let redactor = SecretRedactor(environment: serviceKeyEnv)
        let stdoutRaw = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrRaw = String(data: stderrData, encoding: .utf8) ?? ""
        let (stdoutText, stdoutTruncated) = truncate(text: redactor.redact(stdoutRaw))
        let (stderrText, stderrTruncated) = truncate(text: redactor.redact(stderrRaw))

        return OpResult(content: jsonString([
            "success": !timedOut,
            "command": redactor.redact(command),
            "exit_code": Int(process.terminationStatus),
            "timed_out": timedOut,
            "stdout": stdoutText,
            "stderr": stderrText,
            "stdout_truncated": stdoutTruncated,
            "stderr_truncated": stderrTruncated,
            "timeout_ms": timeout,
            "description": redactor.redact(description ?? "")
        ]))
    }

    // MARK: - Background

    static func runBackground(
        command: String,
        workdir: String? = nil,
        description: String? = nil
    ) async -> OpResult {
        let redactor = SecretRedactor()
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
                "command": redactor.redact(command),
                "description": redactor.redact(description ?? ""),
                "message": "Process started in background. Use bash_manage(mode='output', handle='\(handle.id)') to peek at output, bash_manage(mode='input', handle='\(handle.id)', text='...') to send stdin, bash_manage(mode='kill', handle='\(handle.id)') to stop. You will be notified automatically when it exits."
            ]))
        } catch {
            return OpResult(content: jsonError("failed to spawn background process: \(error.localizedDescription)"))
        }
    }

    static func output(handle: String, since: Int = 0) async -> OpResult {
        guard let snapshot = await BackgroundProcessRegistry.shared.snapshot(handleId: handle) else {
            return OpResult(content: jsonError("unknown background handle: \(handle)"))
        }
        let redactor = SecretRedactor()
        let newStdout = snapshot.stdout.suffixFromByte(since)
        let (outText, outTrunc) = truncate(text: newStdout)
        let (errText, errTrunc) = truncate(text: snapshot.stderr)
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
            "command": redactor.redact(snapshot.command)
        ]
        if let code = snapshot.exitCode { payload["exit_code"] = code }
        return OpResult(content: jsonString(payload))
    }

    static func input(handle: String, text: String, appendNewline: Bool = false) async -> OpResult {
        do {
            let bytesWritten = try await BackgroundProcessRegistry.shared.writeInput(
                handleId: handle,
                text: text,
                appendNewline: appendNewline
            )
            return OpResult(content: jsonString([
                "success": true,
                "handle": handle,
                "bytes_written": bytesWritten,
                "append_newline": appendNewline,
                "message": "Input written to background process stdin. Use bash_manage(mode='output') to inspect the response."
            ]))
        } catch {
            return OpResult(content: jsonError(error.localizedDescription))
        }
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

    fileprivate struct SecretRedactor {
        private let replacements: [(secret: String, placeholder: String)]

        init(environment: [String: String] = KeychainHelper.serviceKeyEnvironment()) {
            self.replacements = environment
                .filter { !$0.value.isEmpty }
                .sorted { $0.value.count > $1.value.count }
                .map { (secret: $0.value, placeholder: "[REDACTED:\($0.key)]") }
        }

        func redact(_ text: String) -> String {
            guard !replacements.isEmpty, !text.isEmpty else { return text }
            var redacted = text
            for replacement in replacements {
                redacted = redacted.replacingOccurrences(
                    of: replacement.secret,
                    with: replacement.placeholder
                )
            }
            return redacted
        }
    }

    fileprivate static func redactServiceKeys(in text: String) -> String {
        SecretRedactor().redact(text)
    }

    private static func truncate(text: String) -> (String, Bool) {
        let data = Data(text.utf8)
        if data.count <= outputCapBytes {
            return (text, false)
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

    // MARK: - Watch

    /// A live regex subscription on a running background process. Fires synthetic
    /// `[BASH WATCH MATCH]` user messages into the conversation when matching lines
    /// appear on stdout/stderr. See `registerWatch(handle:pattern:limit:)`.
    struct Watch {
        let id: String
        let regex: NSRegularExpression
        let patternSource: String
        let limit: Int
        var matchesSoFar: Int
    }

    struct WatchMatch {
        let watchId: String
        let handle: String
        let pattern: String
        let line: String
        let stream: String           // "stdout" or "stderr"
        let matchedAt: Date
        let autoUnsubscribed: Bool   // true on limit reached, process exit, or ReDoS timeout
        let unsubscribeReason: String?
        let matchesSoFar: Int        // count including this match
        let limit: Int
    }

    enum WatchError: Error, CustomStringConvertible {
        case handleNotFound
        case processAlreadyExited
        case invalidRegex(String)

        var description: String {
            switch self {
            case .handleNotFound:       return "unknown background handle"
            case .processAlreadyExited: return "process has already exited; cannot attach a watch"
            case .invalidRegex(let m):  return "invalid regex: \(m)"
            }
        }
    }

    fileprivate final class Entry: @unchecked Sendable {
        let id: String
        let command: String
        let description: String?
        let workdir: String?
        let process: Process
        let stdin: FileHandle
        var stdout: String = ""
        var stderr: String = ""
        /// Trailing partial line not yet terminated by \n — held until a newline arrives
        /// so we only run watches against complete lines. Kept per-stream.
        var stdoutLineBuf: String = ""
        var stderrLineBuf: String = ""
        var status: Status = .running
        var exitCode: Int?
        let startedAt: Date
        var completionDelivered = false

        init(id: String, command: String, description: String?, workdir: String?, process: Process, stdin: FileHandle) {
            self.id = id
            self.command = command
            self.description = description
            self.workdir = workdir
            self.process = process
            self.stdin = stdin
            self.startedAt = Date()
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextCounter: Int = 1
    private var pendingCompletions: [Completion] = []
    private var watches: [String: [Watch]] = [:]
    private var nextWatchId: Int = 1
    private var pendingMatchEvents: [WatchMatch] = []

    /// Serial queue coordinating writes to Entry buffers from pipe readability handlers.
    private let ioQueue = DispatchQueue(label: "LocalAgent.background-process-io")

    private init() {}

    // MARK: Start

    func start(command: String, workdir: String?, description: String?) throws -> Handle {
        let id = "bash_\(nextCounter)"
        nextCounter += 1

        DebugTelemetry.log(
            .bashSpawn,
            summary: "spawn \(id): \(command.prefix(60))",
            detail: [
                "command: \(command)",
                workdir.map { "workdir: \($0)" } ?? nil,
                description.map { "description: \($0)" } ?? nil
            ].compactMap { $0 }.joined(separator: "\n")
        )

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

        var env = ProcessInfo.processInfo.environment
        let serviceKeyEnv = KeychainHelper.serviceKeyEnvironment()
        let redactor = BashTools.SecretRedactor(environment: serviceKeyEnv)
        for (k, v) in serviceKeyEnv { env[k] = v }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let entry = Entry(
            id: id,
            command: command,
            description: description,
            workdir: workdir,
            process: process,
            stdin: inPipe.fileHandleForWriting
        )

        let ioQ = self.ioQueue
        // Strong capture of `entry` is fine: the entry is retained by the registry dictionary
        // until termination, at which point we nil out the readability handlers.
        let entryId = id
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let redacted = redactor.redact(s)
            ioQ.async {
                entry.stdout.append(redacted)
                entry.stdout = redactor.redact(entry.stdout)
                let cap = BashTools.outputCapBytes * 4
                if entry.stdout.utf8.count > cap {
                    entry.stdout = String(entry.stdout.suffix(cap))
                }
                // Extract complete lines from the stream buffer and feed them to watches.
                let lines = BackgroundProcessRegistry.extractCompleteLines(
                    newChunk: s, buffer: &entry.stdoutLineBuf
                )
                if !lines.isEmpty {
                    Task {
                        await BackgroundProcessRegistry.shared.evaluateWatches(
                            handleId: entryId, stream: "stdout", lines: lines.map { redactor.redact($0) }
                        )
                    }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let redacted = redactor.redact(s)
            ioQ.async {
                entry.stderr.append(redacted)
                entry.stderr = redactor.redact(entry.stderr)
                let cap = BashTools.outputCapBytes * 4
                if entry.stderr.utf8.count > cap {
                    entry.stderr = String(entry.stderr.suffix(cap))
                }
                let lines = BackgroundProcessRegistry.extractCompleteLines(
                    newChunk: s, buffer: &entry.stderrLineBuf
                )
                if !lines.isEmpty {
                    Task {
                        await BackgroundProcessRegistry.shared.evaluateWatches(
                            handleId: entryId, stream: "stderr", lines: lines.map { redactor.redact($0) }
                        )
                    }
                }
            }
        }

        // Termination handler runs on a background thread. Drain residual data, then hop into
        // the actor to mark the entry terminated and append a completion.
        process.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            let residualOut = outPipe.fileHandleForReading.availableData
            let residualErr = errPipe.fileHandleForReading.availableData
            ioQ.async {
                if !residualOut.isEmpty, let s = String(data: residualOut, encoding: .utf8) {
                    entry.stdout.append(redactor.redact(s))
                    entry.stdout = redactor.redact(entry.stdout)
                }
                if !residualErr.isEmpty, let s = String(data: residualErr, encoding: .utf8) {
                    entry.stderr.append(redactor.redact(s))
                    entry.stderr = redactor.redact(entry.stderr)
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

    enum InputError: Error, LocalizedError {
        case handleNotFound(String)
        case processNotRunning(String)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .handleNotFound(let handle):
                return "unknown background handle: \(handle)"
            case .processNotRunning(let handle):
                return "background process is not running: \(handle)"
            case .invalidEncoding:
                return "failed to encode input as UTF-8"
            }
        }
    }

    func writeInput(handleId: String, text: String, appendNewline: Bool) throws -> Int {
        guard let e = entries[handleId] else {
            throw InputError.handleNotFound(handleId)
        }
        guard e.status == .running, e.process.isRunning else {
            throw InputError.processNotRunning(handleId)
        }
        let payload = appendNewline ? text + "\n" : text
        guard let data = payload.data(using: .utf8) else {
            throw InputError.invalidEncoding
        }
        try e.stdin.write(contentsOf: data)
        return data.count
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
        let redactor = BashTools.SecretRedactor()
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
            let safeCommand = redactor.redact(r.command)
            let cmd = safeCommand.count > 60
                ? String(safeCommand.prefix(60)) + "…"
                : safeCommand
            if let desc = r.description, !desc.isEmpty {
                lines.append("- \(r.id) [\"\(cmd)\", \(redactor.redact(desc)), running \(dur)]")
            } else {
                lines.append("- \(r.id) [\"\(cmd)\", running \(dur)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    func kill(handleId: String) async -> Bool {
        guard let e = entries[handleId] else { return false }
        guard e.status == .running else { return false }
        try? e.stdin.close()
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
        let redactor = BashTools.SecretRedactor()

        pendingCompletions.append(Completion(
            handleId: e.id,
            command: redactor.redact(e.command),
            description: e.description.map { redactor.redact($0) },
            exitCode: exitCode,
            status: statusAfter,
            stdoutTail: redactor.redact(outTail),
            stderrTail: redactor.redact(errTail),
            durationSeconds: duration
        ))

        // Tear down any still-active watches for this handle, emitting one
        // synthetic terminal match per watch so the agent knows they were
        // auto-unsubscribed because the process exited.
        if let activeWatches = watches[id], !activeWatches.isEmpty {
            for w in activeWatches {
                pendingMatchEvents.append(WatchMatch(
                    watchId: w.id,
                    handle: id,
                    pattern: redactor.redact(w.patternSource),
                    line: "[watch auto-unsubscribed — process exited]",
                    stream: "system",
                    matchedAt: Date(),
                    autoUnsubscribed: true,
                    unsubscribeReason: "process_exited",
                    matchesSoFar: w.matchesSoFar,
                    limit: w.limit
                ))
            }
            watches[id] = nil
        }
    }

    // MARK: Watch API

    func registerWatch(handle: String, pattern: String, limit: Int) -> Result<String, WatchError> {
        guard let e = entries[handle] else { return .failure(.handleNotFound) }
        if e.status != .running { return .failure(.processAlreadyExited) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return .failure(.invalidRegex(error.localizedDescription))
        }
        let clamped = max(1, min(limit, 50))
        let watchId = "watch_\(nextWatchId)"
        nextWatchId += 1
        let watch = Watch(
            id: watchId,
            regex: regex,
            patternSource: pattern,
            limit: clamped,
            matchesSoFar: 0
        )
        var arr = watches[handle] ?? []
        arr.append(watch)
        watches[handle] = arr
        return .success(watchId)
    }

    /// Drain buffered watch match events. Called from the ConversationManager poll loop.
    func drainWatchMatches() -> [WatchMatch] {
        let out = pendingMatchEvents
        pendingMatchEvents.removeAll(keepingCapacity: true)
        return out
    }

    /// Called from pipe-reader callbacks via `Task { await ... }` after a batch of
    /// fully-terminated lines has been extracted. Iterates every watch registered on
    /// `handleId` and regex-matches each line, capped at a 10ms per-match deadline
    /// (catastrophic-backtracking protection). Mutates watch state, appends
    /// `WatchMatch` events, and auto-unsubscribes when limits are reached or a match
    /// times out.
    func evaluateWatches(handleId: String, stream: String, lines: [String]) {
        guard var current = watches[handleId], !current.isEmpty else { return }
        let redactor = BashTools.SecretRedactor()
        var changed = false
        for (wIdx, w) in current.enumerated() where current.indices.contains(wIdx) {
            // Snapshot for closure capture inside the timed match.
            var watchRef = w
            for line in lines {
                let matchResult = BackgroundProcessRegistry.timedRegexMatch(
                    regex: watchRef.regex, line: line, timeoutMs: 10
                )
                switch matchResult {
                case .matched:
                    watchRef.matchesSoFar += 1
                    let reachedLimit = watchRef.matchesSoFar >= watchRef.limit
                    pendingMatchEvents.append(WatchMatch(
                        watchId: watchRef.id,
                        handle: handleId,
                        pattern: redactor.redact(watchRef.patternSource),
                        line: redactor.redact(line),
                        stream: stream,
                        matchedAt: Date(),
                        autoUnsubscribed: reachedLimit,
                        unsubscribeReason: reachedLimit ? "limit_reached" : nil,
                        matchesSoFar: watchRef.matchesSoFar,
                        limit: watchRef.limit
                    ))
                    if reachedLimit {
                        watchRef.matchesSoFar = -1  // sentinel: mark for removal
                    }
                    changed = true
                case .noMatch:
                    break
                case .timedOut:
                    print("[BackgroundProcessRegistry] watch \(watchRef.id) on \(handleId): regex timeout (>10ms) — auto-unsubscribing (ReDoS protection). pattern: \(watchRef.patternSource)")
                    pendingMatchEvents.append(WatchMatch(
                        watchId: watchRef.id,
                        handle: handleId,
                        pattern: redactor.redact(watchRef.patternSource),
                        line: "[watch auto-unsubscribed — regex match exceeded 10ms timeout (possible catastrophic backtracking)]",
                        stream: "system",
                        matchedAt: Date(),
                        autoUnsubscribed: true,
                        unsubscribeReason: "regex_timeout",
                        matchesSoFar: watchRef.matchesSoFar,
                        limit: watchRef.limit
                    ))
                    watchRef.matchesSoFar = -1  // mark for removal
                    changed = true
                }
                if watchRef.matchesSoFar < 0 { break }  // unsubscribed — stop feeding lines
            }
            current[wIdx] = watchRef
        }
        if changed {
            // Remove watches sentineled (matchesSoFar == -1).
            current.removeAll { $0.matchesSoFar < 0 }
            if current.isEmpty {
                watches[handleId] = nil
            } else {
                watches[handleId] = current
            }
        }
    }

    // MARK: Static helpers

    /// Split the incoming chunk across any pending partial line and return all newly-complete
    /// lines (without the trailing \n). Updates `buffer` with the new trailing partial.
    static func extractCompleteLines(newChunk: String, buffer: inout String) -> [String] {
        buffer.append(newChunk)
        guard buffer.contains("\n") else { return [] }
        var out: [String] = []
        // Normalize CR-LF to LF for matching purposes without losing content.
        let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        // All but the last are complete lines; the last is either "" (trailing \n) or a partial.
        for i in 0..<(parts.count - 1) {
            var line = String(parts[i])
            if line.hasSuffix("\r") { line.removeLast() }
            out.append(line)
        }
        buffer = String(parts[parts.count - 1])
        return out
    }

    enum RegexMatchOutcome {
        case matched
        case noMatch
        case timedOut
    }

    /// Runs an NSRegularExpression match against `line` with a hard wall-clock budget.
    /// NSRegularExpression has no native timeout, so we run the match on a detached
    /// task and race it against a sleep. On timeout we return `.timedOut`; the match
    /// task keeps running in the background but its result is discarded.
    ///
    /// This is belt-and-braces: for the overwhelming majority of patterns match
    /// returns in microseconds; the timeout exists purely to bound a pathologically
    /// catastrophic-backtracking pattern so it can't jam the stdout reader loop.
    static func timedRegexMatch(regex: NSRegularExpression, line: String, timeoutMs: Int) -> RegexMatchOutcome {
        // Short-circuit for the common case: Swift cannot cancel an in-flight
        // NSRegularExpression call, but we can cap wall time by racing tasks.
        let sem = DispatchSemaphore(value: 0)
        var outcome: RegexMatchOutcome = .timedOut
        let work = DispatchWorkItem {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let m = regex.firstMatch(in: line, options: [], range: range)
            outcome = (m == nil) ? .noMatch : .matched
            sem.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        if sem.wait(timeout: deadline) == .timedOut {
            // Leave outcome as .timedOut. The work item keeps running; we can't
            // forcibly abort NSRegularExpression, so we just let it finish and
            // let the result signal into the (now-unread) semaphore.
            return .timedOut
        }
        return outcome
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
