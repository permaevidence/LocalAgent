import Foundation

/// Owns all currently-running subagents launched via `Agent(run_in_background: "true")`.
///
/// Mirrors `BackgroundProcessRegistry` (bash) but is Task-backed rather than Process-backed:
/// there are no pipes, no PIDs — just a detached `Task` that runs `SubagentRunner.run(...)`
/// to completion and stores its structured `RunResult`.
///
/// ConversationManager calls `drainCompletions()` once per poll cycle to pull completions
/// and inject them as synthetic `[SUBAGENT COMPLETE]` user messages, triggering a new
/// agent turn so the parent can react.
actor SubagentBackgroundRegistry {
    static let shared = SubagentBackgroundRegistry()

    struct Handle {
        let id: String              // e.g. "subagent_1"
        let subagentType: String
        let description: String
        let startedAt: Date
    }

    struct Completion {
        let handle: Handle
        let result: SubagentRunner.RunResult
        let completedAt: Date
    }

    private var nextId: Int = 1
    private var running: [String: Handle] = [:]
    private var pendingCompletions: [Completion] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Spawns a detached Task that runs the invocation to completion and stores its result.
    /// Returns the Handle immediately.
    func spawn(
        invocation: SubagentRunner.Invocation,
        parentTools: [ToolDefinition],
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> Handle {
        let id = "subagent_\(nextId)"
        nextId += 1

        let handle = Handle(
            id: id,
            subagentType: invocation.subagentType,
            description: invocation.description,
            startedAt: Date()
        )
        running[id] = handle

        DebugTelemetry.log(
            .subagentSpawn,
            summary: "spawn subagent \(id) (\(invocation.subagentType))",
            detail: invocation.description
        )

        let task = Task.detached { [weak self] in
            let runner = SubagentRunner()
            let result = await runner.run(
                invocation: invocation,
                sessionId: nil,
                openRouterService: openRouterService,
                toolExecutor: toolExecutor,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                parentTools: parentTools
            )
            await self?.markCompleted(id: id, result: result)
        }
        tasks[id] = task

        return handle
    }

    /// Returns and clears all completions.
    func drainCompletions() -> [Completion] {
        let out = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: true)
        return out
    }

    /// Snapshot of currently-running handles, used for diagnostics / system-prompt hints.
    func runningHandles() -> [Handle] {
        running.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Compact one-line-per-agent summary of running subagents, used by the
    /// system prompt so the parent knows what's in flight this turn. Returns
    /// `nil` when there are none (skip the section entirely).
    func liveSummary() -> String? {
        let handles = running.values.sorted { $0.startedAt < $1.startedAt }
        guard !handles.isEmpty else { return nil }
        let now = Date()
        var lines: [String] = ["Running subagents:"]
        for h in handles {
            let secs = Int(now.timeIntervalSince(h.startedAt))
            let dur: String
            if secs < 60 {
                dur = "\(secs)s"
            } else {
                let m = secs / 60
                let s = secs % 60
                dur = "\(m)m \(s)s"
            }
            // Trim description to keep the line tight.
            let desc = h.description.count > 60
                ? String(h.description.prefix(60)) + "…"
                : h.description
            lines.append("- \(h.id) [\(h.subagentType), \"\(desc)\", running \(dur)]")
        }
        return lines.joined(separator: "\n")
    }

    /// Best-effort cancellation. `SubagentRunner.run` checks `Task.isCancelled` between turns,
    /// so cancellation takes effect at the next loop iteration.
    func cancel(id: String) -> Bool {
        guard let task = tasks[id] else { return false }
        task.cancel()
        return true
    }

    // MARK: - Internal

    private func markCompleted(id: String, result: SubagentRunner.RunResult) {
        guard let handle = running.removeValue(forKey: id) else { return }
        tasks.removeValue(forKey: id)
        pendingCompletions.append(Completion(
            handle: handle,
            result: result,
            completedAt: Date()
        ))
    }
}
