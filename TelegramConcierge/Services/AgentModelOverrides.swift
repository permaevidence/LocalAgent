import Foundation

/// Per-agent model + reasoning-effort override.
///
/// Lets the user pin a specific OpenRouter model (or the "inherit parent"
/// sentinel) and reasoning effort for each subagent type, regardless of what
/// `SubagentType.preferredModel` would otherwise pick.
///
/// Resolution order inside SubagentRunner:
///   1. Per-call `invocation.modelOverride` (the "sonnet"/"opus"/"haiku" hint
///      passed by the main agent on a specific Agent call).
///   2. Per-agent override from `~/LocalAgent/agent-models.json` (this file).
///   3. SubagentType's built-in `preferredModel` (e.g. `.cheapFast` → Flash).
///   4. Parent main-agent model (fallback for `.inherit` types).
///
/// Config format:
/// ```json
/// {
///   "Explore":         { "model": "anthropic/claude-sonnet-4.5", "reasoning_effort": "medium" },
///   "Plan":            { "model": "inherit",                     "reasoning_effort": "high" },
///   "general-purpose": { "model": "google/gemini-3-flash-preview" }
/// }
/// ```
///
/// Both fields are optional. An empty / missing file means "use built-in
/// defaults for every agent" (current behavior).
enum AgentModelOverrides {

    // MARK: - Types

    struct Override: Equatable {
        /// OpenRouter model slug, "inherit" (use parent's model), or nil (no override).
        var model: String?
        /// "none" | "low" | "medium" | "high", or nil (no override).
        var reasoningEffort: String?
    }

    // MARK: - Cache

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedOverrides: [String: Override]?

    // MARK: - Public API

    /// Returns the override for `agent`, or nil if none set. Case-insensitive
    /// match so callers don't have to worry about built-in capitalization
    /// ("Explore" vs "explore").
    static func override(forAgent agent: String) -> Override? {
        let map = loadIfNeeded()
        if let direct = map[agent] { return direct }
        let lower = agent.lowercased()
        if let loose = map.first(where: { $0.key.lowercased() == lower }) {
            return loose.value
        }
        return nil
    }

    /// Snapshot of the full override map. Used by the Settings UI.
    static func currentOverrides() -> [String: Override] {
        loadIfNeeded()
    }

    /// Overwrite the full map on disk. Settings UI calls this after each edit.
    static func save(_ overrides: [String: Override]) throws {
        let url = overridesURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var serialized: [String: [String: String]] = [:]
        for (agent, override) in overrides {
            var entry: [String: String] = [:]
            if let m = override.model, !m.isEmpty { entry["model"] = m }
            if let r = override.reasoningEffort, !r.isEmpty { entry["reasoning_effort"] = r }
            if !entry.isEmpty {
                serialized[agent] = entry
            }
        }

        let data = try JSONSerialization.data(
            withJSONObject: serialized,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)

        cacheLock.lock()
        cachedOverrides = overrides
        cacheLock.unlock()
    }

    /// Force re-read of the JSON file on next access.
    static func reload() {
        cacheLock.lock()
        cachedOverrides = nil
        cacheLock.unlock()
    }

    // MARK: - Internal

    @discardableResult
    private static func loadIfNeeded() -> [String: Override] {
        cacheLock.lock()
        if let cached = cachedOverrides {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let loaded = loadFromDisk() ?? [:]
        cacheLock.lock()
        cachedOverrides = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func loadFromDisk() -> [String: Override]? {
        let url = overridesURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: Override] = [:]
        for (agent, raw) in root {
            guard let dict = raw as? [String: Any] else { continue }
            let model = dict["model"] as? String
            let reasoning = dict["reasoning_effort"] as? String
            if model != nil || reasoning != nil {
                out[agent] = Override(model: model, reasoningEffort: reasoning)
            }
        }
        return out
    }

    private static func overridesURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("LocalAgent/agent-models.json")
    }
}
