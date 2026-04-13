import Foundation

/// Owns one language-server subprocess. Serializes writes to stdin, decodes
/// framed JSON-RPC from stdout, correlates request IDs to async continuations,
/// and collects `textDocument/publishDiagnostics` notifications by URI.
///
/// Lifecycle:
///   let c = LSPClient(executable: "/usr/bin/sourcekit-lsp")
///   try await c.start()
///   try await c.initialize(rootURI: ...)
///   try await c.didOpen(uri:..., text:..., languageId: "swift")
///   let diags = await c.diagnostics(for: uri, waitFor: 1.0)
///   await c.shutdown()
actor LSPClient {

    // Configuration
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?

    // Subprocess
    private var process: Process?
    private var stdinHandle: FileHandle?

    // Read state
    private var readBuffer = Data()

    // Request correlation
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    // Diagnostics
    private var diagnosticsByURI: [String: [LSPDiagnostic]] = [:]
    private var diagnosticsWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    // Status
    private(set) var isAlive: Bool = false
    private(set) var isInitialized: Bool = false

    // Document versions (per URI)
    private var documentVersions: [String: Int] = [:]

    // Log collection (window/logMessage, window/showMessage) — capped ring
    private var logMessages: [String] = []
    private let logMessageCap = 200

    init(executable: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    // MARK: - Lifecycle

    func start() throws {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let env = environment { proc.environment = env }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Termination: mark dead, fail pending, resolve waiters.
        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            Task { await self.handleTermination() }
        }

        // stdout → actor-isolated ingest.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self = self else { return }
            Task { await self.ingest(data) }
        }

        // stderr → drain silently (could be piped to logs later).
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try proc.run()
        } catch {
            throw LSPClientError.spawnFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdinHandle = stdin.fileHandleForWriting
        self.isAlive = true
    }

    func initialize(rootURI: URL) async throws {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let params: [String: Any] = [
            "processId": pid,
            "rootUri": rootURI.absoluteString,
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "didSave": true,
                        "willSave": false,
                        "willSaveWaitUntil": false
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": true
                    ]
                ],
                "workspace": [
                    "workspaceFolders": true
                ]
            ],
            "workspaceFolders": [
                [
                    "uri": rootURI.absoluteString,
                    "name": rootURI.lastPathComponent
                ]
            ]
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try sendNotification(method: "initialized", params: [String: Any]())
        isInitialized = true
    }

    func shutdown() async {
        if isInitialized && isAlive {
            _ = try? await sendRequest(method: "shutdown", params: nil)
            try? sendNotification(method: "exit", params: nil)
        }
        process?.terminate()
        process = nil
        stdinHandle = nil
        isAlive = false
        isInitialized = false
    }

    // MARK: - Document sync

    func didOpen(uri: URL, text: String, languageId: String) throws {
        let key = uri.absoluteString
        documentVersions[key] = 1
        try sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": key,
                "languageId": languageId,
                "version": 1,
                "text": text
            ]
        ])
    }

    func didChange(uri: URL, text: String) throws {
        let key = uri.absoluteString
        let version = (documentVersions[key] ?? 0) + 1
        documentVersions[key] = version
        // Clear any cached diagnostics — new publish will arrive.
        diagnosticsByURI.removeValue(forKey: key)
        try sendNotification(method: "textDocument/didChange", params: [
            "textDocument": ["uri": key, "version": version],
            "contentChanges": [["text": text]]
        ])
    }

    func didSave(uri: URL) throws {
        try sendNotification(method: "textDocument/didSave", params: [
            "textDocument": ["uri": uri.absoluteString]
        ])
    }

    // MARK: - Diagnostics

    /// Returns diagnostics for `uri`, waiting up to `waitFor` seconds for an
    /// asynchronous `publishDiagnostics` if none are cached yet. Returns
    /// whatever is cached (possibly empty) when the timeout elapses.
    func diagnostics(for uri: URL, waitFor timeout: TimeInterval = 1.0) async -> [LSPDiagnostic] {
        let key = uri.absoluteString
        if let cached = diagnosticsByURI[key] { return cached }
        guard isAlive else { return [] }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            diagnosticsWaiters[key, default: []].append(cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.resolveWaiters(for: key)
            }
        }
        return diagnosticsByURI[key] ?? []
    }

    // MARK: - Private: IO

    private func sendRequest(method: String, params: Any?) async throws -> [String: Any] {
        guard isAlive, let stdin = stdinHandle else { throw LSPClientError.notStarted }
        let id = nextRequestId
        nextRequestId += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params = params { msg["params"] = params }
        let data = try LSPFraming.encode(msg)

        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: LSPClientError.writeFailed(error.localizedDescription))
            }
        }
    }

    private func sendNotification(method: String, params: Any?) throws {
        guard isAlive, let stdin = stdinHandle else { throw LSPClientError.notStarted }
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params = params { msg["params"] = params }
        let data = try LSPFraming.encode(msg)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw LSPClientError.writeFailed(error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while true {
            do {
                guard let message = try LSPFraming.decodeNext(buffer: &readBuffer) else {
                    break
                }
                dispatch(message)
            } catch {
                // Unrecoverable parse state — reset buffer and stop.
                readBuffer.removeAll()
                break
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            // Response to our request.
            if let cont = pendingRequests.removeValue(forKey: id) {
                if let err = message["error"] as? [String: Any] {
                    let msg = err["message"] as? String ?? "LSP error"
                    cont.resume(throwing: LSPClientError.responseError(msg))
                } else {
                    let result = (message["result"] as? [String: Any]) ?? [:]
                    cont.resume(returning: result)
                }
            }
            return
        }
        if let method = message["method"] as? String {
            // Server → client notification or request. We handle notifications
            // and accept-and-ignore server requests (no response sent).
            handleServerMessage(method: method, params: message["params"], id: message["id"])
        }
    }

    private func handleServerMessage(method: String, params: Any?, id: Any?) {
        switch method {
        case "textDocument/publishDiagnostics":
            guard let dict = params as? [String: Any],
                  let uri = dict["uri"] as? String,
                  let raw = dict["diagnostics"] as? [[String: Any]] else { return }
            let diags = raw.compactMap(LSPDiagnostic.from(raw:))
            diagnosticsByURI[uri] = diags
            resolveWaiters(for: uri)

        case "window/logMessage", "window/showMessage":
            if let dict = params as? [String: Any],
               let msg = dict["message"] as? String {
                appendLog("[\(method)] \(msg)")
            }

        default:
            // $/progress, client/registerCapability, workspace/configuration, etc.
            // Accept and ignore for MVP. If the server sent a request (id present),
            // a spec-strict server could hang waiting for a response; in practice
            // sourcekit-lsp / tsserver / pylsp tolerate this for the handful of
            // MVP-scope methods. Revisit if a real server misbehaves.
            _ = id
            break
        }
    }

    private func resolveWaiters(for uri: String) {
        guard let waiters = diagnosticsWaiters.removeValue(forKey: uri) else { return }
        for w in waiters { w.resume() }
    }

    private func handleTermination() {
        isAlive = false
        isInitialized = false
        for (_, cont) in pendingRequests {
            cont.resume(throwing: LSPClientError.terminated)
        }
        pendingRequests.removeAll()
        for (_, waiters) in diagnosticsWaiters {
            for w in waiters { w.resume() }
        }
        diagnosticsWaiters.removeAll()
    }

    private func appendLog(_ line: String) {
        logMessages.append(line)
        if logMessages.count > logMessageCap {
            logMessages.removeFirst(logMessages.count - logMessageCap)
        }
    }

    // MARK: - Introspection (for tests / future registry)

    func currentLogMessages() -> [String] { logMessages }
    func cachedDiagnostics(for uri: URL) -> [LSPDiagnostic]? {
        diagnosticsByURI[uri.absoluteString]
    }
}
