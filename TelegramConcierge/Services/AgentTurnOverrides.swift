import Foundation

/// Per-agent max-turn override.
///
/// Lets the user pin a specific maximum-turn limit for the main agent and
/// each subagent type (built-in or user-defined), overriding the value baked
/// into `SubagentType.defaultMaxTurns` or `ConversationManager`'s safety cap.
///
/// Resolution order:
///   1. Per-agent override from `~/LocalAgent/agent-turns.json` (this file).
///   2. Built-in default (SubagentType.defaultMaxTurns or main-agent constant).
///
/// Config format:
/// ```json
/// {
///   "main":            120,
///   "Explore":         80,
///   "Plan":            80,
///   "general-purpose": 80
/// }
/// ```
enum AgentTurnOverrides {

    // MARK: - Constants

    /// Hard upper bound enforced on every persisted value — matches the cap
    /// used by the subagent editor and YAML loaders.
    static let maximumAllowed: Int = 200

    /// Fallback for the main agent when no override is set on disk. Kept in
    /// sync with `ConversationManager.maxToolRoundsSafetyLimit`.
    static let mainAgentDefault: Int = 120

    // MARK: - Cache

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedOverrides: [String: Int]?

    // MARK: - Public API

    /// Returns the override for `agent`, or nil if none set. Case-insensitive
    /// match so callers don't have to worry about built-in capitalization.
    static func override(forAgent agent: String) -> Int? {
        let map = loadIfNeeded()
        if let direct = map[agent] { return direct }
        let lower = agent.lowercased()
        if let loose = map.first(where: { $0.key.lowercased() == lower }) {
            return loose.value
        }
        return nil
    }

    /// Snapshot of the full override map. Used by the Settings UI.
    static func currentOverrides() -> [String: Int] {
        loadIfNeeded()
    }

    /// Overwrite the full map on disk. Settings UI calls this after each edit.
    static func save(_ overrides: [String: Int]) throws {
        let url = overridesURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var clean: [String: Int] = [:]
        for (agent, value) in overrides {
            guard value > 0 else { continue }
            clean[agent] = min(value, maximumAllowed)
        }

        let data = try JSONSerialization.data(
            withJSONObject: clean,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)

        cacheLock.lock()
        cachedOverrides = clean
        cacheLock.unlock()
    }

    /// Convenience: set (or clear with nil) a single agent's override.
    static func setOverride(_ value: Int?, forAgent agent: String) throws {
        var map = loadIfNeeded()
        if let v = value, v > 0 {
            map[agent] = min(v, maximumAllowed)
        } else {
            map.removeValue(forKey: agent)
        }
        try save(map)
    }

    /// Force re-read of the JSON file on next access.
    static func reload() {
        cacheLock.lock()
        cachedOverrides = nil
        cacheLock.unlock()
    }

    // MARK: - Internal

    @discardableResult
    private static func loadIfNeeded() -> [String: Int] {
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

    private static func loadFromDisk() -> [String: Int]? {
        let url = overridesURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: Int] = [:]
        for (agent, raw) in root {
            if let n = raw as? Int, n > 0 {
                out[agent] = min(n, maximumAllowed)
            } else if let n = raw as? NSNumber {
                let v = n.intValue
                if v > 0 { out[agent] = min(v, maximumAllowed) }
            }
        }
        return out
    }

    private static func overridesURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("LocalAgent/agent-turns.json")
    }
}
