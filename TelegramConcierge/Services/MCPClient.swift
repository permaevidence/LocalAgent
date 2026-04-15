import Foundation

/// Owns one MCP-server subprocess. Serializes writes to stdin, decodes
/// newline-delimited JSON-RPC from stdout, correlates request IDs to async
/// continuations, and caches the discovered tool list from `tools/list`.
///
/// Lifecycle:
///   let c = MCPClient(config: cfg)
///   try await c.start()
///   try await c.initialize()
///   let tools = await c.listedTools
///   let result = try await c.callTool(name: "...", arguments: [:])
///   await c.shutdown()
actor MCPClient {

    // Configuration
    let serverName: String
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]

    // Subprocess
    private var process: Process?
    private var stdinHandle: FileHandle?

    // Read state
    private var readBuffer = Data()

    // Request correlation
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    // Status
    private(set) var isAlive: Bool = false
    private(set) var isInitialized: Bool = false

    // Cached tool list from `tools/list`. Populated during initialize().
    private(set) var listedTools: [MCPTool] = []

    // Capped ring of log lines from window/logMessage-equivalent notifications.
    private var logMessages: [String] = []
    private let logMessageCap = 200

    init(config: MCPServerConfig, resolvedEnvironment: [String: String]) {
        self.serverName = config.name
        self.executable = config.command
        self.arguments = config.arguments
        self.environment = resolvedEnvironment
    }

    // MARK: - Lifecycle

    func start() throws {
        guard process == nil else { return }
        let proc = Process()

        // MCP servers are usually run via `npx` or `uvx`, so we need to locate
        // the executable through PATH. MCPRegistry resolves this up-front and
        // passes the absolute path; if it's still bare, let the shell do the
        // lookup via /usr/bin/env.
        if executable.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [executable] + arguments
        }
        proc.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            Task { await self.handleTermination() }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self = self else { return }
            Task { await self.ingest(data) }
        }

        // MCP servers sometimes emit diagnostic chatter on stderr; drain
        // without surfacing so it doesn't fill the pipe buffer.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try proc.run()
        } catch {
            throw MCPClientError.spawnFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdinHandle = stdin.fileHandleForWriting
        self.isAlive = true
    }

    func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": MCPProtocol.version,
            "capabilities": [
                "roots": ["listChanged": false],
                "sampling": [String: Any]()
            ],
            "clientInfo": [
                "name": MCPProtocol.clientName,
                "version": MCPProtocol.clientVersion
            ]
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try sendNotification(method: "notifications/initialized", params: [String: Any]())
        isInitialized = true

        // Discover tools immediately so first-turn tool-list assembly is sync.
        try await refreshTools()
    }

    func shutdown() async {
        // MCP has no dedicated shutdown method — servers are expected to exit
        // on stdin close or process terminate.
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        isAlive = false
        isInitialized = false
    }

    // MARK: - Tools

    func refreshTools() async throws {
        let result = try await sendRequest(method: "tools/list", params: [String: Any]())
        let raw: [Any]
        if let arr = result["tools"] as? [Any] {
            raw = arr
        } else if let wrapped = result["__value__"] as? [Any] {
            raw = wrapped
        } else {
            raw = []
        }
        var parsed: [MCPTool] = []
        for item in raw {
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String else { continue }
            let description = dict["description"] as? String ?? ""
            let schema = (dict["inputSchema"] as? [String: Any]) ?? [:]
            parsed.append(MCPTool(
                serverName: serverName,
                toolName: name,
                description: description,
                inputSchema: schema
            ))
        }
        // Alphabetical sort for prompt-cache stability: the ToolDefinition
        // array emitted to the LLM must be byte-identical turn over turn.
        parsed.sort { $0.toolName < $1.toolName }
        listedTools = parsed
    }

    /// Call a tool by its ORIGINAL name (without the `mcp__<server>__` prefix).
    /// Returns the concatenated text of all `content` blocks in the response,
    /// or a JSON error string if the server flagged `isError`.
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        let result = try await sendRequest(method: "tools/call", params: params)

        // MCP tool-call result shape:
        //   { content: [{ type: "text"|"image"|..., text?: string, ... }], isError?: bool }
        let isError = (result["isError"] as? Bool) ?? false
        let contentBlocks = (result["content"] as? [[String: Any]]) ?? []

        var pieces: [String] = []
        for block in contentBlocks {
            let type = (block["type"] as? String) ?? ""
            switch type {
            case "text":
                if let text = block["text"] as? String {
                    pieces.append(text)
                }
            case "image":
                // Surface image blocks as a textual reference. Proper inline
                // multimodal handling would require hooking into our
                // attachment pipeline and can wait for Phase 2+.
                let mime = (block["mimeType"] as? String) ?? "image/*"
                pieces.append("[image: \(mime) — \(block["data"].map { _ in "base64" } ?? "ref")]")
            case "resource":
                if let resource = block["resource"] as? [String: Any] {
                    let uri = resource["uri"] as? String ?? "?"
                    let text = resource["text"] as? String ?? ""
                    pieces.append("[resource \(uri)]\n\(text)")
                }
            default:
                // Unknown content type — serialize the raw block for debugging.
                if let data = try? JSONSerialization.data(withJSONObject: block, options: []),
                   let str = String(data: data, encoding: .utf8) {
                    pieces.append(str)
                }
            }
        }

        let joined = pieces.joined(separator: "\n\n")
        if isError {
            return "{\"error\": \"MCP tool '\(name)' on server '\(serverName)' returned isError\", \"content\": \(jsonEscape(joined))}"
        }
        return joined.isEmpty ? "{\"success\": true}" : joined
    }

    // MARK: - Private: IO

    private func sendRequest(method: String, params: Any?) async throws -> [String: Any] {
        guard isAlive, let stdin = stdinHandle else { throw MCPClientError.notStarted }
        let id = nextRequestId
        nextRequestId += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params = params { msg["params"] = params }
        let data = try MCPFraming.encode(msg)

        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: MCPClientError.writeFailed(error.localizedDescription))
            }
        }
    }

    private func sendNotification(method: String, params: Any?) throws {
        guard isAlive, let stdin = stdinHandle else { throw MCPClientError.notStarted }
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params = params { msg["params"] = params }
        let data = try MCPFraming.encode(msg)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw MCPClientError.writeFailed(error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while true {
            do {
                guard let message = try MCPFraming.decodeNext(buffer: &readBuffer) else {
                    break
                }
                dispatch(message)
            } catch {
                // Unrecoverable decoder state — reset buffer and bail.
                readBuffer.removeAll()
                break
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            if let cont = pendingRequests.removeValue(forKey: id) {
                if let err = message["error"] as? [String: Any] {
                    let msg = err["message"] as? String ?? "MCP error"
                    cont.resume(throwing: MCPClientError.responseError(msg))
                } else if let resultDict = message["result"] as? [String: Any] {
                    cont.resume(returning: resultDict)
                } else if let resultArray = message["result"] as? [Any] {
                    cont.resume(returning: ["__value__": resultArray])
                } else {
                    cont.resume(returning: [:])
                }
            }
            return
        }

        if let method = message["method"] as? String {
            handleServerMessage(method: method, params: message["params"], id: message["id"])
        }
    }

    private func handleServerMessage(method: String, params: Any?, id: Any?) {
        switch method {
        case "notifications/message":
            if let dict = params as? [String: Any],
               let data = dict["data"] as? String {
                appendLog("[\(serverName)] \(data)")
            }
        case "notifications/tools/list_changed":
            // Server signals tool list changed. Refresh asynchronously so we
            // don't block the decoder actor. The cached ToolDefinitions will
            // be stale for one turn — acceptable for Phase 1.
            Task { try? await self.refreshTools() }
        default:
            // $/progress, server→client sampling requests, etc. Accept-and-ignore.
            _ = id
            break
        }
    }

    private func handleTermination() {
        isAlive = false
        isInitialized = false
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPClientError.terminated)
        }
        pendingRequests.removeAll()
    }

    private func appendLog(_ line: String) {
        logMessages.append(line)
        if logMessages.count > logMessageCap {
            logMessages.removeFirst(logMessages.count - logMessageCap)
        }
    }

    private func jsonEscape(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: data, encoding: .utf8),
           str.count >= 2 {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
    }

    // MARK: - Introspection

    func currentLogMessages() -> [String] { logMessages }
}
