import Foundation

// MARK: - Subagent Type Registry

/// Model-selection hint for a subagent run. `.cheapFast` routes to gpt-oss-120b via
/// Groq/Vertex for both cost isolation and prompt-cache isolation from the parent.
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
}

/// Model/provider targets for `.cheapFast` subagent runs. Matches the pattern
/// used in WebOrchestrator for its gpt-oss-120b web pipeline.
enum SubagentModelProfile {
    static let cheapFastModel = "openai/gpt-oss-120b"
    static let cheapFastProviders = ["groq", "google-vertex"]
}

enum SubagentTypes {
    static let generalPurpose = SubagentType(
        name: "general-purpose",
        description: "open-ended focused task",
        systemPromptSuffix:
            "You are a focused general-purpose subagent. Return a concrete final message with findings — file paths, line numbers, verbatim quotes when relevant. Do not ask clarifying questions.",
        allowedToolNames: nil,
        defaultMaxTurns: 20,
        preferredModel: .inherit
    )

    static let explore = SubagentType(
        name: "Explore",
        description: "read-only fast search",
        systemPromptSuffix:
            "You are a read-only file search and exploration specialist. Prioritize speed — use parallel tool calls aggressively. Do NOT modify any files. Do NOT run write-bash commands (no `rm`, `mv`, `mkdir`, `cat >`, `echo >`, etc.). Return findings with file paths and line numbers. Report verbatim code snippets when they matter.",
        allowedToolNames: [
            "read_file", "grep", "glob", "list_dir", "list_recent_files",
            "lsp_hover", "lsp_definition", "lsp_references",
            "web_fetch", "web_search", "bash"
        ],
        defaultMaxTurns: 15,
        preferredModel: .cheapFast
    )

    static let plan = SubagentType(
        name: "Plan",
        description: "read-only implementation plan",
        systemPromptSuffix:
            "You are a software architect designing an implementation plan. Explore using read-only tools, then return a step-by-step plan with: critical files to touch, sequencing, risks, and architectural trade-offs. Do NOT execute or modify files.",
        allowedToolNames: [
            "read_file", "grep", "glob", "list_dir", "list_recent_files",
            "lsp_hover", "lsp_definition", "lsp_references",
            "web_fetch", "web_search", "bash"
        ],
        defaultMaxTurns: 20,
        preferredModel: .inherit
    )

    static let builtIns: [SubagentType] = [generalPurpose, explore, plan]

    /// Built-ins plus any user-defined agents from `~/LocalAgent/agents/*.md`.
    /// Built-ins win on name collision.
    static func all() -> [SubagentType] {
        let user = UserAgentLoader.loadAll()
        let builtInNames = Set(builtIns.map { $0.name.lowercased() })
        let filteredUser = user.filter { !builtInNames.contains($0.name.lowercased()) }
        return builtIns + filteredUser
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
