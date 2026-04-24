import Foundation

// MARK: - Subagent Type Registry

/// Model-selection hint for a subagent run. `.cheapFast` routes to a fast
/// Gemini model with explicit "high" reasoning for prompt-cache isolation from
/// the parent (separate model → separate cache lane).
enum SubagentModelChoice {
    case inherit
    case cheapFast
}

/// Describes a subagent kind (built-in or user-defined).
struct SubagentType {
    let name: String
    let description: String
    let systemPromptSuffix: String
    /// nil = inherit ALL parent tools MINUS the Agent tool itself.
    /// Non-nil = strict whitelist by tool name.
    let allowedToolNames: Set<String>?
    let defaultMaxTurns: Int
    let preferredModel: SubagentModelChoice
    /// Default MCP tool-name patterns this subagent type can see (e.g.
    /// `["mcp__playwright__*"]`). Overridden per-agent by
    /// `~/LocalAgent/mcp-routing.json` when an entry for this agent exists.
    /// nil = no MCP tools visible unless the routing file opts them in.
    let mcpToolPatterns: [String]?

    init(
        name: String,
        description: String,
        systemPromptSuffix: String,
        allowedToolNames: Set<String>?,
        defaultMaxTurns: Int,
        preferredModel: SubagentModelChoice,
        mcpToolPatterns: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.systemPromptSuffix = systemPromptSuffix
        self.allowedToolNames = allowedToolNames
        self.defaultMaxTurns = defaultMaxTurns
        self.preferredModel = preferredModel
        self.mcpToolPatterns = mcpToolPatterns
    }
}

/// Model/provider/reasoning targets for `.cheapFast` subagent runs.
/// Gemini-3-Flash gives us cache isolation from the parent while matching the
/// app's default model family, and explicit "high" reasoning mirrors the
/// repo-wide default configured in Settings.
enum SubagentModelProfile {
    static let cheapFastModel = "google/gemini-3-flash-preview"
    /// Provider preference left unset — OpenRouter routes Gemini Flash to
    /// whichever of its configured providers is available (Google AI Studio /
    /// Vertex). Keep this nil unless we need deterministic routing.
    static let cheapFastProviders: [String]? = nil
    static let cheapFastReasoningEffort = "high"
}

enum SubagentTypes {
    static let generalPurpose = SubagentType(
        name: "general-purpose",
        description: "open-ended focused task",
        systemPromptSuffix:
            "You are a focused general-purpose subagent. Return a concrete final message with findings — file paths, line numbers, verbatim quotes when relevant. Do not ask clarifying questions.",
        allowedToolNames: nil,
        defaultMaxTurns: 80,
        preferredModel: .cheapFast
    )

    static let explore = SubagentType(
        name: "Explore",
        description: "read-only fast search",
        systemPromptSuffix:
            "You are a read-only file search and exploration specialist. Prioritize speed — use parallel tool calls aggressively. Do NOT modify any files. Do NOT run write-bash commands (no `rm`, `mv`, `mkdir`, `cat >`, `echo >`, etc.). Return findings with file paths and line numbers. Report verbatim code snippets when they matter.",
        allowedToolNames: [
            "read_file", "grep", "glob", "list_dir", "list_recent_files",
            "lsp",
            "web_fetch", "web_search", "bash"
        ],
        defaultMaxTurns: 80,
        preferredModel: .cheapFast
    )

    static let plan = SubagentType(
        name: "Plan",
        description: "read-only implementation plan",
        systemPromptSuffix:
            "You are a software architect designing an implementation plan. Explore using read-only tools, then return a step-by-step plan with: critical files to touch, sequencing, risks, and architectural trade-offs. Do NOT execute or modify files.",
        allowedToolNames: [
            "read_file", "grep", "glob", "list_dir", "list_recent_files",
            "lsp",
            "web_fetch", "web_search", "bash"
        ],
        defaultMaxTurns: 80,
        preferredModel: .cheapFast
    )

    /// Dynamic subagent registered when a Playwright MCP is installed.
    /// Gets the full browser tool surface scoped to its own context so the
    /// main agent's prompt stays lean.
    static let browse = SubagentType(
        name: "Browse",
        description: "browser automation via Playwright MCP",
        systemPromptSuffix:
            "You are a browser automation specialist. Use the mcp__playwright__* tools to navigate, snapshot, click, type, and evaluate pages. Prefer `browser_snapshot` (cheap, structured accessibility tree) over `browser_take_screenshot` unless a visual is specifically requested. Return a concise report with what you found, what you clicked, and any extracted data. If navigating to a sensitive site (bank, admin console), stop and report back rather than acting.",
        allowedToolNames: ["read_file", "grep", "bash", "web_fetch"],
        defaultMaxTurns: 80,
        preferredModel: .cheapFast,
        mcpToolPatterns: ["mcp__playwright__*"]
    )

    /// Dynamic subagent registered when a SQL MCP (postgres / sqlite / mysql)
    /// is installed. Scoped to read-heavy analysis — writes are still possible
    /// through the MCP but the prompt steers toward inspection first.
    static let db = SubagentType(
        name: "DB",
        description: "SQL database exploration and query",
        systemPromptSuffix:
            "You are a database analysis specialist. Use the mcp__postgres__* / mcp__sqlite__* / mcp__mysql__* tools (whichever are present) to list schemas, inspect tables, and run read queries. For destructive writes (INSERT/UPDATE/DELETE/DROP), stop and confirm intent before executing. Return results as a concise summary with row counts and key values — do not dump large tables verbatim.",
        allowedToolNames: ["read_file", "grep", "bash"],
        defaultMaxTurns: 80,
        preferredModel: .cheapFast,
        mcpToolPatterns: ["mcp__postgres__*", "mcp__sqlite__*", "mcp__mysql__*"]
    )

    static let staticBuiltIns: [SubagentType] = [generalPurpose, explore, plan]

    /// Built-ins that should appear only when a matching MCP server is
    /// installed, keyed by the server name(s) that activate them.
    private static let dynamicBuiltIns: [(type: SubagentType, servers: Set<String>)] = [
        (browse, ["playwright"]),
        (db, ["postgres", "sqlite", "mysql"])
    ]

    /// Active dynamic built-ins for the current registry state. Each dynamic
    /// subagent appears only if at least one of its backing MCP servers is
    /// currently connected (per `MCPAgentRouting.installedServers()`).
    static func activeDynamicBuiltIns() -> [SubagentType] {
        let installed = MCPAgentRouting.installedServers()
        return dynamicBuiltIns.compactMap { pair in
            pair.servers.isDisjoint(with: installed) ? nil : pair.type
        }
    }

    /// All currently-visible built-ins (static + active dynamic).
    static var builtIns: [SubagentType] {
        staticBuiltIns + activeDynamicBuiltIns()
    }

    /// Built-ins plus any user-defined agents from `~/LocalAgent/agents/*.md`.
    /// Built-ins win on name collision.
    static func all() -> [SubagentType] {
        let user = UserAgentLoader.loadAll()
        let built = builtIns
        let builtInNames = Set(built.map { $0.name.lowercased() })
        let filteredUser = user.filter { !builtInNames.contains($0.name.lowercased()) }
        return built + filteredUser
    }

    /// All subagent names for tool-schema enum values.
    static func allNames() -> [String] {
        return all().map { $0.name }
    }

    /// Case-insensitive lookup by name. Built-ins first, then user-defined.
    static func find(name: String) -> SubagentType? {
        let lowered = name.lowercased()
        if let builtIn = builtIns.first(where: { $0.name.lowercased() == lowered }) {
            return builtIn
        }
        return UserAgentLoader.loadAll().first { $0.name.lowercased() == lowered }
    }
}

/// Maps the short model hints accepted by the Agent tool's `model` parameter
/// to concrete OpenRouter model slugs. Returns nil for "inherit"/unknown values,
/// which means "keep the parent's configured model".
enum SubagentModelHintMapper {
    static func openRouterSlug(for hint: String?) -> String? {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              raw != "inherit" else {
            return nil
        }
        switch raw {
        case "sonnet":
            return "anthropic/claude-sonnet-4.5"
        case "opus":
            return "anthropic/claude-opus-4.1"
        case "haiku":
            return "anthropic/claude-haiku-4.5"
        default:
            return nil
        }
    }
}
