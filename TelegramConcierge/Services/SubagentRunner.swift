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
        let finalMessage: String          // capped at 32 KB
        let turnsUsed: Int
        let toolsCalled: [String]         // unique tool names in call order
        let filesTouched: [String]        // paths that appeared/advanced in FilesLedger during the run
        let spendUSD: Double
        let error: String?                // nil on success

        func asJSON() -> String {
            var obj: [String: Any] = [
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
        openRouterService: OpenRouterService,
        toolExecutor: ToolExecutor,
        imagesDirectory: URL,
        documentsDirectory: URL,
        parentTools: [ToolDefinition]
    ) async -> RunResult {
        // 1. Resolve subagent type
        guard let subagentType = SubagentTypes.find(name: invocation.subagentType) else {
            return RunResult(
                finalMessage: "",
                turnsUsed: 0,
                toolsCalled: [],
                filesTouched: [],
                spendUSD: 0,
                error: "Unknown subagent_type '\(invocation.subagentType)'. Valid values: general-purpose, Explore, Plan."
            )
        }

        // 2. Build filtered tool list.
        //    - Always strip the Agent tool (recursion guard).
        //    - If a whitelist is set, keep only whitelisted names.
        var filteredTools = parentTools.filter { $0.function.name != "Agent" }
        if let whitelist = subagentType.allowedToolNames {
            filteredTools = filteredTools.filter { whitelist.contains($0.function.name) }
        }
        let allowedToolNames = Set(filteredTools.map { $0.function.name })

        // 3. Build an isolated message history — a single synthetic user message.
        let syntheticUser = Message(
            role: .user,
            content: invocation.taskPrompt,
            timestamp: Date()
        )
        var messagesForLLM: [Message] = [syntheticUser]

        // 4. Pick the model.
        //    - .cheapFast → gpt-oss-120b via Groq/Vertex (cost + cache isolation).
        //    - .inherit  → parent's configured model.
        //    - Agent-tool `model` param ("sonnet"/"opus"/"haiku") overrides .inherit when mappable.
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
            effectiveModelOverride = perCallSlug
            effectiveProviderOverride = nil
            effectiveReasoningOverride = nil
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
        var toolInteractions: [ToolInteraction] = []
        var toolsCalledOrdered: [String] = []
        var seenToolNames = Set<String>()
        var totalSpendUSD: Double = 0
        var turnsUsed = 0
        var runError: String? = nil
        var finalText: String = ""

        let maxTurns = subagentType.defaultMaxTurns
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

        return RunResult(
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
