import AppKit
import Darwin
import Foundation

// MARK: - Tool Executor

/// Central dispatcher that routes tool calls to their implementations
actor ToolExecutor {
    private let webOrchestrator = WebOrchestrator()
    private let archiveService = ConversationArchiveService()
    private var openRouterService: OpenRouterService?
    private var subagentImagesDirectory: URL?
    private var subagentDocumentsDirectory: URL?

    private static let runningProcessLock = NSLock()
    private static var runningProcesses: [ObjectIdentifier: Process] = [:]

    // MARK: - Configuration

    func configure(openRouterKey: String, serperKey: String, jinaKey: String) async {
        await webOrchestrator.configure(openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)
        Task { await archiveService.configure(apiKey: openRouterKey) }
    }

    /// Inject the parent's OpenRouterService so the Agent tool can drive a subagent loop.
    func configureOpenRouter(_ service: OpenRouterService, imagesDirectory: URL, documentsDirectory: URL) {
        self.openRouterService = service
        self.subagentImagesDirectory = imagesDirectory
        self.subagentDocumentsDirectory = documentsDirectory
    }
    
    nonisolated func cancelAllRunningProcesses() async {
        let processes = Self.snapshotRunningProcesses()
        guard !processes.isEmpty else { return }
        
        print("[ToolExecutor] Cancelling \(processes.count) running subprocess(es)")
        for process in processes where process.isRunning {
            process.terminate()
        }
        
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        for process in processes where process.isRunning {
            process.interrupt()
        }
        
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        for process in processes where process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
        }
    }
    
    private nonisolated static func waitForProcessExit(_ process: Process, timeoutNanoseconds: UInt64) async {
        let pollInterval: UInt64 = 50_000_000
        var elapsed: UInt64 = 0
        
        while process.isRunning && elapsed < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval
        }
    }
    
    private static func registerRunningProcess(_ process: Process) {
        runningProcessLock.lock()
        runningProcesses[ObjectIdentifier(process)] = process
        runningProcessLock.unlock()
    }
    
    private static func unregisterRunningProcess(_ process: Process) {
        runningProcessLock.lock()
        runningProcesses.removeValue(forKey: ObjectIdentifier(process))
        runningProcessLock.unlock()
    }
    
    private static func snapshotRunningProcesses() -> [Process] {
        runningProcessLock.lock()
        let processes = Array(runningProcesses.values)
        runningProcessLock.unlock()
        return processes
    }
    
    // MARK: - Execution
    
    /// Execute a single tool call and return the result
    func execute(_ call: ToolCall) async throws -> ToolResultMessage {
        try Task.checkCancellation()
        return try await withTelemetry(call) {
            try await self.executeBody(call)
        }
    }

    /// Wraps tool execution with telemetry (toolStart/toolEnd/toolError + timing).
    /// The telemetry stream is user-only and NEVER sent to the LLM.
    private func withTelemetry(
        _ call: ToolCall,
        _ body: () async throws -> ToolResultMessage
    ) async throws -> ToolResultMessage {
        let started = Date()
        let argSummary = Self.shortArgSummary(call.function.arguments)
        let startSummary = argSummary.isEmpty
            ? call.function.name
            : "\(call.function.name)  \(argSummary)"
        DebugTelemetry.log(
            .toolStart,
            summary: startSummary,
            detail: call.function.arguments
        )
        do {
            let result = try await body()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let isError = result.content.contains("\"error\"")
            DebugTelemetry.log(
                isError ? .toolError : .toolEnd,
                summary: "\(call.function.name) (\(ms)ms)",
                durationMs: ms,
                isError: isError
            )
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DebugTelemetry.log(
                .toolError,
                summary: "\(call.function.name) threw",
                detail: String(describing: error),
                durationMs: ms,
                isError: true
            )
            throw error
        }
    }

    /// Pulls 1–2 identifying fields from a tool's JSON argument string for a
    /// compact, single-line summary in the telemetry view. Falls back to the
    /// first 60 chars of the raw arg string when parsing fails.
    static func shortArgSummary(_ jsonArgs: String) -> String {
        let preferredKeys = ["path", "file_path", "handle", "query", "command", "url", "pattern", "search_term", "target"]
        if let data = jsonArgs.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parts: [String] = []
            for key in preferredKeys {
                if parts.count >= 2 { break }
                if let v = obj[key] {
                    let strVal: String
                    if let s = v as? String { strVal = s }
                    else { strVal = String(describing: v) }
                    parts.append("\(key)=\(strVal)")
                }
            }
            if !parts.isEmpty {
                let joined = parts.joined(separator: " ")
                if joined.count <= 60 { return joined }
                return String(joined.prefix(60)) + "…"
            }
        }
        let trimmed = jsonArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    /// Internal dispatch body (formerly the body of `execute`). Kept separate so
    /// `withTelemetry` can wrap the whole thing uniformly.
    private func executeBody(_ call: ToolCall) async throws -> ToolResultMessage {
        // Special cases for tools that return ToolResultMessage with file attachment for multimodal injection
        switch call.function.name {
        case "read_file":
            return await executeReadFile(call)
        case "shortcuts":
            return await executeShortcuts(call)
        case "generate_image":
            return await executeGenerateImage(call)
        case "run_shortcut":
            return await executeRunShortcut(call)
        case "web_search":
            return try await executeWebSearch(call)
        case "web_research_sweep":
            return try await executeDeepResearch(call)
        case "Agent":
            return await executeAgentToolResult(call)
        default:
            break
        }
        
        let content: String
        
        switch call.function.name {
        // Filesystem tool surface
        case "write_file":
            content = await executeWriteFile(call)
        case "edit_file":
            content = await executeEditFile(call)
        case "apply_patch":
            content = await executeApplyPatch(call)
        case "grep":
            content = await executeGrep(call)
        case "glob":
            content = await executeGlob(call)
        case "list_dir":
            content = await executeListDir(call)
        case "list_recent_files":
            content = await executeListRecentFiles(call)
        case "bash":
            content = await executeBash(call)
        case "bash_manage":
            content = await executeBashManage(call)
        case "todo_write":
            content = await executeTodoWrite(call)
        case "subagent_manage":
            content = await executeSubagentManage(call)
        case "lsp":
            content = await executeLSP(call)

        case "manage_reminders":
            content = try await executeManageReminders(call)

        case "view_conversation_chunk":
            content = await executeViewConversationChunk(call)

        case "skill":
            content = executeLoadSkill(call)

        case "tool_search":
            content = await executeToolSearch(call)
        case "mcp_call":
            content = await executeMcpCall(call)

        // generate_image is handled in the special multimodal injection switch above

        case "web_fetch":
            content = await executeWebFetch(call)
            
        case "send_document_to_chat":
            content = await executeSendDocumentToChat(call)
            
        // Shortcuts Tools
        case "list_shortcuts":
            content = await executeListShortcuts(call)
        // run_shortcut is handled above with file attachment for media output

        default:
            if MCPRegistry.isMCPPrefixed(call.function.name) {
                content = await MCPRegistry.shared.callTool(
                    prefixedName: call.function.name,
                    argumentsJSON: call.function.arguments
                )
            } else {
                content = "{\"error\": \"Unknown tool: \(call.function.name)}\"}"
            }
        }
        
        return ToolResultMessage(toolCallId: call.id, content: content)
    }
    
    /// Execute multiple tool calls in parallel
    func executeParallel(_ calls: [ToolCall]) async throws -> [ToolResultMessage] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ToolResultMessage.self) { group in
            for call in calls {
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.execute(call)
                }
            }
            
            var results: [ToolResultMessage] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeWebSearch(_ call: ToolCall) async throws -> ToolResultMessage {
        // Parse arguments from JSON string
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse web_search arguments\"}")
        }
        
        do {
            let result = try await webOrchestrator.executeForTool(query: args.query)
            return ToolResultMessage(
                toolCallId: call.id,
                content: result.asJSON(),
                spendUSD: result.spendUSD
            )
        } catch {
            let spendUSD = (error as? ResearchExecutionError)?.spendUSD
            return ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\": \"Web search failed: \(error.localizedDescription)\"}",
                spendUSD: spendUSD
            )
        }
    }

    private func executeDeepResearch(_ call: ToolCall) async throws -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse web_research_sweep arguments\"}")
        }

        do {
            let result = try await webOrchestrator.executeDeepResearchForTool(query: args.query)
            return ToolResultMessage(
                toolCallId: call.id,
                content: result.asJSON(),
                spendUSD: result.spendUSD
            )
        } catch {
            let spendUSD = (error as? ResearchExecutionError)?.spendUSD
            return ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\": \"Deep research failed: \(error.localizedDescription)\"}",
                spendUSD: spendUSD
            )
        }
    }
    
    private func executeManageReminders(_ call: ToolCall) async throws -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageRemindersArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_reminders arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "set":
            guard let triggerDatetime = args.triggerDatetime,
                  let prompt = args.prompt,
                  !triggerDatetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'set', trigger_datetime and prompt are required"}"#
            }

            guard let date = parseISO8601Date(triggerDatetime) else {
                return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-02-01T09:00:00') or ISO 8601 with offset."}"#
            }

            guard date > Date() else {
                return #"{"error":"Reminder datetime must be in the future"}"#
            }

            if let recurrenceRaw = args.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !recurrenceRaw.isEmpty,
               parseRecurrenceType(recurrenceRaw) == nil {
                return #"{"error":"Invalid recurrence. Use daily, weekly, monthly, every_X_minutes, or every_X_hours."}"#
            }

            let recurrence = parseRecurrenceType(args.recurrence)

            let reminder = await ReminderService.shared.addReminder(triggerDate: date, prompt: prompt, recurrence: recurrence)
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .full
            dateFormatter.timeStyle = .short
            var message = "Reminder successfully scheduled"
            if let rec = recurrence {
                message += " (recurring: \(rec.description))"
            }
            let result = SetReminderResult(
                success: true,
                reminderId: reminder.id.uuidString,
                scheduledFor: dateFormatter.string(from: date),
                message: message
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Reminder scheduled"}"#

        case "list":
            let reminders = await ReminderService.shared.getPendingReminders()
            if reminders.isEmpty {
                return #"{"success": true, "count": 0, "reminders": [], "message": "No pending reminders"}"#
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            let localISOFormatter = DateFormatter()
            localISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            localISOFormatter.timeZone = TimeZone.current

            var jsonEntries: [String] = []
            for reminder in reminders {
                let idStr = reminder.id.uuidString
                let triggerLocal = localISOFormatter.string(from: reminder.triggerDate)
                let triggerReadable = dateFormatter.string(from: reminder.triggerDate)
                let promptEscaped = reminder.prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")

                var entryFields = [
                    "\"id\": \"\(idStr)\"",
                    "\"trigger_datetime\": \"\(triggerLocal)\"",
                    "\"trigger_readable\": \"\(triggerReadable)\"",
                    "\"prompt\": \"\(promptEscaped)\""
                ]

                if let rec = reminder.recurrence {
                    entryFields.append("\"recurrence\": \"\(rec.description)\"")
                }
                jsonEntries.append("{\(entryFields.joined(separator: ", "))}")
            }

            let remindersJson = jsonEntries.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(reminders.count), \"reminders\": [\(remindersJson)], \"message\": \"Found \(reminders.count) pending reminder(s)\"}"

        case "delete":
            let pendingReminders = await ReminderService.shared.getPendingReminders()
            var targetIDs: [String] = []
            var deleteMode = "single"

            if args.deleteAll == true {
                targetIDs = pendingReminders.map { $0.id.uuidString }
                deleteMode = "all"
            } else if args.deleteRecurring == true {
                if let recurrenceRaw = args.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !recurrenceRaw.isEmpty,
                   parseRecurrenceType(recurrenceRaw) == nil {
                    return #"{"error":"Invalid recurrence filter for delete_recurring. Use daily, weekly, monthly, every_X_minutes, or every_X_hours."}"#
                }

                let recurrenceFilter = parseRecurrenceType(args.recurrence)
                targetIDs = pendingReminders.filter { reminder in
                    guard let recurrence = reminder.recurrence else { return false }
                    if let recurrenceFilter {
                        return recurrence == recurrenceFilter
                    }
                    return true
                }.map { $0.id.uuidString }
                deleteMode = "recurring"
            } else if let reminderIds = args.reminderIds, !reminderIds.isEmpty {
                targetIDs = reminderIds
                deleteMode = "batch"
            } else if let reminderId = args.reminderId, !reminderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                targetIDs = [reminderId]
                deleteMode = "single"
            } else {
                return #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#
            }

            let normalizedTargetIDs = Array(NSOrderedSet(array: targetIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })) as? [String] ?? []

            if normalizedTargetIDs.isEmpty {
                return #"{"error":"No valid reminder IDs provided for deletion"}"#
            }

            var deletedCount = 0
            var notFoundCount = 0
            var invalidIDs: [String] = []

            for idString in normalizedTargetIDs {
                guard let uuid = UUID(uuidString: idString) else {
                    invalidIDs.append(idString)
                    continue
                }
                let success = await ReminderService.shared.deleteReminder(id: uuid)
                if success {
                    deletedCount += 1
                } else {
                    notFoundCount += 1
                }
            }

            if deleteMode == "single" && normalizedTargetIDs.count == 1 && invalidIDs.isEmpty {
                if deletedCount == 1 {
                    return #"{"success":true,"message":"Reminder deleted successfully","deleted_count":1}"#
                }
                return #"{"error":"Reminder not found with the specified ID"}"#
            }

            let invalidIDsJSON = invalidIDs
                .map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            let message = "Deleted \(deletedCount) reminder(s). \(notFoundCount) not found. \(invalidIDs.count) invalid ID(s)."
            return """
            {"success": true, "mode": "\(deleteMode)", "deleted_count": \(deletedCount), "not_found_count": \(notFoundCount), "invalid_ids": [\(invalidIDsJSON)], "message": "\(message)"}
            """

        default:
            return #"{"error":"Invalid action. Supported actions: set, list, delete"}"#
        }
    }
    // MARK: - Helpers
    
    private func parseISO8601Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try full ISO 8601 with timezone offset first
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) { return date }

        // Fall back to local time (no offset) — parse in system timezone
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            localFormatter.dateFormat = format
            if let date = localFormatter.date(from: trimmed) { return date }
        }

        return nil
    }

    private func parseRecurrenceType(_ rawValue: String?) -> RecurrenceType? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "daily":
            return .daily
        case "weekly":
            return .weekly
        case "monthly":
            return .monthly
        default:
            if rawValue.hasPrefix("every_") && rawValue.hasSuffix("_minutes") {
                let numberPart = rawValue
                    .replacingOccurrences(of: "every_", with: "")
                    .replacingOccurrences(of: "_minutes", with: "")
                if let minutes = Int(numberPart), minutes > 0 {
                    return .custom(minutes: minutes)
                }
            }
            if rawValue.hasPrefix("every_") && rawValue.hasSuffix("_hours") {
                let numberPart = rawValue
                    .replacingOccurrences(of: "every_", with: "")
                    .replacingOccurrences(of: "_hours", with: "")
                if let hours = Int(numberPart), hours > 0 {
                    return .custom(minutes: hours * 60)
                }
            }
            return nil
        }
    }
    
    // MARK: - Conversation History Viewing
    
    private func executeViewConversationChunk(_ call: ToolCall) async -> String {
        let pageSize = 15
        
        // Parse arguments (chunk_id is optional; page applies to listing mode)
        var chunkIdStr: String? = nil
        var requestedPage = 1
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(ViewConversationChunkArguments.self, from: argsData) {
            chunkIdStr = args.chunkId?.trimmingCharacters(in: .whitespaces)
            requestedPage = max(args.page ?? 1, 1)
        }
        
        // Get all chunks
        let allChunks = await archiveService.getAllChunks()
        
        // MODE 1: List older chunk summaries not already shown in context
        if chunkIdStr == nil || chunkIdStr?.isEmpty == true {
            if allChunks.isEmpty {
                return "{\"success\": true, \"message\": \"No archived conversation chunks yet. Chunks are created as conversations grow.\"}"
            }
            
            let inContextChunkIds = Set(
                await archiveService
                    .getRecentChunkSummaries()
                    .map { $0.id }
            )
            
            let historicalChunks = allChunks.filter { !inContextChunkIds.contains($0.id) }
            if historicalChunks.isEmpty {
                return "{\"success\": true, \"message\": \"No older archived chunks outside the summaries already in context.\"}"
            }
            
            let sortedChunks = historicalChunks.sorted { lhs, rhs in
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate > rhs.endDate
                }
                return lhs.startDate > rhs.startDate
            }
            
            let totalPages = max(1, Int(ceil(Double(sortedChunks.count) / Double(pageSize))))
            if requestedPage > totalPages {
                return "{\"error\": \"Invalid page \(requestedPage). Available pages: 1-\(totalPages).\"}"
            }
            
            let startIndex = (requestedPage - 1) * pageSize
            let endIndex = min(startIndex + pageSize, sortedChunks.count)
            let pageChunks = Array(sortedChunks[startIndex..<endIndex])
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            
            var output = """
            === ARCHIVED CONVERSATION CHUNKS (OLDER THAN IN-CONTEXT SUMMARIES) ===
            Page: \(requestedPage)/\(totalPages), ordered newest to oldest
            Showing: \(pageChunks.count) of \(sortedChunks.count) older chunk(s) (15 per page)
            Excluded (already in context): \(inContextChunkIds.count) chunk(s)
            
            """
            
            for chunk in pageChunks {
                let shortId = String(chunk.id.uuidString.prefix(8))
                let dateRange = "\(dateFormatter.string(from: chunk.startDate)) - \(dateFormatter.string(from: chunk.endDate))"
                let typeLabel = chunk.type == .consolidated ? "CONSOLIDATED" : "TEMPORARY"
                
                output += """
                
                [\(shortId)] (\(typeLabel), \(chunk.sizeLabel))
                Period: \(dateRange)
                Messages: \(chunk.messageCount)
                Summary: \(chunk.summary)
                
                ---
                """
            }
            
            output += "\n\nTo view full messages from a chunk, call: view_conversation_chunk(chunk_id: \"<8-char ID>\")"
            if requestedPage < totalPages {
                output += "\nNext page: view_conversation_chunk(page: \(requestedPage + 1))"
            }
            if requestedPage > 1 {
                output += "\nPrevious page: view_conversation_chunk(page: \(requestedPage - 1))"
            }
            
            return output
        }
        
        // MODE 2: View specific chunk content (when chunk_id is provided)
        do {
            guard let chunk = allChunks.first(where: { 
                $0.id.uuidString == chunkIdStr || 
                $0.id.uuidString.hasPrefix(chunkIdStr!) ||
                $0.id.uuidString.lowercased().hasPrefix(chunkIdStr!.lowercased())
            }) else {
                return "{\"error\": \"Chunk not found with ID: \(chunkIdStr!). Call view_conversation_chunk() without arguments to see all available chunks.\"}"
            }
            
            // Get the full chunk content
            let content = try await archiveService.getChunkContent(chunkId: chunk.id)
            
            // Format the date range for context
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            
            let header = """
            === CHUNK DETAILS ===
            ID: \(chunk.id.uuidString)
            Type: \(chunk.sizeLabel) (\(chunk.type == .temporary ? "temporary" : "consolidated"))
            Period: \(dateFormatter.string(from: chunk.startDate)) to \(dateFormatter.string(from: chunk.endDate))
            Messages: \(chunk.messageCount)
            
            === CHUNK MESSAGES ===
            
            """
            
            return header + content
        } catch {
            return "{\"error\": \"Failed to load chunk: \(error.localizedDescription)\"}"
        }
    }

    // MARK: - Skills

    /// Load a curated skill from `~/LocalAgent/skills/` and return its body.
    /// Read-only by design: the agent cannot create or modify skills. If the
    /// skill is missing, return the current index so the agent can recover
    /// and pick a valid name.
    private nonisolated func executeLoadSkill(_ call: ToolCall) -> String {
        struct Args: Decodable { let skill_name: String? }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let name = args.skill_name?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return "{\"error\": \"skill_name is required\"}"
        }

        guard let skill = SkillsRegistry.skill(named: name) else {
            let available = SkillsRegistry.allSkills().map { $0.name }
            let availableList = available.isEmpty
                ? "(no skills installed)"
                : available.joined(separator: ", ")
            return "{\"error\": \"Skill '\(name)' not found. Available: \(availableList)\"}"
        }

        // Match Claude Code's skill-loading contract so agentskills.io skills
        // imported from the wider ecosystem work unchanged:
        //   1. Substitute ${CLAUDE_SKILL_DIR} with the real absolute path.
        //   2. Prepend "Base directory for this skill: <path>" so bare
        //      filename references in the body (e.g. "see REFERENCE.md")
        //      have a resolution anchor.
        // Verified against cli.js 2.1.112 — exact same two operations.
        var body = skill.body
        if let dir = skill.directoryURL {
            body = body.replacingOccurrences(
                of: "${CLAUDE_SKILL_DIR}",
                with: dir.path
            )
        }

        var result: String
        if let dir = skill.directoryURL {
            result = "Base directory for this skill: \(dir.path)\n\n" + body
        } else {
            result = "Skill '\(skill.name)' loaded. Follow the procedure below — combine with your own judgment, don't recite verbatim.\n\n" + body
        }

        if !skill.assets.isEmpty {
            var lines: [String] = ["", "", "---", "", "**Assets bundled with this skill** (invoke via the bash tool using the absolute paths below):"]
            for asset in skill.assets {
                lines.append("- `\(asset.path)`")
            }
            result += lines.joined(separator: "\n")
        }
        return result
    }

    // MARK: - Deferred MCP Discovery

    private func executeToolSearch(_ call: ToolCall) async -> String {
        struct Args: Decodable { let server: String? }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let server = args.server?.trimmingCharacters(in: .whitespaces),
              !server.isEmpty else {
            return "{\"error\": \"'server' parameter is required.\"}"
        }
        guard let result = await MCPRegistry.shared.toolSchemasForServer(server) else {
            return "{\"error\": \"MCP server '\(server)' is not available. It may not be installed, or it failed to start.\"}"
        }
        return result
    }

    private func executeMcpCall(_ call: ToolCall) async -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"error\": \"Failed to parse mcp_call arguments as JSON object.\"}"
        }
        guard let server = raw["server"] as? String, !server.isEmpty else {
            return "{\"error\": \"'server' parameter is required.\"}"
        }
        guard let tool = raw["tool"] as? String, !tool.isEmpty else {
            return "{\"error\": \"'tool' parameter is required.\"}"
        }
        let arguments = raw["arguments"] as? [String: Any] ?? [:]

        // Construct the prefixed name and serialize arguments for the standard
        // MCPRegistry.callTool path — reuses all existing validation & dispatch.
        let prefixedName = "mcp__\(server)__\(tool)"
        let argsJSON: String
        if arguments.isEmpty {
            argsJSON = "{}"
        } else if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                  let str = String(data: argsData, encoding: .utf8) {
            argsJSON = str
        } else {
            return "{\"error\": \"Failed to serialize arguments to JSON.\"}"
        }
        return await MCPRegistry.shared.callTool(prefixedName: prefixedName, argumentsJSON: argsJSON)
    }
}

// MARK: - Tool Argument Types

private func normalizeRecipientList(_ recipients: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    
    for recipient in recipients {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { continue }
        normalized.append(trimmed)
    }
    
    return normalized
}

private func parseRecipientsFromString(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    
    if let data = trimmed.data(using: .utf8),
       let parsed = try? JSONDecoder().decode([String].self, from: data) {
        return normalizeRecipientList(parsed)
    }
    
    let split = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
    return normalizeRecipientList(split)
}

private func decodeRecipients<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [String] {
    if let array = try? container.decodeIfPresent([String].self, forKey: key) {
        return normalizeRecipientList(array ?? [])
    }
    
    if let value = try? container.decode(String.self, forKey: key) {
        return parseRecipientsFromString(value)
    }
    
    return []
}

private func isLikelyValidEmailAddress(_ address: String) -> Bool {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains("@") && trimmed.contains(".")
}

private func allEmailAddressesAreValid(_ addresses: [String]) -> Bool {
    addresses.allSatisfy { isLikelyValidEmailAddress($0) }
}

struct WebSearchArguments: Codable {
    let query: String
}

struct BashWatchArguments: Codable {
    let handle: String
    let pattern: String
    let limit: Int?
}

struct ManageRemindersArguments: Codable {
    let action: String
    let triggerDatetime: String?
    let prompt: String?
    let recurrence: String?
    let reminderId: String?
    let reminderIds: [String]?
    let deleteAll: Bool?
    let deleteRecurring: Bool?
    
    enum CodingKeys: String, CodingKey {
        case action
        case triggerDatetime = "trigger_datetime"
        case prompt
        case recurrence
        case reminderId = "reminder_id"
        case reminderIds = "reminder_ids"
        case deleteAll = "delete_all"
        case deleteRecurring = "delete_recurring"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        triggerDatetime = try container.decodeIfPresent(String.self, forKey: .triggerDatetime)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        recurrence = try container.decodeIfPresent(String.self, forKey: .recurrence)
        reminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        deleteAll = try container.decodeIfPresent(Bool.self, forKey: .deleteAll)
        deleteRecurring = try container.decodeIfPresent(Bool.self, forKey: .deleteRecurring)

        if let array = try? container.decodeIfPresent([String].self, forKey: .reminderIds) {
            reminderIds = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .reminderIds))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                reminderIds = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                reminderIds = csv.isEmpty ? nil : csv
            }
        } else {
            reminderIds = nil
        }
    }
}

struct SetReminderResult: Codable {
    let success: Bool
    let reminderId: String
    let scheduledFor: String
    let message: String
}



// MARK: - Calendar Tool Argument Types

struct ManageCalendarArguments: Codable {
    let action: String
    let includePast: Bool?
    let eventId: String?
    let title: String?
    let datetime: String?
    let notes: String?
    
    enum CodingKeys: String, CodingKey {
        case action
        case includePast = "include_past"
        case eventId = "event_id"
        case title
        case datetime
        case notes
    }
}

// MARK: - Calendar Tool Result Types

struct CalendarEventResponse: Codable {
    let id: String
    let title: String
    let datetime: String
    let datetimeISO: String
    let notes: String?
    let isPast: Bool
}

struct ViewCalendarResult: Codable {
    let success: Bool
    let eventCount: Int
    let events: [CalendarEventResponse]
    let message: String
}

struct AddCalendarEventResult: Codable {
    let success: Bool
    let eventId: String
    let scheduledFor: String
    let message: String
}

// MARK: - Conversation History View Types

struct ViewConversationChunkArguments: Codable {
    let chunkId: String?
    let page: Int?
    
    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
        case page
    }
}

// MARK: - Email Tool Types

// MARK: - Email Tool Execution Extension

struct ListDocumentsResult: Codable {
    let success: Bool
    let documentCount: Int
    let returnedCount: Int
    let hasMore: Bool
    let nextCursor: String?
    let order: String
    let cursorUsed: String?
    let documents: [DocumentInfo]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case documentCount
        case returnedCount = "returned_count"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case order
        case cursorUsed = "cursor_used"
        case documents
        case message
    }
}

struct DocumentInfo: Codable {
    let filename: String
    let sizeKB: Int
    let type: String
    let createdAt: String
    let lastOpenedAt: String?
    let createdAtSource: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case sizeKB
        case type
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case createdAtSource = "created_at_source"
    }
}

struct ReadDocumentArguments: Decodable {
    let documentFilenames: [String]
    
    enum CodingKeys: String, CodingKey {
        case documentFilename = "document_filename"
        case documentFilenames = "document_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let parsedFilenames: [String]
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            parsedFilenames = array
        } else if let raw = (try? container.decode(String.self, forKey: .documentFilenames))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                parsedFilenames = parsed
            } else {
                parsedFilenames = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } else if let singleFilename = try? container.decode(String.self, forKey: .documentFilename) {
            parsedFilenames = [singleFilename]
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "Provide document_filenames (array/JSON array string/CSV) or legacy document_filename"
            )
        }
        
        let normalized = parsedFilenames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var seen: Set<String> = []
        let deduplicated = normalized.filter { seen.insert($0).inserted }
        
        guard !deduplicated.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "No document filenames provided"
            )
        }
        
        documentFilenames = deduplicated
    }
}

struct ReadDocumentItemResult: Codable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType
        case sizeBytes
        case message
    }
}

struct ReadDocumentResult: Codable {
    let success: Bool
    let loadedCount: Int
    let maxDocumentsPerCall: Int
    let documents: [ReadDocumentItemResult]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case loadedCount
        case maxDocumentsPerCall = "max_documents_per_call"
        case documents
        case message
    }
}

// MARK: - Document Tool Execution Extension

extension ToolExecutor {
    private var documentsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("LocalAgent/documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var documentsLastOpenedIndexURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("LocalAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("documents_last_opened.json")
    }

    private func loadDocumentsLastOpenedIndex() -> [String: Int64] {
        guard let data = try? Data(contentsOf: documentsLastOpenedIndexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func saveDocumentsLastOpenedIndex(_ index: [String: Int64]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: documentsLastOpenedIndexURL, options: .atomic)
    }

    private func recordDocumentOpened(filename: String, openedAt: Date = Date()) {
        var index = loadDocumentsLastOpenedIndex()
        index[filename] = Int64((openedAt.timeIntervalSince1970 * 1000.0).rounded())
        saveDocumentsLastOpenedIndex(index)
    }
    
    private func parseListDocumentsCursor(_ cursor: String) -> Int? {
        let trimmed = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if let offset = Int(trimmed), offset >= 0 {
            return offset
        }
        
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("offset:") {
            let value = trimmed.dropFirst("offset:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let offset = Int(value), offset >= 0 {
                return offset
            }
        }
        
        return nil
    }
    private func getMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
    
    private func isInlineMimeTypeSupportedForLLM(_ mimeType: String) -> Bool {
        let normalized = mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()
        
        if normalized.hasPrefix("image/") {
            return true
        }
        
        let supported: Set<String> = [
            "application/pdf",
            "text/plain",
            "text/markdown",
            "application/json",
            "text/csv",
            "text/html",
            "application/xml"
        ]
        return supported.contains(normalized)
    }
}

// MARK: - Download Email Attachment Types

// MARK: - Batch Download Types

// MARK: - Get Email Thread Types

// MARK: - Get Email Thread Execution

extension ToolExecutor {
    
}

// MARK: - Contact Tool Argument Types

// MARK: - Contact Tool Result Types

struct ContactResponse: Codable {
    let id: String
    let firstName: String
    let lastName: String?
    let fullName: String
    let email: String?
    let phone: String?
    let organization: String?
}

struct FindContactResult: Codable {
    let success: Bool
    let contactCount: Int
    let contacts: [ContactResponse]
    let message: String
}

struct AddContactResult: Codable {
    let success: Bool
    let contactId: String
    let fullName: String
    let message: String
}

struct ListContactsResult: Codable {
    let success: Bool
    let totalCount: Int
    let returnedCount: Int
    let limit: Int
    let nextCursor: String?
    let cursorUsed: String?
    let contacts: [ContactResponse]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case totalCount = "total_count"
        case returnedCount = "returned_count"
        case limit
        case nextCursor = "next_cursor"
        case cursorUsed = "cursor_used"
        case contacts
        case message
    }
}

struct DeleteContactsResult: Codable {
    let success: Bool
    let deletedCount: Int
    let failedIds: [String]?
    let message: String
}

// MARK: - Image Generation Tool

extension ToolExecutor {
    /// Store for generated images to be sent after tool execution
    private static var pendingImages: [(data: Data, mimeType: String, prompt: String)] = []
    
    /// Store for documents to be sent after tool execution
    private static var pendingDocuments: [(data: Data, filename: String, mimeType: String, caption: String?)] = []
    
    /// Legacy transient store for downloaded attachment bytes. ConversationManager
    /// drains this after each turn; durable descriptions are generated at prune time.
    private static var pendingFilesForDescription: [(filename: String, data: Data, mimeType: String)] = []
    
    /// Store for downloaded filenames to add to Message history
    private static var pendingDownloadedFilenames: [String] = []
    
    /// Get and clear pending images
    static func getPendingImages() -> [(data: Data, mimeType: String, prompt: String)] {
        let images = pendingImages
        pendingImages = []
        return images
    }
    
    /// Get and clear pending documents
    static func getPendingDocuments() -> [(data: Data, filename: String, mimeType: String, caption: String?)] {
        let documents = pendingDocuments
        pendingDocuments = []
        return documents
    }
    
    /// Get and clear transient downloaded attachment bytes
    static func getPendingFilesForDescription() -> [(filename: String, data: Data, mimeType: String)] {
        let files = pendingFilesForDescription
        pendingFilesForDescription = []
        return files
    }
    
    /// Get and clear downloaded filenames to store in Message history
    static func getPendingDownloadedFilenames() -> [String] {
        let filenames = pendingDownloadedFilenames
        pendingDownloadedFilenames = []
        return filenames
    }
    
    /// Clear all pending tool outputs (used for cancellation / interruption)
    static func clearPendingToolOutputs() {
        pendingImages = []
        pendingDocuments = []
        pendingFilesForDescription = []
        pendingDownloadedFilenames = []
    }
    
    /// Queue a downloaded/generated filename for history and drainable transient bytes
    static func queueFileForDescription(filename: String, data: Data, mimeType: String) {
        pendingFilesForDescription.append((filename: filename, data: data, mimeType: mimeType))
        // Also track filename for Message history
        pendingDownloadedFilenames.append(filename)
    }
    
    /// Images directory for loading source images
    private var imagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LocalAgent/images", isDirectory: true)
    }
    
    func executeGenerateImage(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GenerateImageArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse generate_image arguments\"}")
        }
        
        // Check if Gemini API is configured
        guard await GeminiImageService.shared.isConfigured() else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Gemini API key is not configured. Please add your Google API key in Settings.\"}")
        }
        
        // Load source image if provided
        var sourceImageData: Data? = nil
        var sourceMimeType: String? = nil
        
        if let sourceImage = args.sourceImage, !sourceImage.isEmpty {
            let imageURL = imagesDirectory.appendingPathComponent(sourceImage)
            
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Source image not found: \(sourceImage). Make sure the filename is correct.\"}")
            }
            
            do {
                sourceImageData = try Data(contentsOf: imageURL)
                // Determine MIME type from extension
                let ext = imageURL.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg":
                    sourceMimeType = "image/jpeg"
                case "png":
                    sourceMimeType = "image/png"
                case "gif":
                    sourceMimeType = "image/gif"
                case "webp":
                    sourceMimeType = "image/webp"
                default:
                    sourceMimeType = "image/jpeg"
                }
            } catch {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to load source image: \(error.localizedDescription)\"}")
            }
        }
        
        let requestedSize = args.size?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImageSize = GeminiImageSize.parse(requestedSize)
        if let requestedSize, !requestedSize.isEmpty, normalizedImageSize == nil {
            let escapedSize = requestedSize
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\": \"Invalid size '\(escapedSize)'. Supported values: 1K, 2K, 4K.\"}"
            )
        }
        
        do {
            let (imageData, mimeType, spendUSD) = try await GeminiImageService.shared.generateImage(
                prompt: args.prompt,
                sourceImageData: sourceImageData,
                sourceMimeType: sourceMimeType,
                imageSize: normalizedImageSize?.rawValue
            )
            
            // Save generated image to documents folder so Gemini can reference it later
            let fileExtension = mimeType.contains("png") ? "png" : "jpg"
            let fileName = "generated_\(UUID().uuidString).\(fileExtension)"
            let documentsURL = documentsDirectory.appendingPathComponent(fileName)
            let imagesURL = imagesDirectory.appendingPathComponent(fileName)
            
            do {
                try imageData.write(to: documentsURL)
                try imageData.write(to: imagesURL)
                print("[ToolExecutor] Saved generated image: \(fileName) (\(imageData.count) bytes)")
            } catch {
                print("[ToolExecutor] Failed to save generated image: \(error)")
                // Continue anyway - we can still send to Telegram and inject multimodally
            }
            
            // Store the image for sending to Telegram after the tool response
            ToolExecutor.pendingImages.append((imageData, mimeType, args.prompt))
            
            // Queue file for description generation (like email attachments)
            ToolExecutor.queueFileForDescription(filename: fileName, data: imageData, mimeType: mimeType)
            
            let isEdit = sourceImageData != nil
            
            // Create file attachment for multimodal injection (LLM can see the generated image)
            let attachment = FileAttachment(data: imageData, mimeType: mimeType, filename: fileName, sourcePath: documentsURL.path)
            print("[ToolExecutor] Created FileAttachment for generated image: \(fileName) (\(mimeType), \(imageData.count) bytes)")
            
            // Result text (image will be injected as multimodal content)
            let result = """
            {"success": true, "filename": "\(fileName)", "mimeType": "\(mimeType)", "sizeBytes": \(imageData.count), "resolution": "\(normalizedImageSize?.rawValue ?? "default")", "message": "\(isEdit ? "Image transformed" : "Image generated") successfully. You can now see and analyze the result."}
            """
            
            return ToolResultMessage(
                toolCallId: call.id,
                content: result,
                fileAttachment: attachment,
                spendUSD: spendUSD
            )
        } catch {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Image generation failed: \(error.localizedDescription)\"}")
        }
    }
    
    // MARK: - macOS Shortcuts Tool Implementations

    private func compactJSONObject(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.compactMapValues { value in
            switch value {
            case let string as String: return string
            case let int as Int: return int
            case let bool as Bool: return bool
            case let strings as [String]: return strings
            default: return nil
            }
        }
    }

    private func syntheticToolCall(from call: ToolCall, name: String, arguments: [String: Any]) -> ToolCall? {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return ToolCall(
            id: call.id,
            type: call.type,
            function: FunctionCall(name: name, arguments: json)
        )
    }

    private func executeShortcuts(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ShortcutsArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to parse shortcuts arguments"}"#)
        }

        switch args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list":
            let content = await executeListShortcuts(call)
            return ToolResultMessage(toolCallId: call.id, content: content)

        case "run":
            guard let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error": "shortcuts action='run' requires a non-empty name"}"#)
            }

            guard let syntheticCall = syntheticToolCall(
                from: call,
                name: "run_shortcut",
                arguments: compactJSONObject([
                    "name": name,
                    "input": args.input?.trimmingCharacters(in: .whitespacesAndNewlines)
                ])
            ) else {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to prepare shortcuts run arguments"}"#)
            }

            return await executeRunShortcut(syntheticCall)

        default:
            return ToolResultMessage(
                toolCallId: call.id,
                content: #"{"error": "Unknown shortcuts action. Use 'list' or 'run'."}"#
            )
        }
    }
    
    private func executeListShortcuts(_ call: ToolCall) async -> String {
        if Task.isCancelled {
            return #"{"error": "Shortcut listing cancelled"}"#
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            ToolExecutor.registerRunningProcess(process)
            defer { ToolExecutor.unregisterRunningProcess(process) }
            
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if process.isRunning {
                        process.interrupt()
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if process.isRunning {
                await Self.waitForProcessExit(process, timeoutNanoseconds: 500_000_000)
            }
            if process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    _ = kill(pid, SIGKILL)
                }
                await Self.waitForProcessExit(process, timeoutNanoseconds: 500_000_000)
            }
            
            if Task.isCancelled {
                return #"{"error": "Shortcut listing cancelled"}"#
            }
            
            if process.isRunning {
                return #"{"error": "Shortcut listing did not terminate cleanly"}"#
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                return "{\"error\": \"Failed to list shortcuts: \(errorOutput.isEmpty ? "Unknown error" : errorOutput)\"}"
            }
            
            // Parse the output - each line is a shortcut name
            let shortcuts = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            if shortcuts.isEmpty {
                return "{\"success\": true, \"count\": 0, \"shortcuts\": [], \"message\": \"No shortcuts found. Create shortcuts in the Shortcuts app.\"}"
            }
            
            let shortcutList = shortcuts.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(shortcuts.count), \"shortcuts\": [\(shortcutList)], \"message\": \"Found \(shortcuts.count) shortcut(s). Use shortcuts with action='run' and the exact name to execute.\"}"
        } catch {
            return "{\"error\": \"Failed to execute shortcuts command: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeRunShortcut(_ call: ToolCall) async -> ToolResultMessage {
        if Task.isCancelled {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Shortcut execution cancelled"}"#)
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(RunShortcutArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse run_shortcut arguments\"}")
        }
        
        let shortcutName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Shortcut name cannot be empty\"}")
        }
        
        let sandboxedTempDir = FileManager.default.temporaryDirectory
        
        // If input is provided, write it to the sandboxed temp dir (app owns it, CLI can read it)
        var inputFile: URL? = nil
        if let input = args.input, !input.isEmpty {
            inputFile = sandboxedTempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            do {
                try input.write(to: inputFile!, atomically: true, encoding: .utf8)
                print("[ToolExecutor] Input file written to: \(inputFile!.path)")
            } catch {
                print("[ToolExecutor] Failed to write input file: \(error)")
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to write input file: \(error.localizedDescription)\"}")
            }
        }
        
        let timeoutSeconds: Double = 120
        
        var finalOutputData = Data()
        var exitCode: Int32 = 0
        var appleEventsPermissionDenied = false
        var appleScriptErrorText = ""
        
        // PRIMARY: Use Shortcuts Events (AppleScript), which is working on this machine.
        print("[ToolExecutor] Starting shortcut '\(shortcutName)' via AppleScript Shortcuts Events")
        let appleScriptPrimary = await runShortcutViaAppleScript(name: shortcutName, input: args.input, timeoutSeconds: timeoutSeconds)
        exitCode = appleScriptPrimary.exitCode
        
        if appleScriptPrimary.exitCode == 0, !appleScriptPrimary.outputData.isEmpty {
            finalOutputData = appleScriptPrimary.outputData
            print("[ToolExecutor] AppleScript primary captured: \(finalOutputData.count) bytes")
        } else {
            appleScriptErrorText = appleScriptPrimary.errorText
            let normalizedAppleScriptError = appleScriptPrimary.errorText.lowercased()
            appleEventsPermissionDenied =
                normalizedAppleScriptError.contains("privilege violation") ||
                normalizedAppleScriptError.contains("(-10004)") ||
                normalizedAppleScriptError.contains("error -10004")
            
            if !appleScriptPrimary.errorText.isEmpty {
                print("[ToolExecutor] AppleScript primary error: \(appleScriptPrimary.errorText.prefix(500))")
                if appleEventsPermissionDenied {
                    print("[ToolExecutor] AppleScript indicates AppleEvents permission denial (-10004)")
                }
            } else {
                print("[ToolExecutor] AppleScript primary returned empty output; falling back to shortcuts CLI capture...")
            }
            
            // FALLBACK: CLI output capture paths (file, stdout, then pipe).
            let outputFilename = "shortcut_output_\(UUID().uuidString).txt"
            let outputFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFilename)
            let didCreateOutputFile = FileManager.default.createFile(
                atPath: outputFileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o666]
            )
            print("[ToolExecutor] Output file precreate at \(outputFileURL.path): \(didCreateOutputFile ? "ok" : "failed")")
            
            var processArguments = ["run", shortcutName]
            if let inputFile = inputFile {
                processArguments.append(contentsOf: ["--input-path", inputFile.path])
            }
            processArguments.append(contentsOf: ["--output-path", outputFileURL.path])
            
            print("[ToolExecutor] CLI fallback command: /usr/bin/shortcuts run '<shortcut name>' --output-path '<sandbox temp file>'")
            
            let primaryResult: (exitCode: Int32, stdoutData: Data, stderrData: Data) = await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = processArguments
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                process.terminationHandler = { proc in
                    ToolExecutor.unregisterRunningProcess(proc)
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (proc.terminationStatus, outData, errData))
                }
                
                do {
                    try process.run()
                    ToolExecutor.registerRunningProcess(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                        if process.isRunning {
                            process.terminate()
                            print("[ToolExecutor] Shortcut '\(shortcutName)' TIMED OUT")
                        }
                    }
                } catch {
                    print("[ToolExecutor] Failed to launch: \(error)")
                    continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                }
            }
            
            exitCode = primaryResult.exitCode
            print("[ToolExecutor] CLI fallback exit code: \(primaryResult.exitCode)")
            print("[ToolExecutor] CLI fallback stdout bytes: \(primaryResult.stdoutData.count)")
            print("[ToolExecutor] CLI fallback stderr bytes: \(primaryResult.stderrData.count)")
            if let stderrText = String(data: primaryResult.stderrData, encoding: .utf8), !stderrText.isEmpty {
                print("[ToolExecutor] CLI fallback stderr: \(stderrText.prefix(500))")
            }
            
            var fileOutputData = Data()
            for _ in 0..<20 {
                if let data = try? Data(contentsOf: outputFileURL), !data.isEmpty {
                    fileOutputData = data
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            
            if !fileOutputData.isEmpty {
                finalOutputData = fileOutputData
                print("[ToolExecutor] CLI fallback file captured: \(fileOutputData.count) bytes")
            } else if !primaryResult.stdoutData.isEmpty {
                finalOutputData = primaryResult.stdoutData
                print("[ToolExecutor] CLI fallback stdout captured: \(primaryResult.stdoutData.count) bytes")
            } else {
                print("[ToolExecutor] CLI fallback returned no output in file or stdout")
            }
            
            // Known CLI quirk fallback: omit --output-path and force a pipe (| cat).
            if finalOutputData.isEmpty && primaryResult.exitCode == 0 {
                let escapedName = shortcutName.replacingOccurrences(of: "'", with: "'\\''")
                var noOutputPathCommand = "/usr/bin/shortcuts run '\(escapedName)'"
                if let inputFile = inputFile {
                    let escapedPath = inputFile.path.replacingOccurrences(of: "'", with: "'\\''")
                    noOutputPathCommand += " --input-path '\(escapedPath)'"
                }
                noOutputPathCommand += " | /bin/cat"
                print("[ToolExecutor] Retrying CLI with no --output-path + pipe fallback...")
                
                let pipedFallback = await withCheckedContinuation { (continuation: CheckedContinuation<(exitCode: Int32, stdoutData: Data, stderrData: Data), Never>) in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", noOutputPathCommand]
                    
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    
                    process.terminationHandler = { proc in
                        ToolExecutor.unregisterRunningProcess(proc)
                        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: (proc.terminationStatus, outData, errData))
                    }
                    
                    do {
                        try process.run()
                        ToolExecutor.registerRunningProcess(process)
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                    } catch {
                        continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                    }
                }
                
                if !pipedFallback.stdoutData.isEmpty {
                    finalOutputData = pipedFallback.stdoutData
                    print("[ToolExecutor] Piped CLI fallback captured: \(finalOutputData.count) bytes")
                } else {
                    print("[ToolExecutor] Piped CLI fallback returned empty output")
                    if let fallbackErr = String(data: pipedFallback.stderrData, encoding: .utf8), !fallbackErr.isEmpty {
                        print("[ToolExecutor] Piped CLI fallback stderr: \(fallbackErr.prefix(500))")
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        
        // Clean up input file
        if let inputFile = inputFile { try? FileManager.default.removeItem(at: inputFile) }
        
        print("[ToolExecutor] Shortcut '\(shortcutName)' finished with exit code: \(exitCode)")
        print("[ToolExecutor] Final output: \(finalOutputData.count) bytes")
        
        // Check if output contains binary media (image) by checking magic bytes
        var fileAttachment: FileAttachment? = nil
        var outputInfo = ""
        
        if finalOutputData.count > 0 {
            let mimeType = detectMimeType(from: finalOutputData)
            
            if mimeType.hasPrefix("image/") {
                // Binary image output — save and create attachment for multimodal injection
                let fileExtension: String
                switch mimeType {
                case "image/png": fileExtension = "png"
                case "image/gif": fileExtension = "gif"
                case "image/webp": fileExtension = "webp"
                default: fileExtension = "jpg"
                }
                
                let savedFilename = "shortcut_\(UUID().uuidString).\(fileExtension)"
                let savedPath = documentsDirectory.appendingPathComponent(savedFilename)
                let imagePath = imagesDirectory.appendingPathComponent(savedFilename)
                
                try? finalOutputData.write(to: savedPath)
                try? finalOutputData.write(to: imagePath)
                
                fileAttachment = FileAttachment(data: finalOutputData, mimeType: mimeType, filename: savedFilename, sourcePath: savedPath.path)
                outputInfo = ", \"output_file\": {\"filename\": \"\(savedFilename)\", \"mimeType\": \"\(mimeType)\", \"sizeBytes\": \(finalOutputData.count), \"message\": \"Image output saved and visible for analysis\"}"
                
                print("[ToolExecutor] Shortcut produced image output: \(savedFilename) (\(finalOutputData.count) bytes)")
            } else {
                // Text output from stdout
                let textOutput = String(data: finalOutputData, encoding: .utf8) ?? ""
                if !textOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let escapedOutput = textOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "")
                    outputInfo = ", \"output\": \"\(escapedOutput)\""
                    print("[ToolExecutor] Shortcut text output: \(textOutput.prefix(200))")
                }
            }
        }
        
        // Build result
        let permissionDeniedNoOutput = appleEventsPermissionDenied && finalOutputData.isEmpty
        let success = (exitCode == 0) && !permissionDeniedNoOutput
        
        var result = "{\"success\": \(success), \"exit_code\": \(exitCode), \"shortcut\": \"\(shortcutName.replacingOccurrences(of: "\"", with: "\\\""))\""
        
        result += outputInfo
        
        if permissionDeniedNoOutput {
            result += ", \"error_code\": \"apple_events_permission_denied\""
        } else if success && finalOutputData.isEmpty {
            result += ", \"warning\": \"Shortcut executed but returned no output\""
        }
        
        if permissionDeniedNoOutput {
            let errorMessage = "AppleEvents permission denied while running Shortcuts Events (-10004). In System Settings > Privacy & Security > Automation, allow this app to control Shortcuts Events, then retry."
            let escapedMessage = errorMessage
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result += ", \"message\": \"\(escapedMessage)\""
            
            if !appleScriptErrorText.isEmpty {
                let escapedDetails = appleScriptErrorText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                result += ", \"details\": \"\(escapedDetails)\""
            }
        } else if success {
            result += ", \"message\": \"Shortcut '\(shortcutName)' executed successfully\""
        } else {
            result += ", \"message\": \"Shortcut '\(shortcutName)' failed with exit code \(exitCode)\""
        }
        
        result += "}"
        
        return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: fileAttachment)
    }
    
    /// Detect MIME type from file data by checking magic bytes
    private func detectMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "application/octet-stream" }
        
        let bytes = [UInt8](data.prefix(12))
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        
        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        
        // GIF: 47 49 46 38
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        
        // WebP: 52 49 46 46 ... 57 45 42 50
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count >= 12 {
            let webpBytes = [UInt8](data[8..<12])
            if webpBytes == [0x57, 0x45, 0x42, 0x50] {
                return "image/webp"
            }
        }
        
        // PDF: 25 50 44 46 (%PDF)
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        }
        
        // Check if it looks like text
        let textBytes = data.prefix(1024)
        if let _ = String(data: textBytes, encoding: .utf8) {
            // Appears to be valid UTF-8 text
            return "text/plain"
        }
        
        return "application/octet-stream"
    }
    
    private func runShortcutViaAppleScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        // Prefer in-process AppleScript so sandbox/TCC permissions apply to this app directly.
        let inProcessResult = await runShortcutViaInProcessAppleScript(name: name, input: input)
        if inProcessResult.exitCode == 0 || !inProcessResult.errorText.isEmpty {
            return inProcessResult
        }
        
        print("[ToolExecutor] In-process AppleScript returned empty output; trying osascript fallback...")
        let osascriptResult = await runShortcutViaOSAScript(name: name, input: input, timeoutSeconds: timeoutSeconds)
        if osascriptResult.exitCode == 0, !osascriptResult.outputData.isEmpty {
            return osascriptResult
        }
        if !osascriptResult.errorText.isEmpty {
            return osascriptResult
        }
        
        return inProcessResult
    }
    
    private func runShortcutViaInProcessAppleScript(name: String, input: String?) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        await MainActor.run {
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            
            let command: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            guard let script = NSAppleScript(source: command) else {
                return (-1, Data(), "Failed to create AppleScript object")
            }
            
            var errorInfo: NSDictionary?
            let resultDescriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? (errorInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "Unknown AppleScript error"
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int)
                    ?? (errorInfo["NSAppleScriptErrorNumber"] as? Int)
                    ?? -1
                return (Int32(number), Data(), "\(message) (\(number))")
            }
            
            if let text = resultDescriptor.stringValue, !text.isEmpty {
                return (0, Data(text.utf8), "")
            }
            
            let rawData = resultDescriptor.data
            if !rawData.isEmpty {
                return (0, rawData, "")
            }
            
            return (0, Data(), "")
        }
    }
    
    private func runShortcutViaOSAScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let scriptLine: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            let arguments = ["-l", "AppleScript", "-e", scriptLine]
            process.arguments = arguments
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            process.terminationHandler = { proc in
                ToolExecutor.unregisterRunningProcess(proc)
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, outData, errText))
            }
            
            do {
                try process.run()
                ToolExecutor.registerRunningProcess(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            } catch {
                continuation.resume(returning: (-1, Data(), error.localizedDescription))
            }
        }
    }
}

// MARK: - Image Generation Argument Types

struct GenerateImageArguments: Codable {
    let prompt: String
    let sourceImage: String?
    let size: String?
    
    enum CodingKeys: String, CodingKey {
        case prompt
        case sourceImage = "source_image"
        case size
    }
}

struct GenerateImageResult: Codable {
    let success: Bool
    let message: String
    let imageSize: Int
    let mimeType: String
    let generatedFilename: String
    
    enum CodingKeys: String, CodingKey {
        case success, message, mimeType
        case imageSize = "image_size"
        case generatedFilename = "generated_filename"
    }
}

// MARK: - Shortcuts Tool Argument Types

struct ShortcutsArguments: Codable {
    let action: String
    let name: String?
    let input: String?
}

struct RunShortcutArguments: Codable {
    let name: String
    let input: String?
}

// MARK: - URL Viewing and Download Tool Implementations

/// JSON-escape a string for safe inline interpolation into a JSON object literal.
/// Returns the value with surrounding quotes (e.g. `"hello\nworld"`).
fileprivate func jsonStringLit(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
       let str = String(data: data, encoding: .utf8),
       str.count >= 2 {
        return String(str.dropFirst().dropLast())
    }
    // Fallback: manual minimal escaping.
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

extension ToolExecutor {
    func executeWebFetch(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebFetchArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse web_fetch arguments. Required: url (string), prompt (string).\"}"
        }

        // Validate URL format
        guard args.url.hasPrefix("http://") || args.url.hasPrefix("https://") else {
            return "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}"
        }

        // Validate prompt non-empty
        let promptTrim = args.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptTrim.isEmpty else {
            return "{\"error\": \"web_fetch requires a non-empty prompt describing what to extract from the page.\"}"
        }

        do {
            let result = try await webOrchestrator.readUrlContent(url: args.url, prompt: promptTrim)
            // Returns a prompt-compressed excerpt plus image metadata (captions, URLs)
            // LLM can use bash curl + read_file to download and view specific images
            return result.asJSON()
        } catch {
            return "{\"error\": \"Failed to fetch URL: \(error.localizedDescription)\"}"
        }
    }

}

// MARK: - URL Tool Argument Types

struct WebFetchArguments: Codable {
    let url: String
    let prompt: String
}

// MARK: - Send Document to Chat Tool

extension ToolExecutor {
    func executeSendDocumentToChat(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_document_to_chat arguments\"}"
        }

        // Resolve absolute path directly
        let documentURL = URL(fileURLWithPath: args.filePath)
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return "{\"error\": \"File not found: \(args.filePath). Use glob or list_dir to verify the path.\"}"
        }

        do {
            let documentData = try Data(contentsOf: documentURL)
            let filename = documentURL.lastPathComponent
            recordDocumentOpened(filename: filename)
            
            // Determine MIME type from extension
            let ext = documentURL.pathExtension.lowercased()
            let mimeType: String
            switch ext {
            case "pdf":
                mimeType = "application/pdf"
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "txt":
                mimeType = "text/plain"
            case "json":
                mimeType = "application/json"
            case "html":
                mimeType = "text/html"
            case "xml":
                mimeType = "application/xml"
            case "zip":
                mimeType = "application/zip"
            case "doc", "docx":
                mimeType = "application/msword"
            case "xls", "xlsx":
                mimeType = "application/vnd.ms-excel"
            default:
                mimeType = "application/octet-stream"
            }
            
            // Store the document for sending after the tool response
            ToolExecutor.pendingDocuments.append((
                data: documentData,
                filename: filename,
                mimeType: mimeType,
                caption: args.caption
            ))

            print("[ToolExecutor] Queued document for sending: \(args.filePath) (\(documentData.count) bytes)")

            let result = SendDocumentToChatResult(
                success: true,
                filePath: args.filePath,
                sizeBytes: documentData.count,
                message: "File '\(filename)' will be sent to the chat."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"message\": \"Document queued for sending\"}"
        } catch {
            return "{\"error\": \"Failed to read document: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - Send Document to Chat Types

struct SendDocumentToChatArguments: Codable {
    let filePath: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case caption
    }
}

struct SendDocumentToChatResult: Codable {
    let success: Bool
    let filePath: String
    let sizeBytes: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case success, message
        case filePath = "file_path"
        case sizeBytes = "size_bytes"
    }
}


// MARK: - Gmail Tool Argument Types

struct GmailReaderArguments: Codable {
    let action: String
    let query: String?
    let limit: Int?
    let messageId: String?
    let threadId: String?
    let attachmentId: String?
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case action, query, limit, filename
        case messageId = "message_id"
        case threadId = "thread_id"
        case attachmentId = "attachment_id"
    }
}

struct GmailComposerArguments: Codable {
    let action: String
    let to: String?
    let subject: String?
    let body: String?
    let threadId: String?
    let inReplyTo: String?
    let cc: [String]
    let bcc: [String]
    let attachmentFilenames: [String]?
    let messageId: String?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case action, to, subject, body, cc, bcc, comment
        case threadId = "thread_id"
        case inReplyTo = "in_reply_to"
        case attachmentFilenames = "attachment_filenames"
        case messageId = "message_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)

        if let array = try? container.decodeIfPresent([String].self, forKey: .attachmentFilenames) {
            attachmentFilenames = array
        } else if let jsonString = try? container.decodeIfPresent(String.self, forKey: .attachmentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            attachmentFilenames = parsed
        } else {
            attachmentFilenames = nil
        }
    }
}

struct GmailQueryArguments: Codable {
    let query: String?
    let limit: Int?
}

struct GmailSendArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let threadId: String?
    let inReplyTo: String?
    let cc: [String]
    let bcc: [String]
    let attachmentFilenames: [String]?
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
        case threadId = "thread_id"
        case inReplyTo = "in_reply_to"
        case attachmentFilenames = "attachment_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        
        // Handle attachmentFilenames as either an array or a JSON string
        if let array = try? container.decodeIfPresent([String].self, forKey: .attachmentFilenames) {
            attachmentFilenames = array
        } else if let jsonString = try? container.decodeIfPresent(String.self, forKey: .attachmentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            attachmentFilenames = parsed
        } else {
            attachmentFilenames = nil
        }
    }
}

struct GmailThreadArguments: Codable {
    let threadId: String
    
    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
    }
}

struct GmailForwardArguments: Codable {
    let to: String
    let messageId: String
    let comment: String?
    
    enum CodingKeys: String, CodingKey {
        case to
        case messageId = "message_id"
        case comment
    }
}

struct GmailAttachmentArguments: Codable {
    let messageId: String
    let attachmentId: String
    let filename: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case attachmentId = "attachment_id"
        case filename
    }
}

// MARK: - Agent (subagent) Tool

struct SubagentInvocationArguments: Decodable {
    let subagent_type: String
    let description: String
    let prompt: String
    let session_id: String?
    let close_session: String?
    let run_in_background: Bool?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case subagent_type
        case description
        case prompt
        case session_id
        case close_session
        case run_in_background
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subagent_type = try container.decode(String.self, forKey: .subagent_type)
        description = try container.decode(String.self, forKey: .description)
        prompt = try container.decode(String.self, forKey: .prompt)
        session_id = try container.decodeIfPresent(String.self, forKey: .session_id)
        close_session = try container.decodeIfPresent(String.self, forKey: .close_session)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .run_in_background) {
            run_in_background = boolValue
        } else if let rawValue = try? container.decodeIfPresent(String.self, forKey: .run_in_background) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                run_in_background = true
            case "false", "no", "0":
                run_in_background = false
            default:
                run_in_background = nil
            }
        } else {
            run_in_background = nil
        }
    }
}

extension ToolExecutor {
    /// Wraps executeAgent and surfaces subagent spend on the ToolResultMessage so
    /// ConversationManager's toolSpendUSD pass rolls it into the parent's cumulative
    /// daily/monthly counters and spend-limit enforcement. Background spawns still
    /// return spend = 0 here (the cost lands later via SubagentBackgroundRegistry →
    /// checkBackgroundSubagentCompletions).
    func executeAgentToolResult(_ call: ToolCall) async -> ToolResultMessage {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SubagentInvocationArguments.self, from: data) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid Agent tool arguments\"}")
        }

        guard let openRouter = openRouterService else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Agent tool not configured: OpenRouterService missing. ConversationManager must call toolExecutor.configureOpenRouter(...).\"}")
        }

        let imagesDir = subagentImagesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAgent/images", isDirectory: true)
        let documentsDir = subagentDocumentsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAgent/documents", isDirectory: true)
        let parentTools = AvailableTools.all(includeWebSearch: true)
        let runInBg = args.run_in_background ?? false
        let invocation = SubagentRunner.Invocation(
            subagentType: args.subagent_type,
            description: args.description,
            taskPrompt: args.prompt,
            modelOverride: args.model,
            runInBackground: runInBg
        )

        if runInBg {
            let handle = await SubagentBackgroundRegistry.shared.spawn(
                invocation: invocation,
                parentTools: parentTools,
                openRouterService: openRouter,
                toolExecutor: self,
                imagesDirectory: imagesDir,
                documentsDirectory: documentsDir
            )
            let payload: [String: Any] = [
                "background": true,
                "handle": handle.id,
                "subagent_type": handle.subagentType,
                "description": handle.description,
                "note": "Subagent is running in the background. You will receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Continue with other work or wait."
            ]
            let content = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"error\": \"Failed to encode background handle response\"}"
            return ToolResultMessage(toolCallId: call.id, content: content)
        }

        let runner = SubagentRunner()
        let result = await runner.run(
            invocation: invocation,
            sessionId: args.session_id,
            openRouterService: openRouter,
            toolExecutor: self,
            imagesDirectory: imagesDir,
            documentsDirectory: documentsDir,
            parentTools: parentTools
        )
        return ToolResultMessage(
            toolCallId: call.id,
            content: result.asJSON(),
            spendUSD: result.spendUSD > 0 ? result.spendUSD : nil
        )
    }

    func executeAgent(_ call: ToolCall) async -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SubagentInvocationArguments.self, from: data) else {
            return "{\"error\": \"Invalid Agent tool arguments\"}"
        }

        guard let openRouter = openRouterService else {
            return "{\"error\": \"Agent tool not configured: OpenRouterService missing. ConversationManager must call toolExecutor.configureOpenRouter(...).\"}"
        }

        let imagesDir = subagentImagesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAgent/images", isDirectory: true)
        let documentsDir = subagentDocumentsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalAgent/documents", isDirectory: true)

        // Same tool surface the parent sees this session — the subagent's type filter will narrow it.
        let parentTools = AvailableTools.all(includeWebSearch: true)

        let runInBg = args.run_in_background ?? false
        let invocation = SubagentRunner.Invocation(
            subagentType: args.subagent_type,
            description: args.description,
            taskPrompt: args.prompt,
            modelOverride: args.model,
            runInBackground: runInBg
        )

        if runInBg {
            let handle = await SubagentBackgroundRegistry.shared.spawn(
                invocation: invocation,
                parentTools: parentTools,
                openRouterService: openRouter,
                toolExecutor: self,
                imagesDirectory: imagesDir,
                documentsDirectory: documentsDir
            )
            let payload: [String: Any] = [
                "background": true,
                "handle": handle.id,
                "subagent_type": handle.subagentType,
                "description": handle.description,
                "note": "Subagent is running in the background. You will receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Continue with other work or wait."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"Failed to encode background handle response\"}"
        }

        let runner = SubagentRunner()
        let result = await runner.run(
            invocation: invocation,
            sessionId: args.session_id,
            openRouterService: openRouter,
            toolExecutor: self,
            imagesDirectory: imagesDir,
            documentsDirectory: documentsDir,
            parentTools: parentTools
        )
        return result.asJSON()
    }

    func executeSubagentManage(_ call: ToolCall) async -> String {
        struct Args: Decodable { let mode: String?; let handle: String?; let limit: Int?; let offset: Int? }
        let args: Args
        if let data = call.function.arguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Args.self, from: data) {
            args = decoded
        } else {
            args = Args(mode: nil, handle: nil, limit: nil, offset: nil)
        }
        guard let mode = args.mode else {
            return "{\"error\": \"subagent_manage requires 'mode' (list_running, list_sessions, or cancel)\"}"
        }

        switch mode {
        case "list_running":
            let handles = await SubagentBackgroundRegistry.shared.runningHandles()
            let now = Date()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let rows: [[String: Any]] = handles.map { h in
                [
                    "handle": h.id,
                    "subagent_type": h.subagentType,
                    "description": h.description,
                    "started_at": iso.string(from: h.startedAt),
                    "running_seconds": Int(now.timeIntervalSince(h.startedAt))
                ]
            }
            let payload: [String: Any] = ["count": rows.count, "running": rows]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage list_running result\"}"

        case "cancel":
            guard let handle = args.handle, !handle.isEmpty else {
                return "{\"cancelled\": false, \"reason\": \"mode='cancel' requires 'handle'\"}"
            }
            let ok = await SubagentBackgroundRegistry.shared.cancel(id: handle)
            let payload: [String: Any] = ok
                ? ["cancelled": true, "handle": handle, "note": "Cancellation requested. Takes effect at the subagent's next turn boundary."]
                : ["cancelled": false, "handle": handle, "reason": "not found"]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage cancel result\"}"

        case "list_sessions":
            let limit = args.limit ?? 20
            let offset = args.offset ?? 0
            let (sessions, total) = await SubagentSessionRegistry.shared.list(limit: limit, offset: offset)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let rows: [[String: Any]] = sessions.map { s in
                [
                    "session_id": s.id,
                    "subagent_type": s.subagentType,
                    "description": s.description,
                    "created": iso.string(from: s.created),
                    "last_used": iso.string(from: s.lastUsed),
                    "total_turns": s.totalTurns,
                    "message_count": s.messages.count,
                    "spend_usd": s.totalSpendUSD
                ]
            }
            let payload: [String: Any] = ["sessions": rows, "total": total, "has_more": offset + limit < total]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{\"error\": \"failed to encode subagent_manage list_sessions result\"}"

        default:
            return "{\"error\": \"Unknown mode '\(mode)'. Use 'list_running', 'list_sessions', or 'cancel'.\"}"
        }
    }
}
