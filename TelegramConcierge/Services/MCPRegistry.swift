import Foundation

/// Singleton actor: owns every connected MCP client, reads `~/LocalAgent/mcp.json`,
/// resolves Keychain-backed secrets into the spawn environment, bootstraps
/// servers on first use, caches the merged tool list as native
/// `ToolDefinition`s for the LLM tool block, and dispatches `tools/call`
/// requests from `ToolExecutor`.
///
/// Phase 1 behavior: lazy-but-eager. The first call to `allToolDefinitions()`
/// in a session triggers `bootstrap()` which spawns every configured server
/// in parallel, waits for each handshake to complete (or fail), and caches
/// the result for the lifetime of the session. Subsequent calls are O(1).
///
/// Tool-list stability is preserved by:
///   - alphabetical sort inside each client's refreshTools()
///   - alphabetical sort of server names when merging
///   - never re-spawning mid-session unless a client actually crashed
actor MCPRegistry {

    public static let shared = MCPRegistry()

    private struct Entry {
        let client: MCPClient
        let config: MCPServerConfig
        var failed: Bool
        var failureReason: String?
    }

    private var entries: [String: Entry] = [:]   // key = server name
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap: Bool = false

    private init() {}

    // MARK: - Public API

    /// Returns every MCP tool converted to a native `ToolDefinition`, ready
    /// to append to the LLM tool block. Sorted deterministically by prefixed
    /// name (`mcp__<server>__<tool>`) so the output is byte-stable across
    /// turns — critical for prompt-cache hits.
    ///
    /// Triggers bootstrap on first call. Later calls reuse the cached list.
    /// Per-agent filtering (including always vs deferred) is handled by
    /// `MCPAgentRouting`, not here.
    func allToolDefinitions() async -> [ToolDefinition] {
        await ensureBootstrapped()
        var combined: [MCPTool] = []
        for entry in entries.values where !entry.failed {
            let tools = await entry.client.listedTools
            combined.append(contentsOf: tools)
        }
        combined.sort { $0.prefixedName < $1.prefixedName }
        return combined.map(Self.convertToToolDefinition)
    }

    /// Compact summaries for the specified server names. Each entry includes:
    /// server name, description (user-provided or auto), and tool count.
    /// Used to inject lightweight hints into the system prompt for deferred MCPs.
    /// Which servers are deferred is decided by MCPAgentRouting, not here.
    func serverSummaries(for serverNames: Set<String>) async -> [(name: String, description: String, toolCount: Int)] {
        await ensureBootstrapped()
        var out: [(String, String, Int)] = []
        for name in serverNames {
            guard let entry = entries[name], !entry.failed else { continue }
            let tools = await entry.client.listedTools
            guard !tools.isEmpty else { continue }
            let desc = entry.config.description ?? Self.autoDescription(tools: tools)
            out.append((name, desc, tools.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Returns a formatted text block describing every tool on `serverName`,
    /// including parameter schemas. Intended as the result of `tool_search`.
    func toolSchemasForServer(_ serverName: String) async -> String? {
        await ensureBootstrapped()
        guard let entry = entries[serverName], !entry.failed else { return nil }
        let tools = await entry.client.listedTools
        guard !tools.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("MCP server '\(serverName)' — \(tools.count) tools:")
        lines.append("")
        for tool in tools.sorted(by: { $0.toolName < $1.toolName }) {
            lines.append("## \(tool.toolName)")
            if !tool.description.isEmpty {
                lines.append(tool.description)
            }
            let props = (tool.inputSchema["properties"] as? [String: Any]) ?? [:]
            let required = Set((tool.inputSchema["required"] as? [String]) ?? [])
            if !props.isEmpty {
                lines.append("Parameters:")
                for key in props.keys.sorted() {
                    guard let dict = props[key] as? [String: Any] else { continue }
                    let type = (dict["type"] as? String) ?? "string"
                    let desc = (dict["description"] as? String) ?? ""
                    let req = required.contains(key) ? " (required)" : ""
                    var enumNote = ""
                    if let vals = dict["enum"] as? [Any] {
                        enumNote = " — enum: \(vals.map { "\($0)" }.joined(separator: ", "))"
                    }
                    lines.append("  - \(key): \(type)\(req)\(enumNote)\(desc.isEmpty ? "" : " — \(desc)")")
                }
            } else {
                lines.append("Parameters: none")
            }
            lines.append("")
        }
        lines.append("Use mcp_call(server: \"\(serverName)\", tool: \"<tool_name>\", arguments: {...}) to invoke.")
        return lines.joined(separator: "\n")
    }

    /// Auto-generate a short description from tool names (fallback when user
    /// hasn't provided one). Shows up to 5 names, then "and N more".
    private static func autoDescription(tools: [MCPTool]) -> String {
        let names = tools.map(\.toolName).sorted()
        if names.count <= 5 {
            return "Provides: \(names.joined(separator: ", "))"
        }
        let first5 = names.prefix(5).joined(separator: ", ")
        return "Provides: \(first5), and \(names.count - 5) more"
    }

    /// Dispatch a tool call from `ToolExecutor`. The argument is the prefixed
    /// name (`mcp__<server>__<tool>`) surfaced to the LLM. Routes to the
    /// right client and returns the textual result (or a JSON error string).
    func callTool(prefixedName: String, argumentsJSON: String) async -> String {
        await ensureBootstrapped()
        guard let (serverName, toolName) = Self.splitPrefixedName(prefixedName) else {
            return jsonError("Malformed MCP tool name '\(prefixedName)'")
        }
        guard let entry = entries[serverName], !entry.failed else {
            let reason = entries[serverName]?.failureReason ?? "not installed or not configured"
            return jsonError("MCP server '\(serverName)' unavailable (\(reason))")
        }

        // Parse arguments. Empty string → empty dict. Anything else must be a
        // JSON object.
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String: Any]
        if trimmed.isEmpty {
            args = [:]
        } else if let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            return jsonError("MCP tool '\(prefixedName)' expected a JSON object for arguments")
        }

        do {
            return try await entry.client.callTool(name: toolName, arguments: args)
        } catch {
            return jsonError("MCP tool '\(prefixedName)' failed: \(error)")
        }
    }

    /// Status snapshot for settings UI / telemetry. Reports every configured
    /// server — connected, disabled, or failed.
    func status() async -> [(name: String, connected: Bool, failed: Bool, reason: String?, toolCount: Int)] {
        await ensureBootstrapped()
        var out: [(String, Bool, Bool, String?, Int)] = []
        for (name, entry) in entries {
            let alive = await entry.client.isAlive
            let tools = await entry.client.listedTools
            out.append((name, alive, entry.failed, entry.failureReason, tools.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Kill every spawned server. Called on app termination.
    func shutdownAll() async {
        for entry in entries.values {
            await entry.client.shutdown()
        }
        entries.removeAll()
        didBootstrap = false
        bootstrapTask = nil
    }

    /// Tear down every running client and re-bootstrap from the current
    /// on-disk config. Called by Settings UI after mcp.json is rewritten so
    /// changes take effect without requiring an app restart.
    func reloadFromDisk() async {
        for entry in entries.values {
            await entry.client.shutdown()
        }
        entries.removeAll()
        didBootstrap = false
        bootstrapTask = nil
        await ensureBootstrapped()
    }

    // MARK: - Config persistence (for Settings UI)

    /// Public wrapper around the private on-disk loader. Used by the MCPs
    /// settings panel to render the current configuration.
    nonisolated static func loadConfigsFromDisk() -> [MCPServerConfig] {
        loadConfigs()
    }

    /// Write the full mcp.json atomically. Sorted by server name for
    /// reviewable diffs. Does NOT restart running clients — call
    /// `await MCPRegistry.shared.reloadFromDisk()` afterwards if the changes
    /// need to take effect immediately.
    nonisolated static func saveConfigsToDisk(_ configs: [MCPServerConfig]) throws {
        var servers: [String: Any] = [:]
        for cfg in configs.sorted(by: { $0.name < $1.name }) {
            var dict: [String: Any] = [
                "command": cfg.command,
                "args": cfg.arguments
            ]
            if !cfg.environment.isEmpty { dict["env"] = cfg.environment }
            if cfg.disabled { dict["disabled"] = true }
            if !cfg.secretRefs.isEmpty { dict["secretRefs"] = cfg.secretRefs }
            if let desc = cfg.description, !desc.isEmpty { dict["description"] = desc }
            servers[cfg.name] = dict
        }
        let root: [String: Any] = ["mcpServers": servers]
        let url = mcpConfigURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    public static func mcpConfigPath() -> String {
        mcpConfigURL().path
    }

    // MARK: - Bootstrap

    private func ensureBootstrapped() async {
        if didBootstrap { return }
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { await self.bootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func bootstrap() async {
        defer {
            didBootstrap = true
            bootstrapTask = nil
        }
        let configs = Self.loadConfigs()
        guard !configs.isEmpty else { return }

        // Spawn in parallel so one slow server (npx cold start) doesn't block
        // the others. Each task populates a local entry on success or a
        // failure marker on error.
        await withTaskGroup(of: (String, Entry).self) { group in
            for cfg in configs {
                group.addTask {
                    await Self.spawnOne(config: cfg)
                }
            }
            for await (name, entry) in group {
                entries[name] = entry
            }
        }
    }

    private static func spawnOne(config: MCPServerConfig) async -> (String, Entry) {
        if config.disabled {
            let client = MCPClient(config: config, resolvedEnvironment: [:])
            return (config.name, Entry(client: client, config: config, failed: true, failureReason: "disabled in mcp.json"))
        }

        let env = resolveEnvironment(for: config)
        let resolved = resolveExecutable(config: config)
        let client = MCPClient(config: resolved, resolvedEnvironment: env)

        do {
            try await client.start()
            try await client.initialize()
            DebugTelemetry.log(
                .toolStart,
                summary: "mcp spawn ok: \(config.name)",
                detail: "\(resolved.command) \(resolved.arguments.joined(separator: " "))"
            )
            return (config.name, Entry(client: client, config: config, failed: false, failureReason: nil))
        } catch {
            await client.shutdown()
            DebugTelemetry.log(
                .toolError,
                summary: "mcp spawn failed: \(config.name)",
                detail: String(describing: error),
                isError: true
            )
            return (config.name, Entry(
                client: client,
                config: config,
                failed: true,
                failureReason: String(describing: error)
            ))
        }
    }

    // MARK: - Config loading

    private static func loadConfigs() -> [MCPServerConfig] {
        let url = mcpConfigURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let servers = root["mcpServers"] as? [String: Any] else { return [] }

        var out: [MCPServerConfig] = []
        for (name, raw) in servers {
            guard let dict = raw as? [String: Any],
                  let command = dict["command"] as? String else { continue }
            let args = (dict["args"] as? [String]) ?? []
            let env = (dict["env"] as? [String: String]) ?? [:]
            let disabled = (dict["disabled"] as? Bool) ?? false
            let secretRefs = (dict["secretRefs"] as? [String]) ?? []
            let desc = dict["description"] as? String
            out.append(MCPServerConfig(
                name: name,
                command: command,
                arguments: args,
                environment: env,
                disabled: disabled,
                secretRefs: secretRefs,
                description: desc
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func mcpConfigURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("LocalAgent/mcp.json")
    }

    // MARK: - Environment & executable resolution

    /// Merge: inherited PATH/HOME/etc. + config.env + Keychain-backed secrets.
    /// Keychain keys are `mcp_env_<server>_<VAR>` (populated via Settings in
    /// a later phase). Plaintext values in mcp.json's `env` block take
    /// precedence for explicit overrides, but users are expected to put
    /// secrets in the Keychain.
    private static func resolveEnvironment(for config: MCPServerConfig) -> [String: String] {
        var env = baseEnvironment()
        for (k, v) in config.environment { env[k] = v }
        for ref in config.secretRefs {
            let key = "mcp_env_\(config.name)_\(ref)"
            if let value = KeychainHelper.load(key: key), !value.isEmpty {
                env[ref] = value
            }
        }
        return env
    }

    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Augment PATH with common install locations so `npx`, `uvx`,
        // `bun`, `python3`, etc. resolve reliably from a GUI-launched
        // subprocess environment.
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(env["HOME"] ?? "")/.local/bin",
            "\(env["HOME"] ?? "")/.bun/bin",
            "\(env["HOME"] ?? "")/.cargo/bin"
        ]
        let existing = env["PATH"] ?? ""
        var parts = existing.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// If `command` is bare (no slash), try to resolve via the augmented
    /// PATH. Returns the config with the absolute path filled in so MCPClient
    /// doesn't need to do its own lookup. Falls through untouched on miss.
    private static func resolveExecutable(config: MCPServerConfig) -> MCPServerConfig {
        if config.command.contains("/") { return config }
        let env = baseEnvironment()
        let path = env["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(config.command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return MCPServerConfig(
                    name: config.name,
                    command: candidate,
                    arguments: config.arguments,
                    environment: config.environment,
                    disabled: config.disabled,
                    secretRefs: config.secretRefs,
                    description: config.description
                )
            }
        }
        return config
    }

    // MARK: - Tool conversion (MCP inputSchema → ToolDefinition)

    /// Best-effort conversion from MCP's raw JSON-Schema `inputSchema` to our
    /// flat `FunctionParameters` shape. Nested-object properties are
    /// flattened to `type: "object"` with a descriptive note. Fully captured
    /// fidelity is deferred to a later phase (rawSchema pass-through).
    static func convertToToolDefinition(_ tool: MCPTool) -> ToolDefinition {
        let schema = tool.inputSchema
        let rawProps = (schema["properties"] as? [String: Any]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []

        var properties: [String: ParameterProperty] = [:]
        for (key, raw) in rawProps {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? "string"
            var description = (dict["description"] as? String) ?? ""
            var enumValues: [String]? = nil
            if let vals = dict["enum"] as? [Any] {
                enumValues = vals.compactMap { v -> String? in
                    if let s = v as? String { return s }
                    return String(describing: v)
                }
            }
            var itemsSchema: ArrayItemsSchema? = nil
            switch type {
            case "array":
                if let items = dict["items"] as? [String: Any] {
                    let itemType = (items["type"] as? String) ?? "string"
                    itemsSchema = ArrayItemsSchema(type: itemType)
                } else {
                    itemsSchema = ArrayItemsSchema(type: "string")
                }
            case "object":
                // Flatten: note sub-shape in description so the LLM can still form valid args.
                if let sub = dict["properties"] as? [String: Any], !sub.isEmpty {
                    let keys = sub.keys.sorted().joined(separator: ", ")
                    description = description.isEmpty
                        ? "JSON object with fields: \(keys)"
                        : "\(description) (JSON object with fields: \(keys))"
                }
            default:
                break
            }

            properties[key] = ParameterProperty(
                type: type,
                description: description,
                enumValues: enumValues,
                items: itemsSchema
            )
        }

        let fullDescription: String
        if tool.description.isEmpty {
            fullDescription = "Tool provided by MCP server '\(tool.serverName)'."
        } else {
            fullDescription = "\(tool.description)\n\n(Provided by MCP server '\(tool.serverName)'.)"
        }

        return ToolDefinition(
            function: FunctionDefinition(
                name: tool.prefixedName,
                description: fullDescription,
                parameters: FunctionParameters(
                    properties: properties,
                    required: required
                )
            )
        )
    }

    // MARK: - Name routing

    /// Split `mcp__<server>__<tool>` into (server, tool). Returns nil if the
    /// prefix doesn't parse.
    static func splitPrefixedName(_ prefixed: String) -> (server: String, tool: String)? {
        guard prefixed.hasPrefix("mcp__") else { return nil }
        let trimmed = String(prefixed.dropFirst("mcp__".count))
        guard let sep = trimmed.range(of: "__") else { return nil }
        let server = String(trimmed[..<sep.lowerBound])
        let tool = String(trimmed[sep.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    public static func isMCPPrefixed(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    // MARK: - Helpers

    private func jsonError(_ msg: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: ["error": msg], options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"MCP error\"}"
    }
}
