import Foundation

// MARK: - Subagent Type Registry

/// Model-selection hint for a subagent run. Phase 1 only uses `.inherit` in practice;
/// `.cheapFast` will be wired in Phase 2 to a Groq-hosted gpt-oss-120b route.
enum SubagentModelChoice {
    case inherit
    case cheapFast
}

/// Describes a built-in subagent kind. Mirrors Claude Code's Agent/Task tool conventions.
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

    static let all: [SubagentType] = [generalPurpose, explore, plan]

    /// Case-insensitive lookup by name.
    static func find(name: String) -> SubagentType? {
        let lowered = name.lowercased()
        return all.first { $0.name.lowercased() == lowered }
    }
}
