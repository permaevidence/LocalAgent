import Foundation

// MARK: - Subagent Runner

/// Runs a single subagent task to completion with an isolated message history
/// and a filtered tool list. Mirrors Claude Code's Agent/Task tool behavior.
actor SubagentRunner {
    /// If no progress (LLM response or tool completion) occurs within this
    /// interval, the subagent is considered stuck and is force-killed.
    private static let stalenessTimeout: TimeInterval = 20 * 60  // 20 minutes

    /// Tracks the last time a meaningful operation completed. Reset after each
    /// LLM response or tool execution batch.
    private var lastProgressDate = Date()
    struct Invocation {
        let subagentType: String
        let description: String
        let taskPrompt: String
        let modelOverride: String?        // "sonnet"/"opus"/"haiku"/"inherit"/nil
        let runInBackground: Bool         // Informational; actual routing happens in ToolExecutor.executeAgent
    }

    struct RunResult {
        let sessionId: String             // persistent session handle
        let isNewSession: Bool            // true if freshly created, false if resumed
        let finalMessage: String          // capped at 32 KB
        let turnsUsed: Int
        let toolsCalled: [String]         // unique tool names in call order
        let filesTouched: [String]        // paths that appeared/advanced in FilesLedger during the run
        let spendUSD: Double
        let error: String?                // nil on success

        func asJSON() -> String {
            var obj: [String: Any] = [
                "session_id": sessionId,
                "is_new_session": isNewSession,
                "final_message": finalMessage,
                "turns_used": turnsUsed,
                "tools_called": toolsCalled,
                "files_touched": filesTouched,
                "spend_usd": spendUSD
            ]
            if let error { obj["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"Failed to serialize subagent result\"}"
        }
    }

    /// Hard cap on the subagent's final message returned to the parent. Claude Code
    /// has no documented cap; 32 KB covers its typical envelope (long Plans,
    /// comprehensive general-purpose analyses) while retaining a runaway-protection
    /// backstop. Truncation adds a `[...truncated]` marker on a UTF-8 boundary.
    private static let finalMessageByteCap = 32 * 1024

    func run(
        invocation: Invocation,
        sessionId: String?,
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        parentTools: [ToolDefinition]
    ) async -> RunResult {
        // 1. Resolve subagent type
        guard let subagentType = SubagentTypes.find(name: invocation.subagentType) else {
            return RunResult(
                sessionId: sessionId ?? "",
                isNewSession: false,
                finalMessage: "",
                turnsUsed: 0,
                toolsCalled: [],
                filesTouched: [],
                spendUSD: 0,
                error: "Unknown subagent_type '\(invocation.subagentType)'. Valid values: \(SubagentTypes.allNames().joined(separator: ", "))."
            )
        }

        // 2. Build filtered tool list (rebuilt fresh each run so new MCPs are picked up).
        var filteredTools = parentTools.filter { $0.function.name != "Agent" }
        if let whitelist = subagentType.allowedToolNames {
            filteredTools = filteredTools.filter { whitelist.contains($0.function.name) }
        }
        // Subagents get all routed tools directly (always + deferred combined)
        // since they have their own context window and don't benefit from deferral.
        let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
        let subagentMcpTools = MCPAgentRouting.allToolsForAgent(
            agent: subagentType.name,
            allTools: allMcpTools,
            fallbackPatterns: subagentType.mcpToolPatterns
        )
        filteredTools += subagentMcpTools
        let allowedToolNames = Set(filteredTools.map { $0.function.name })

        // 3. Session: create or resume.
        let registry = SubagentSessionRegistry.shared
        let resolvedSessionId: String
        let isNew: Bool
        var messagesForLLM: [Message]
        var priorToolInteractions: [ToolInteraction]
        var overflow: SubagentSessionRegistry.SessionOverflow? = nil

        if let sid = sessionId, let result = await registry.prepareResume(sessionId: sid, continuationPrompt: invocation.taskPrompt) {
            resolvedSessionId = sid
            isNew = false
            messagesForLLM = result.session.messages
            priorToolInteractions = result.session.toolInteractions
            overflow = result.overflow
        } else {
            let (newId, session) = await registry.create(
                subagentType: invocation.subagentType,
                description: invocation.description,
                initialPrompt: invocation.taskPrompt
            )
            resolvedSessionId = newId
            isNew = true
            messagesForLLM = session.messages
            priorToolInteractions = session.toolInteractions
        }
        let syntheticUser = messagesForLLM.last ?? Message(role: .user, content: invocation.taskPrompt, timestamp: Date())

        // 4. Pick the model. Resolution order (highest precedence first):
        //    a. Per-call Agent-tool `model` hint ("sonnet"/"opus"/"haiku"/"inherit").
        //    b. User-configured per-agent override from
        //       ~/LocalAgent/agent-models.json (Settings → Agents → Model / Reasoning).
        //    c. SubagentType.preferredModel (.cheapFast → Flash+high, .inherit → nil).
        //    d. Fall through to parent's configured model (handled by OpenRouterService).
        let userOverride = AgentModelOverrides.override(forAgent: subagentType.name)
        let userModelSlug: String? = {
            guard let m = userOverride?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !m.isEmpty,
                  m.lowercased() != "inherit"
            else { return nil }
            return m
        }()
        let userReasoning: String? = {
            guard let r = userOverride?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !r.isEmpty
            else { return nil }
            return r
        }()

        let typeLevelOverride: (model: String, providers: [String]?, reasoning: String?)?
        switch subagentType.preferredModel {
        case .cheapFast:
            typeLevelOverride = (
                SubagentModelProfile.cheapFastModel,
                SubagentModelProfile.cheapFastProviders,
                SubagentModelProfile.cheapFastReasoningEffort
            )
        case .inherit:
            typeLevelOverride = nil
        }

        let perCallSlug = SubagentModelHintMapper.openRouterSlug(for: invocation.modelOverride)
        if let hint = invocation.modelOverride,
           !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           hint.lowercased() != "inherit",
           perCallSlug == nil {
            print("[SubagentRunner] Ignoring unsupported model hint '\(hint)'; falling back to type default.")
        }

        let effectiveModelOverride: String?
        let effectiveProviderOverride: [String]?
        let effectiveReasoningOverride: String?
        if let perCallSlug {
            // Per-call hint wins. User settings and type defaults both overridden.
            effectiveModelOverride = perCallSlug
            effectiveProviderOverride = nil
            effectiveReasoningOverride = userReasoning
        } else if userModelSlug != nil || userReasoning != nil {
            // User override present. Fill each field from user → type → nil.
            effectiveModelOverride = userModelSlug ?? typeLevelOverride?.model
            effectiveProviderOverride = userModelSlug != nil ? nil : typeLevelOverride?.providers
            effectiveReasoningOverride = userReasoning ?? typeLevelOverride?.reasoning
        } else if let typeLevelOverride {
            effectiveModelOverride = typeLevelOverride.model
            effectiveProviderOverride = typeLevelOverride.providers
            effectiveReasoningOverride = typeLevelOverride.reasoning
        } else {
            effectiveModelOverride = nil
            effectiveProviderOverride = nil
            effectiveReasoningOverride = nil
        }

        // 5. Summarize overflow from session resume (if any).
        if let overflow = overflow {
            let summary = await summarizeOverflow(
                overflow,
                openRouterService: openRouterService,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                modelOverride: effectiveModelOverride,
                providerOverride: effectiveProviderOverride,
                reasoningEffortOverride: effectiveReasoningOverride
            )
            if let summary {
                let summaryMsg = Message(role: .user, content: summary, timestamp: Date(timeIntervalSince1970: 0))
                messagesForLLM.insert(summaryMsg, at: 0)
                await registry.injectSummary(sessionId: resolvedSessionId, summary: summary)
            }
        }

        // 6. Capture a pre-run snapshot of the FilesLedger to diff after the run.
        let preSnapshot = await FilesLedgerDiff.snapshot()

        // 7. Tool loop
        var toolInteractions: [ToolInteraction] = priorToolInteractions
        var toolsCalledOrdered: [String] = []
        var seenToolNames = Set<String>()
        var totalSpendUSD: Double = 0
        var turnsUsed = 0
        var runError: String? = nil
        var finalText: String = ""

        let maxTurns = AgentTurnOverrides.override(forAgent: subagentType.name)
            ?? subagentType.defaultMaxTurns
        let turnStartDate = Date()
        let turnTokenBudget = Self.turnTokenBudget()
        var lastPromptTokens: Int? = nil

        loop: for round in 1...maxTurns {
            turnsUsed = round
            do {
                try Task.checkCancellation()
                try checkStaleness()

                // If context already exceeds the turn budget, force a final response.
                let forceFinish = lastPromptTokens.map { $0 >= turnTokenBudget } ?? false
                let response = try await openRouterService.generateResponse(
                    messages: messagesForLLM,
                    imagesDirectory: imagesDirectory,
                    documentsDirectory: documentsDirectory,
                    tools: forceFinish ? [] : filteredTools,
                    toolResultMessages: toolInteractions.isEmpty ? nil : toolInteractions,
                    calendarContext: nil,
                    emailContext: nil,
                    chunkSummaries: nil,
                    totalChunkCount: 0,
                    currentUserMessageId: syntheticUser.id,
                    turnStartDate: turnStartDate,
                    finalResponseInstruction: forceFinish
                        ? "[CONTEXT BUDGET EXHAUSTED] Your context has reached the token limit for this turn. Provide your final answer NOW — summarize your progress and state what remains."
                        : subagentType.systemPromptSuffix,
                    modelOverride: effectiveModelOverride,
                    providerOverride: effectiveProviderOverride,
                    reasoningEffortOverride: effectiveReasoningOverride
                )
                markProgress()  // LLM responded — subagent is alive

                switch response {
                case .text(let content, let promptTk, _, let spend):
                    if let spend { totalSpendUSD += spend }
                    if let pt = promptTk { lastPromptTokens = pt }
                    finalText = content
                    break loop

                case .toolCalls(let assistantMessage, let calls, let promptTk, _, let spend):
                    if let spend { totalSpendUSD += spend }
                    if let pt = promptTk { lastPromptTokens = pt }

                    // Filter out any tool calls the subagent is not allowed to make.
                    var executableCalls: [ToolCall] = []
                    var blockedResults: [ToolResultMessage] = []
                    for call in calls {
                        if allowedToolNames.contains(call.function.name) {
                            executableCalls.append(call)
                            if !seenToolNames.contains(call.function.name) {
                                seenToolNames.insert(call.function.name)
                                toolsCalledOrdered.append(call.function.name)
                            }
                        } else {
                            let blocked = ToolResultMessage(
                                toolCallId: call.id,
                                content: "{\"error\": \"Tool '\(call.function.name)' is not available to this subagent.\"}"
                            )
                            blockedResults.append(blocked)
                        }
                    }

                    var toolResults: [ToolResultMessage] = []
                    if !executableCalls.isEmpty {
                        let executed = try await executeWithTimeout(executableCalls, using: toolExecutor)
                        toolResults.append(contentsOf: executed)
                    }
                    toolResults.append(contentsOf: blockedResults)
                    markProgress()  // Tools completed — subagent is alive

                    // Accumulate any tool-internal spend (e.g. web_search nested API calls).
                    for r in toolResults { if let s = r.spendUSD { totalSpendUSD += s } }

                    // Reorder to match the assistant's tool_call order.
                    var ordered: [ToolResultMessage] = []
                    var remaining = toolResults
                    for call in assistantMessage.toolCalls {
                        if let idx = remaining.firstIndex(where: { $0.toolCallId == call.id }) {
                            ordered.append(remaining.remove(at: idx))
                        }
                    }
                    if !remaining.isEmpty { ordered.append(contentsOf: remaining) }

                    toolInteractions.append(ToolInteraction(
                        assistantMessage: assistantMessage,
                        results: ordered
                    ))
                }
            } catch is CancellationError {
                runError = "Subagent cancelled"
                break loop
            } catch let e as SubagentStalenessError {
                runError = e.localizedDescription
                break loop
            } catch {
                runError = "Subagent error: \(error.localizedDescription)"
                break loop
            }
        }

        if runError == nil && finalText.isEmpty {
            runError = "Subagent exhausted maxTurns (\(maxTurns)) without returning a final text message"
        }

        // 8. Diff FilesLedger for files touched during the run.
        let postSnapshot = await FilesLedgerDiff.snapshot()
        let filesTouched = FilesLedgerDiff.diff(pre: preSnapshot, post: postSnapshot).allTouched

        // 9. Cap the final message at 32 KB (runaway-protection backstop).
        let cappedFinal = Self.capToBytes(finalText, limit: Self.finalMessageByteCap)

        // 10. Commit run state to the session registry so the session is resumable.
        let newInteractions = Array(toolInteractions.dropFirst(priorToolInteractions.count))
        await registry.commitRun(
            sessionId: resolvedSessionId,
            additionalTurns: turnsUsed,
            additionalSpend: totalSpendUSD,
            newToolsCalled: toolsCalledOrdered,
            newToolInteractions: newInteractions,
            finalAssistantText: finalText.isEmpty ? nil : finalText
        )

        return RunResult(
            sessionId: resolvedSessionId,
            isNewSession: isNew,
            finalMessage: cappedFinal,
            turnsUsed: turnsUsed,
            toolsCalled: toolsCalledOrdered,
            filesTouched: filesTouched,
            spendUSD: totalSpendUSD,
            error: runError
        )
    }

    // MARK: - Session Overflow Summarization

    /// Summarize content that was trimmed from a session on resume.
    /// Returns a structured summary string, or nil if summarization fails
    /// (in which case the subagent simply loses the old context — same as before).
    private func summarizeOverflow(
        _ overflow: SubagentSessionRegistry.SessionOverflow,
        openRouterService: OpenRouterService,
        imagesDirectory: URL,
        documentsDirectory: URL,
        modelOverride: String?,
        providerOverride: [String]?,
        reasoningEffortOverride: String?
    ) async -> String? {
        // Build a text representation of the trimmed content.
        var transcript = ""

        for msg in overflow.trimmedMessages {
            let role = msg.role == .user ? "USER" : "ASSISTANT"
            transcript += "[\(role)] \(msg.content)\n\n"
        }

        for interaction in overflow.trimmedToolInteractions {
            if let reasoning = interaction.assistantMessage.reasoning {
                transcript += "[THINKING] \(reasoning)\n"
            }
            for tc in interaction.assistantMessage.toolCalls {
                transcript += "[TOOL CALL] \(tc.function.name)(\(tc.function.arguments))\n"
            }
            for result in interaction.results {
                transcript += "[TOOL RESULT] \(result.content)\n"
            }
            transcript += "\n"
        }

        guard !transcript.isEmpty else { return nil }

        let summaryPrompt = """
        You are summarizing the earlier portion of a coding agent's work session that is being \
        evicted from context to free up space. The agent will continue working with only this \
        summary as reference for what happened before.

        Produce a detailed, structured summary that preserves:
        1. WHAT was accomplished — every significant action, decision, and outcome
        2. FILES touched — exact file paths and what was done to each (created, edited, read, deleted)
        3. KEY findings — errors encountered, solutions applied, important values/configs discovered
        4. CURRENT STATE — where the work left off, what was in progress, any pending items
        5. CONTEXT — any user requirements, constraints, or preferences that were established

        Be thorough — information not in this summary is permanently lost. Use exact file paths, \
        function names, and error messages. Do not generalize when specifics are available.

        Format the summary as a clear, scannable document with headers and bullet points.

        === TRANSCRIPT TO SUMMARIZE ===
        \(transcript)
        """

        let summaryMessages = [Message(role: .user, content: summaryPrompt, timestamp: Date())]

        do {
            let response = try await openRouterService.generateResponse(
                messages: summaryMessages,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                tools: [],
                modelOverride: modelOverride,
                providerOverride: providerOverride,
                reasoningEffortOverride: reasoningEffortOverride
            )

            switch response {
            case .text(let content, _, _, _):
                return "[SESSION HISTORY SUMMARY — Earlier work in this session was summarized to free context space. Details below are from the evicted portion.]\n\n\(content)"
            case .toolCalls:
                // Shouldn't happen with tools=[], but handle gracefully.
                return nil
            }
        } catch {
            print("[SubagentRunner] Failed to summarize session overflow: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Turn Token Budget

    private static func turnTokenBudget() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.subagentTurnTokenBudgetKey),
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return KeychainHelper.defaultSubagentTurnTokenBudget
    }

    // MARK: - Progress Watchdog

    private func markProgress() {
        lastProgressDate = Date()
    }

    private func checkStaleness() throws {
        let elapsed = Date().timeIntervalSince(lastProgressDate)
        if elapsed > Self.stalenessTimeout {
            throw SubagentStalenessError(staleDuration: elapsed)
        }
    }

    /// Races a tool execution batch against the staleness timeout.
    /// Uses unstructured tasks so timeout can return even when tool execution is
    /// blocked in non-cooperative I/O and would prevent a task group from exiting.
    private func executeWithTimeout(
        _ calls: [ToolCall],
        using executor: ToolExecutor
    ) async throws -> [ToolResultMessage] {
        let raceSlot = ToolExecutionTimeoutRaceSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    Task {
                        await executor.cancelAllRunningProcesses()
                    }
                    return
                }

                let race = ToolExecutionTimeoutRace(continuation: continuation)
                raceSlot.set(race)

                let executionTask = Task {
                    do {
                        let results = try await executor.executeParallel(calls)
                        race.resolve(.success(results))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                race.setExecutionTask(executionTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(Self.stalenessTimeout * 1_000_000_000))
                    } catch {
                        return
                    }
                    race.cancelExecution()
                    Task {
                        await executor.cancelAllRunningProcesses()
                    }
                    race.resolve(.failure(SubagentStalenessError(staleDuration: Self.stalenessTimeout)))
                }
                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            raceSlot.cancelExecution()
            raceSlot.resolve(.failure(CancellationError()))
            Task {
                await executor.cancelAllRunningProcesses()
            }
        }
    }

    // MARK: - Helpers

    private static func capToBytes(_ s: String, limit: Int) -> String {
        let data = Data(s.utf8)
        if data.count <= limit { return s }
        let marker = "\n[...truncated]"
        let markerBytes = Data(marker.utf8).count
        let head = max(0, limit - markerBytes)
        let prefix = data.prefix(head)
        // Truncate to a valid UTF-8 boundary by trimming trailing bytes until decode succeeds.
        var truncated = Data(prefix)
        while !truncated.isEmpty {
            if let str = String(data: truncated, encoding: .utf8) {
                return str + marker
            }
            truncated.removeLast()
        }
        return marker
    }

}

// MARK: - Staleness Error

struct SubagentStalenessError: Error, LocalizedError {
    let staleDuration: TimeInterval
    var errorDescription: String? {
        "Subagent killed: no progress for \(Int(staleDuration / 60)) minutes (stuck operation)"
    }
}

private final class ToolExecutionTimeoutRace {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ToolResultMessage], Error>?
    private var executionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolved = false

    init(continuation: CheckedContinuation<[ToolResultMessage], Error>) {
        self.continuation = continuation
    }

    func setExecutionTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = resolved
        if !resolved {
            executionTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = resolved
        if !resolved {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancelExecution() {
        lock.lock()
        let task = executionTask
        lock.unlock()
        task?.cancel()
    }

    func resolve(_ result: Result<[ToolResultMessage], Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        let executionTask = executionTask
        lock.unlock()

        timeoutTask?.cancel()
        if case .failure(let error) = result, error is SubagentStalenessError {
            executionTask?.cancel()
        }

        switch result {
        case .success(let results):
            continuation?.resume(returning: results)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class ToolExecutionTimeoutRaceSlot {
    private let lock = NSLock()
    private var race: ToolExecutionTimeoutRace?
    private var cancellationRequested = false

    func set(_ race: ToolExecutionTimeoutRace) {
        lock.lock()
        let shouldCancel = cancellationRequested
        if !shouldCancel {
            self.race = race
        }
        lock.unlock()

        if shouldCancel {
            race.cancelExecution()
            race.resolve(.failure(CancellationError()))
        }
    }

    func cancelExecution() {
        lock.lock()
        cancellationRequested = true
        let race = race
        lock.unlock()
        race?.cancelExecution()
    }

    func resolve(_ result: Result<[ToolResultMessage], Error>) {
        lock.lock()
        let race = race
        lock.unlock()
        race?.resolve(result)
    }
}
