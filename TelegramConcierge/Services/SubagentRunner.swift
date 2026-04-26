import Foundation

// MARK: - Subagent Runner

/// Runs a single subagent task to completion with an isolated message history
/// and a filtered tool list. Mirrors Claude Code's Agent/Task tool behavior.
actor SubagentRunner {
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
        // Use unfiltered list so subagents can access deferred-server tools too
        // (e.g. Browse subagent using Playwright even when it's deferred for main).
        let allMcpTools = await MCPRegistry.shared.allToolDefinitionsUnfiltered()
        let subagentMcpTools = MCPAgentRouting.filterMcpTools(
            forAgent: subagentType.name,
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

        if let sid = sessionId, let session = await registry.prepareResume(sessionId: sid, continuationPrompt: invocation.taskPrompt) {
            resolvedSessionId = sid
            isNew = false
            messagesForLLM = session.messages
            priorToolInteractions = session.toolInteractions
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

        // 5. Capture a pre-run snapshot of the FilesLedger to diff after the run.
        let preSnapshot = await FilesLedgerDiff.snapshot()

        // 6. Tool loop
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

        loop: for round in 1...maxTurns {
            turnsUsed = round
            do {
                try Task.checkCancellation()
                let response = try await openRouterService.generateResponse(
                    messages: messagesForLLM,
                    imagesDirectory: imagesDirectory,
                    documentsDirectory: documentsDirectory,
                    tools: filteredTools,
                    toolResultMessages: toolInteractions.isEmpty ? nil : toolInteractions,
                    calendarContext: nil,
                    emailContext: nil,
                    chunkSummaries: nil,
                    totalChunkCount: 0,
                    currentUserMessageId: syntheticUser.id,
                    turnStartDate: turnStartDate,
                    finalResponseInstruction: subagentType.systemPromptSuffix,
                    modelOverride: effectiveModelOverride,
                    providerOverride: effectiveProviderOverride,
                    reasoningEffortOverride: effectiveReasoningOverride
                )

                switch response {
                case .text(let content, _, let spend):
                    if let spend { totalSpendUSD += spend }
                    finalText = content
                    break loop

                case .toolCalls(let assistantMessage, let calls, _, let spend):
                    if let spend { totalSpendUSD += spend }

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
                        let executed = try await toolExecutor.executeParallel(executableCalls)
                        toolResults.append(contentsOf: executed)
                    }
                    toolResults.append(contentsOf: blockedResults)

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
            } catch {
                runError = "Subagent error: \(error.localizedDescription)"
                break loop
            }
        }

        if runError == nil && finalText.isEmpty {
            runError = "Subagent exhausted maxTurns (\(maxTurns)) without returning a final text message"
        }

        // 7. Diff FilesLedger for files touched during the run.
        let postSnapshot = await FilesLedgerDiff.snapshot()
        let filesTouched = FilesLedgerDiff.diff(pre: preSnapshot, post: postSnapshot).allTouched

        // 8. Cap the final message at 32 KB (runaway-protection backstop).
        let cappedFinal = Self.capToBytes(finalText, limit: Self.finalMessageByteCap)

        // 9. Commit run state to the session registry so the session is resumable.
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
