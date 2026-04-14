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
        
        // Special cases for tools that return ToolResultMessage with file attachment for multimodal injection
        switch call.function.name {
        case "read_file":
            return await executeReadFile(call)
        case "download_email_attachment":
            return await executeDownloadEmailAttachment(call)
        case "gmailreader":
            return await executeGmailReader(call)
        case "gmail_attachment":
            return await executeGmailAttachment(call)
        case "shortcuts":
            return await executeShortcuts(call)
        case "generate_image":
            return await executeGenerateImage(call)
        case "web_fetch_image":
            return await executeWebFetchImage(call)
        case "run_shortcut":
            return await executeRunShortcut(call)
        case "web_search":
            return try await executeWebSearch(call)
        case "deep_research":
            return try await executeDeepResearch(call)
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
        case "bash_output":
            content = await executeBashOutput(call)
        case "bash_kill":
            content = await executeBashKill(call)
        case "todo_write":
            content = await executeTodoWrite(call)
        case "Agent":
            content = await executeAgent(call)
        case "list_running_subagents":
            content = await executeListRunningSubagents(call)
        case "cancel_subagent":
            content = await executeCancelSubagent(call)
        case "lsp_hover":
            content = await executeLSPHover(call)
        case "lsp_definition":
            content = await executeLSPDefinition(call)
        case "lsp_references":
            content = await executeLSPReferences(call)

        case "manage_reminders":
            content = try await executeManageReminders(call)
            
        case "manage_calendar":
            content = await executeManageCalendar(call)
            
        case "view_conversation_chunk":
            content = await executeViewConversationChunk(call)
            
        case "read_emails":
            content = await executeReadEmails(call)
            
        case "search_emails":
            content = await executeSearchEmails(call)
            
        case "send_email":
            content = await executeSendEmail(call)
            
        case "reply_email":
            content = await executeReplyEmail(call)
            
        case "forward_email":
            content = await executeForwardEmail(call)
            
        case "send_email_with_attachment":
            content = await executeSendEmailWithAttachment(call)
            
        // download_email_attachment handled above with file attachment
            
        case "get_email_thread":
            content = await executeGetEmailThread(call)
            
        case "manage_contacts":
            content = await executeManageContacts(call)
            
        // generate_image is handled in the special multimodal injection switch above
            
        case "web_fetch":
            content = await executeWebFetch(call)
            
        case "download_from_url":
            content = await executeDownloadFromUrl(call)
            
        case "send_document_to_chat":
            content = await executeSendDocumentToChat(call)
            
        // Shortcuts Tools
        case "list_shortcuts":
            content = await executeListShortcuts(call)
        // run_shortcut is handled above with file attachment for media output
            
        // Gmail API Tools
        case "gmailcomposer":
            content = await executeGmailComposer(call)

        case "gmail_query":
            content = await executeGmailQuery(call)
            
        case "gmail_send":
            content = await executeGmailSend(call)
            
        case "gmail_thread":
            content = await executeGmailThread(call)
            
        case "gmail_forward":
            content = await executeGmailForward(call)
            
        // gmail_attachment handled above with file attachment
            
        default:
            content = "{\"error\": \"Unknown tool: \(call.function.name)}\"}"
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
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse deep_research arguments\"}")
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
    // MARK: - Calendar Tool Implementations
    
    private func executeManageCalendar(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageCalendarArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_calendar arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "view":
            let includePast = args.includePast ?? false
            let events = await CalendarService.shared.getEvents(includePast: includePast)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let localISOFormatter = DateFormatter()
            localISOFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            localISOFormatter.timeZone = TimeZone.current

            let eventList = events.map { event -> CalendarEventResponse in
                CalendarEventResponse(
                    id: event.id.uuidString,
                    title: event.title,
                    datetime: formatter.string(from: event.datetime),
                    datetimeISO: localISOFormatter.string(from: event.datetime),
                    notes: event.notes,
                    isPast: event.datetime < Date()
                )
            }

            let result = ViewCalendarResult(
                success: true,
                eventCount: eventList.count,
                events: eventList,
                message: eventList.isEmpty ? "No events found" : "Found \(eventList.count) event(s)"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"eventCount":0,"events":[]}"#

        case "add":
            guard let title = args.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let datetime = args.datetime, !datetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'add', title and datetime are required"}"#
            }
            guard let eventDate = parseISO8601Date(datetime) else {
                return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-02-01T15:00:00') or ISO 8601 with offset."}"#
            }

            let event = await CalendarService.shared.addEvent(
                title: title,
                datetime: eventDate,
                notes: args.notes
            )

            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short

            let result = AddCalendarEventResult(
                success: true,
                eventId: event.id.uuidString,
                scheduledFor: formatter.string(from: eventDate),
                message: "Event '\(title)' successfully added to calendar"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Event added"}"#

        case "edit":
            guard let eventId = args.eventId, let eventUUID = UUID(uuidString: eventId) else {
                return #"{"error":"For action 'edit', event_id must be a valid UUID"}"#
            }

            var newDatetime: Date? = nil
            if let datetimeString = args.datetime {
                guard let parsed = parseISO8601Date(datetimeString) else {
                    return #"{"error":"Invalid datetime format. Use local datetime (e.g., '2026-02-01T15:00:00') or ISO 8601 with offset."}"#
                }
                newDatetime = parsed
            }

            let success = await CalendarService.shared.updateEvent(
                id: eventUUID,
                title: args.title,
                datetime: newDatetime,
                notes: args.notes
            )
            if success {
                return #"{"success":true,"message":"Event updated successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        case "delete":
            guard let eventId = args.eventId, let eventUUID = UUID(uuidString: eventId) else {
                return #"{"error":"For action 'delete', event_id must be a valid UUID"}"#
            }

            let success = await CalendarService.shared.deleteEvent(id: eventUUID)
            if success {
                return #"{"success":true,"message":"Event deleted successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        default:
            return #"{"error":"Invalid action. Supported actions: view, add, edit, delete"}"#
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

struct ReadEmailsArguments: Codable {
    let count: Int?
}

struct ReadEmailsResult: Codable {
    let success: Bool
    let emailCount: Int
    let emails: [EmailMessage]
    let message: String
}

struct SearchEmailsArguments: Codable {
    let query: String?
    let from: String?
    let since: String?
    let before: String?
    let folder: String?
    let limit: Int?
}

struct SendEmailArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let cc: [String]
    let bcc: [String]
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
    }
}

struct SendEmailResult: Codable {
    let success: Bool
    let message: String
}

struct ReplyEmailArguments: Codable {
    let messageId: String
    let to: String
    let subject: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case to, subject, body
    }
}

// MARK: - Email Tool Execution Extension

extension ToolExecutor {
    func executeReadEmails(_ call: ToolCall) async -> String {
        // Parse arguments (optional count) - default to 10
        var count = 10
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(ReadEmailsArguments.self, from: argsData),
           let argCount = args.count {
            count = min(max(argCount, 1), 20)
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.fetchEmails(count: count)
            
            // Update the cache with fresh data
            await EmailService.shared.updateCache(with: emails)
            
            let result = ReadEmailsResult(
                success: true,
                emailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found" : "Found \(emails.count) email(s)"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"emailCount\": \(emails.count)}"
        } catch {
            return "{\"error\": \"Failed to read emails: \(error.localizedDescription)\"}"
        }
    }
    
    func executeSearchEmails(_ call: ToolCall) async -> String {
        // Parse arguments
        var query: String? = nil
        var from: String? = nil
        var since: Date? = nil
        var before: Date? = nil
        var folder: String? = nil
        var limit = 10
        
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(SearchEmailsArguments.self, from: argsData) {
            query = args.query
            from = args.from
            folder = args.folder
            if let argLimit = args.limit {
                limit = min(max(argLimit, 1), 50)
            }
            
            // Parse date strings (YYYY-MM-DD format)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            
            if let sinceStr = args.since {
                since = dateFormatter.date(from: sinceStr)
            }
            if let beforeStr = args.before {
                before = dateFormatter.date(from: beforeStr)
            }
        }
        
        // Validate at least one search criteria (folder alone is valid for browsing)
        if query == nil && from == nil && since == nil && before == nil && folder == nil {
            return "{\"error\": \"At least one search criteria (query, from, since, before, or folder) is required.\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.searchEmails(
                query: query,
                from: from,
                since: since,
                before: before,
                folder: folder,
                limit: limit
            )
            
            let result = ReadEmailsResult(
                success: true,
                emailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found matching the search criteria" : "Found \(emails.count) email(s) matching your search"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"emailCount\": \(emails.count)}"
        } catch {
            return "{\"error\": \"Email search failed: \(error.localizedDescription)\"}"
        }
    }
    
    func executeSendEmail(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendEmailArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_email arguments\"}"
        }
        
        // Basic email validation
        guard isLikelyValidEmailAddress(args.to) else {
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return "{\"error\": \"Invalid cc or bcc email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let success = try await EmailService.shared.sendEmail(
                to: args.to,
                subject: args.subject,
                body: args.body,
                cc: args.cc,
                bcc: args.bcc
            )
            
            if success {
                let result = SendEmailResult(
                    success: true,
                    message: "Email sent successfully to \(args.to)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"success\": true, \"message\": \"Email sent\"}"
            } else {
                return "{\"error\": \"Failed to send email\"}"
            }
        } catch {
            return "{\"error\": \"Failed to send email: \(error.localizedDescription)\"}"
        }
    }
    
    func executeReplyEmail(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeReplyEmail called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReplyEmailArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse reply_email arguments")
            return "{\"error\": \"Failed to parse reply_email arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - to: \(args.to), subject: \(args.subject), messageId: \(args.messageId)")
        
        // Basic email validation
        guard args.to.contains("@") && args.to.contains(".") else {
            print("[ToolExecutor] Invalid email address: \(args.to)")
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        // Validate message_id format (should be <...>)
        guard args.messageId.hasPrefix("<") && args.messageId.hasSuffix(">") else {
            print("[ToolExecutor] Invalid message_id format: \(args.messageId)")
            return "{\"error\": \"Invalid message_id format. Must be in format <id@domain>\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            print("[ToolExecutor] Email not configured")
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        print("[ToolExecutor] Calling EmailService.replyToEmail...")
        
        do {
            let success = try await EmailService.shared.replyToEmail(
                inReplyTo: args.messageId,
                references: nil,  // For single-level replies, In-Reply-To is sufficient
                to: args.to,
                subject: args.subject,
                body: args.body
            )
            
            print("[ToolExecutor] EmailService.replyToEmail returned: \(success)")
            
            if success {
                let result = SendEmailResult(
                    success: true,
                    message: "Reply sent successfully to \(args.to) (threaded with original email)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    print("[ToolExecutor] Reply email success, returning result")
                    return json
                }
                return "{\"success\": true, \"message\": \"Reply sent\"}"
            } else {
                print("[ToolExecutor] EmailService.replyToEmail returned false")
                return "{\"error\": \"Failed to send reply\"}"
            }
        } catch {
            print("[ToolExecutor] EmailService.replyToEmail threw error: \(error)")
            return "{\"error\": \"Failed to send reply: \(error.localizedDescription)\"}"
        }
    }
    
    func executeForwardEmail(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeForwardEmail called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ForwardEmailArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse forward_email arguments")
            return "{\"error\": \"Failed to parse forward_email arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - to: \(args.to), emailUid: \(args.emailUid), originalSubject: \(args.originalSubject)")
        
        // Basic email validation
        guard args.to.contains("@") && args.to.contains(".") else {
            print("[ToolExecutor] Invalid email address: \(args.to)")
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            print("[ToolExecutor] Email not configured")
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        // Fetch the original email to get attachments info
        print("[ToolExecutor] Fetching original email to check for attachments...")
        var attachments: [EmailService.ForwardAttachment] = []
        
        do {
            let emails = try await EmailService.shared.fetchFullEmailsByUID([args.emailUid])
            if let email = emails.first, !email.attachments.isEmpty {
                print("[ToolExecutor] Found \(email.attachments.count) attachment(s) to forward - downloading in batch...")
                
                // Create a map from partId to correct filename/mimeType from the original attachment list
                var attachmentInfo: [String: (filename: String, mimeType: String)] = [:]
                for attachment in email.attachments {
                    attachmentInfo[attachment.partId] = (filename: attachment.filename, mimeType: attachment.mimeType)
                }
                
                // Get all part IDs for batch download
                let partIds = email.attachments.map { $0.partId }
                
                // Download ALL attachments in a SINGLE IMAP session (much faster!)
                let results = try await EmailService.shared.downloadAllAttachments(
                    emailUid: args.emailUid,
                    partIds: partIds
                )
                
                // Convert to ForwardAttachment format, using correct filenames
                for result in results {
                    let info = attachmentInfo[result.partId]
                    let correctFilename = info?.filename ?? result.filename
                    let correctMimeType = info?.mimeType ?? result.mimeType
                    
                    attachments.append(EmailService.ForwardAttachment(
                        data: result.data,
                        filename: correctFilename,
                        mimeType: correctMimeType
                    ))
                    print("[ToolExecutor] Downloaded attachment: \(correctFilename) (\(correctMimeType), \(result.data.count) bytes)")
                }
                
                print("[ToolExecutor] Successfully downloaded \(attachments.count) of \(email.attachments.count) attachment(s)")
            } else {
                print("[ToolExecutor] No attachments found in original email")
            }
        } catch {
            print("[ToolExecutor] Warning: Could not fetch original email for attachments: \(error)")
            // Continue anyway - we'll forward without attachments
        }
        
        print("[ToolExecutor] Calling EmailService.forwardEmailWithAttachments with \(attachments.count) attachment(s)...")
        
        do {
            let success = try await EmailService.shared.forwardEmailWithAttachments(
                to: args.to,
                originalFrom: args.originalFrom,
                originalDate: args.originalDate,
                originalSubject: args.originalSubject,
                originalBody: args.originalBody,
                comment: args.comment,
                attachments: attachments
            )
            
            print("[ToolExecutor] EmailService.forwardEmailWithAttachments returned: \(success)")
            
            if success {
                let attachmentInfo = attachments.isEmpty 
                    ? "" 
                    : " including \(attachments.count) attachment(s)"
                let result = SendEmailResult(
                    success: true,
                    message: "Email forwarded successfully to \(args.to)\(attachmentInfo)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    print("[ToolExecutor] Forward email success")
                    return json
                }
                return "{\"success\": true, \"message\": \"Email forwarded with attachments\"}"
            } else {
                print("[ToolExecutor] EmailService.forwardEmailWithAttachments returned false")
                return "{\"error\": \"Failed to forward email\"}"
            }
        } catch {
            print("[ToolExecutor] EmailService.forwardEmailWithAttachments threw error: \(error)")
            return "{\"error\": \"Failed to forward email: \(error.localizedDescription)\"}"
        }
    }
}

struct ForwardEmailArguments: Codable {
    let to: String
    let emailUid: String
    let originalFrom: String
    let originalDate: String
    let originalSubject: String
    let originalBody: String
    let comment: String?
    
    enum CodingKeys: String, CodingKey {
        case to
        case emailUid = "email_uid"
        case originalFrom = "original_from"
        case originalDate = "original_date"
        case originalSubject = "original_subject"
        case originalBody = "original_body"
        case comment
    }
}

// MARK: - Document Tool Types

struct ListDocumentsArguments: Codable {
    let limit: Int?
    let cursor: String?
    
    enum CodingKeys: String, CodingKey {
        case limit
        case cursor
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let intLimit = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limit = intLimit
        } else if let stringLimit = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let parsed = Int(stringLimit.trimmingCharacters(in: .whitespacesAndNewlines)) {
            limit = parsed
        } else {
            limit = nil
        }
        
        if let stringCursor = try? container.decodeIfPresent(String.self, forKey: .cursor) {
            cursor = stringCursor
        } else if let intCursor = try? container.decodeIfPresent(Int.self, forKey: .cursor) {
            cursor = String(intCursor)
        } else {
            cursor = nil
        }
    }
}

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

struct SendEmailWithAttachmentArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let cc: [String]
    let bcc: [String]
    let documentFilenames: [String]
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
        case documentFilenames = "document_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        
        // Handle documentFilenames as either an array or a JSON string
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            documentFilenames = array
        } else if let jsonString = try? container.decode(String.self, forKey: .documentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            documentFilenames = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .documentFilenames, in: container, debugDescription: "document_filenames must be a JSON array of strings")
        }
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
    
    func executeSendEmailWithAttachment(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendEmailWithAttachmentArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_email_with_attachment arguments\"}"
        }
        
        // Basic email validation
        guard isLikelyValidEmailAddress(args.to) else {
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return "{\"error\": \"Invalid cc or bcc email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        // Load all attachment files
        var attachments: [(url: URL, name: String)] = []
        for filename in args.documentFilenames {
            let documentURL = documentsDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: documentURL.path) else {
                return "{\"error\": \"Document not found: \(filename). Use list_documents to see available files.\"}"
            }
            attachments.append((url: documentURL, name: filename))
        }
        
        guard !attachments.isEmpty else {
            return "{\"error\": \"No documents specified. Use list_documents to see available files.\"}"
        }
        
        do {
            let success = try await EmailService.shared.sendEmailWithAttachments(
                to: args.to,
                subject: args.subject,
                body: args.body,
                cc: args.cc,
                bcc: args.bcc,
                attachments: attachments
            )
            
            if success {
                for filename in args.documentFilenames {
                    recordDocumentOpened(filename: filename)
                }
                let filenames = args.documentFilenames.joined(separator: ", ")
                let result = SendEmailResult(
                    success: true,
                    message: "Email with \(attachments.count) attachment(s) (\(filenames)) sent successfully to \(args.to)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"success\": true, \"message\": \"Email with attachments sent\"}"
            } else {
                return "{\"error\": \"Failed to send email with attachments\"}"
            }
        } catch {
            return "{\"error\": \"Failed to send email with attachments: \(error.localizedDescription)\"}"
        }
    }
    
    func executeDownloadEmailAttachment(_ call: ToolCall) async -> ToolResultMessage {
        print("[ToolExecutor] executeDownloadEmailAttachment called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(DownloadEmailAttachmentArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse download_email_attachment arguments")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse download_email_attachment arguments\"}")
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}")
        }
        
        // Handle download_all mode (batch download with multimodal injection)
        if args.downloadAll == true {
            print("[ToolExecutor] Batch downloading all attachments for email UID: \(args.emailUid)")
            return await downloadAllAttachments(emailUid: args.emailUid, toolCallId: call.id)
        }
        
        // Single attachment download
        guard let partId = args.partId else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Either part_id or download_all=true must be provided\"}")
        }
        
        print("[ToolExecutor] Parsed args - email_uid: \(args.emailUid), part_id: \(partId)")
        
        do {
            let result = try await EmailService.shared.downloadAttachment(
                emailUid: args.emailUid,
                partId: partId
            )
            
            print("[ToolExecutor] Downloaded attachment: \(result.filename) (\(result.mimeType), \(result.data.count) bytes)")
            
            // Save to documents folder
            let savedFilename = await saveAttachmentToDocuments(data: result.data, filename: result.filename, mimeType: result.mimeType)
            
            // Create file attachment for multimodal injection (just like read_document)
            let attachment = FileAttachment(data: result.data, mimeType: result.mimeType, filename: savedFilename)
            
            // Queue for description generation after agentic loop completes
            ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: result.mimeType)
            
            // Result text (no base64 needed - file will be injected as multimodal content)
            let visibilityMessage: String
            if isInlineMimeTypeSupportedForLLM(result.mimeType) {
                visibilityMessage = "Attachment '\(result.filename)' downloaded and visible. You can now analyze its contents directly."
            } else if result.mimeType == "application/zip" || result.filename.lowercased().hasSuffix(".zip") {
                visibilityMessage = "Attachment '\(result.filename)' downloaded. ZIP files are not viewable inline; extract with the bash tool (e.g. `unzip`) if needed."
            } else {
                visibilityMessage = "Attachment '\(result.filename)' downloaded but not viewable inline in this model."
            }
            let resultJson = """
            {"success": true, "filename": "\(result.filename)", "mimeType": "\(result.mimeType)", "sizeBytes": \(result.data.count), "savedFilename": "\(savedFilename)", "message": "\(visibilityMessage)"}
            """
            
            return ToolResultMessage(toolCallId: call.id, content: resultJson, fileAttachment: attachment)
        } catch {
            print("[ToolExecutor] Error downloading attachment: \(error)")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to download attachment: \(error.localizedDescription)\"}")
        }
    }
    
    /// Download all attachments from an email and return with multimodal injection
    private func downloadAllAttachments(emailUid: String, toolCallId: String) async -> ToolResultMessage {
        do {
            // First, fetch the email to get attachment list
            let emails = try await EmailService.shared.fetchFullEmailsByUID([emailUid])
            
            guard let email = emails.first else {
                return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"Email not found with UID \(emailUid)\"}")
            }
            
            guard !email.attachments.isEmpty else {
                return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"No attachments found in this email\"}")
            }
            
            // Create a map from partId to correct filename/mimeType from the original attachment list
            // This is more reliable than parsing from BODYSTRUCTURE which can be buggy
            var attachmentInfo: [String: (filename: String, mimeType: String)] = [:]
            for attachment in email.attachments {
                attachmentInfo[attachment.partId] = (filename: attachment.filename, mimeType: attachment.mimeType)
            }
            
            // Get all part IDs for batch download
            let partIds = email.attachments.map { $0.partId }
            
            // Download ALL attachments in a SINGLE IMAP session (much faster!)
            let results = try await EmailService.shared.downloadAllAttachments(
                emailUid: emailUid,
                partIds: partIds
            )
            
            var downloadedFiles: [BatchAttachmentResult] = []
            var fileAttachments: [FileAttachment] = []
            var errors: [String] = []
            
            // Process downloaded attachments
            for result in results {
                // Use the original filename from the attachment list, not from the download response
                let info = attachmentInfo[result.partId]
                let correctFilename = info?.filename ?? result.filename
                let correctMimeType = info?.mimeType ?? result.mimeType
                
                let savedFilename = await saveAttachmentToDocuments(
                    data: result.data,
                    filename: correctFilename,
                    mimeType: correctMimeType
                )
                
                downloadedFiles.append(BatchAttachmentResult(
                    filename: correctFilename,
                    mimeType: correctMimeType,
                    sizeBytes: result.data.count,
                    savedFilename: savedFilename
                ))
                
                // Create file attachment for multimodal injection
                fileAttachments.append(FileAttachment(
                    data: result.data,
                    mimeType: correctMimeType,
                    filename: savedFilename
                ))
                
                // Queue for description generation after agentic loop completes
                ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: correctMimeType)
                
                print("[ToolExecutor] Downloaded attachment: \(correctFilename) -> \(savedFilename)")
            }
            
            // Track any attachments that failed (weren't in results)
            let downloadedPartIds = Set(results.map { $0.partId })
            for attachment in email.attachments where !downloadedPartIds.contains(attachment.partId) {
                errors.append("\(attachment.filename): Failed to download")
                print("[ToolExecutor] Failed to download attachment \(attachment.filename) (partId: \(attachment.partId))")
            }
            
            let inlineVisibleCount = downloadedFiles.filter { isInlineMimeTypeSupportedForLLM($0.mimeType) }.count
            let responseMessage: String
            if downloadedFiles.isEmpty {
                responseMessage = "Failed to download attachments"
            } else if inlineVisibleCount == downloadedFiles.count {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. All files are now visible for analysis."
            } else if inlineVisibleCount == 0 {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. Files are saved locally but not viewable inline; use project tools for ZIP/binary workflows."
            } else {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. \(inlineVisibleCount) file(s) are visible inline; others are saved locally for project import."
            }
            
            let response = BatchDownloadResult(
                success: !downloadedFiles.isEmpty,
                totalAttachments: email.attachments.count,
                downloadedCount: downloadedFiles.count,
                files: downloadedFiles,
                errors: errors.isEmpty ? nil : errors,
                message: responseMessage
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(response), let json = String(data: data, encoding: .utf8) {
                return ToolResultMessage(toolCallId: toolCallId, content: json, fileAttachments: fileAttachments)
            }
            
            return ToolResultMessage(toolCallId: toolCallId, content: "{\"success\": true, \"downloadedCount\": \(downloadedFiles.count)}", fileAttachments: fileAttachments)
        } catch {
            print("[ToolExecutor] Error in batch download: \(error)")
            return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"Failed to fetch email attachments: \(error.localizedDescription)\"}")
        }
    }
    
    /// Save attachment to documents folder
    private func saveAttachmentToDocuments(data: Data, filename: String, mimeType: String) async -> String {
        let fileManager = FileManager.default
        
        // Sanitize filename
        var safeFilename = filename.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        
        // Ensure unique filename
        var finalFilename = safeFilename
        var counter = 1
        while fileManager.fileExists(atPath: documentsDirectory.appendingPathComponent(finalFilename).path) {
            let ext = (safeFilename as NSString).pathExtension
            let name = (safeFilename as NSString).deletingPathExtension
            finalFilename = "\(name)_\(counter).\(ext)"
            counter += 1
        }
        
        let fileURL = documentsDirectory.appendingPathComponent(finalFilename)
        
        do {
            try data.write(to: fileURL)
            print("[ToolExecutor] Saved attachment to: \(fileURL.path)")
            
            // Also save to images directory if it's an image
            if mimeType.hasPrefix("image/") {
                let imagesURL = imagesDirectory.appendingPathComponent(finalFilename)
                try? data.write(to: imagesURL)
            }
            
            return finalFilename
        } catch {
            print("[ToolExecutor] Failed to save attachment: \(error)")
            return filename
        }
    }
    
    // MARK: - Gmail API Tool Implementations

    private func executeGmailReader(_ call: ToolCall) async -> ToolResultMessage {
        guard await GmailService.shared.isAuthenticated else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings and complete OAuth authentication."}"#
            )
        }

        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailReaderArguments.self, from: argsData) else {
            return ToolResultMessage(
                toolCallId: call.id,
                content: #"{"error": "Failed to parse gmailreader arguments"}"#
            )
        }

        switch normalizedGmailAction(args.action) {
        case "search":
            guard let syntheticCall = syntheticToolCall(
                from: call,
                name: "gmail_query",
                arguments: compactJSONObject([
                    "query": args.query,
                    "limit": args.limit
                ])
            ) else {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to prepare gmailreader search arguments"}"#)
            }
            return ToolResultMessage(toolCallId: call.id, content: await executeGmailQuery(syntheticCall))

        case "read_message":
            guard let messageId = nonEmptyGmailField(args.messageId) else {
                return ToolResultMessage(
                    toolCallId: call.id,
                    content: #"{"error": "gmailreader action='read_message' requires message_id"}"#
                )
            }
            return ToolResultMessage(toolCallId: call.id, content: await executeGmailReadMessage(messageId: messageId))

        case "read_thread":
            guard let threadId = nonEmptyGmailField(args.threadId),
                  let syntheticCall = syntheticToolCall(
                    from: call,
                    name: "gmail_thread",
                    arguments: ["thread_id": threadId]
                  ) else {
                return ToolResultMessage(
                    toolCallId: call.id,
                    content: #"{"error": "gmailreader action='read_thread' requires thread_id"}"#
                )
            }
            return ToolResultMessage(toolCallId: call.id, content: await executeGmailThread(syntheticCall))

        case "download_attachment":
            guard let messageId = nonEmptyGmailField(args.messageId),
                  let attachmentId = nonEmptyGmailField(args.attachmentId),
                  let filename = nonEmptyGmailField(args.filename),
                  let syntheticCall = syntheticToolCall(
                    from: call,
                    name: "gmail_attachment",
                    arguments: [
                        "message_id": messageId,
                        "attachment_id": attachmentId,
                        "filename": filename
                    ]
                  ) else {
                return ToolResultMessage(
                    toolCallId: call.id,
                    content: #"{"error": "gmailreader action='download_attachment' requires message_id, attachment_id, and filename"}"#
                )
            }
            return await executeGmailAttachment(syntheticCall)

        default:
            return ToolResultMessage(
                toolCallId: call.id,
                content: #"{"error": "Unknown gmailreader action. Use 'search', 'read_message', 'read_thread', or 'download_attachment'."}"#
            )
        }
    }

    private func executeGmailComposer(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }

        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailComposerArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmailcomposer arguments"}"#
        }

        let action = normalizedGmailAction(args.action)
        guard let to = nonEmptyGmailField(args.to) else {
            return #"{"error": "gmailcomposer requires a non-empty 'to' address"}"#
        }

        switch action {
        case "new":
            guard let subject = nonEmptyGmailField(args.subject),
                  let body = nonEmptyGmailField(args.body),
                  let syntheticCall = syntheticToolCall(
                    from: call,
                    name: "gmail_send",
                    arguments: compactJSONObject([
                        "to": to,
                        "subject": subject,
                        "body": body,
                        "cc": args.cc.isEmpty ? nil : args.cc,
                        "bcc": args.bcc.isEmpty ? nil : args.bcc,
                        "attachment_filenames": args.attachmentFilenames
                    ])
                  ) else {
                return #"{"error": "gmailcomposer action='new' requires subject and body"}"#
            }
            return await executeGmailSend(syntheticCall)

        case "reply":
            guard let subject = nonEmptyGmailField(args.subject),
                  let body = nonEmptyGmailField(args.body),
                  let threadId = nonEmptyGmailField(args.threadId),
                  let syntheticCall = syntheticToolCall(
                    from: call,
                    name: "gmail_send",
                    arguments: compactJSONObject([
                        "to": to,
                        "subject": subject,
                        "body": body,
                        "thread_id": threadId,
                        "in_reply_to": nonEmptyGmailField(args.inReplyTo),
                        "cc": args.cc.isEmpty ? nil : args.cc,
                        "bcc": args.bcc.isEmpty ? nil : args.bcc,
                        "attachment_filenames": args.attachmentFilenames
                    ])
                  ) else {
                return #"{"error": "gmailcomposer action='reply' requires subject, body, and thread_id"}"#
            }
            return await executeGmailSend(syntheticCall)

        case "forward":
            guard let messageId = nonEmptyGmailField(args.messageId),
                  let syntheticCall = syntheticToolCall(
                    from: call,
                    name: "gmail_forward",
                    arguments: compactJSONObject([
                        "to": to,
                        "message_id": messageId,
                        "comment": nonEmptyGmailField(args.comment)
                    ])
                  ) else {
                return #"{"error": "gmailcomposer action='forward' requires message_id"}"#
            }
            return await executeGmailForward(syntheticCall)

        default:
            return #"{"error": "Unknown gmailcomposer action. Use 'new', 'reply', or 'forward'."}"#
        }
    }

    private func executeGmailReadMessage(messageId: String) async -> String {
        do {
            let message = try await GmailService.shared.getMessage(id: messageId)

            var response = "=== EMAIL MESSAGE ===\n"
            response += "Message ID: \(message.id)\n"
            response += "Thread ID: \(message.threadId)\n"
            response += "From: \(message.getHeader("From") ?? "Unknown")\n"
            response += "To: \(message.getHeader("To") ?? "")\n"

            if let cc = message.getHeader("Cc"), !cc.isEmpty {
                response += "Cc: \(cc)\n"
            }

            response += "Subject: \(message.getHeader("Subject") ?? "(No subject)")\n"
            response += "Date: \(message.getHeader("Date") ?? "")\n"

            let attachments = message.payload?.getAttachmentParts() ?? []
            if !attachments.isEmpty {
                response += "Attachments:\n"
                for attachment in attachments {
                    let filename = attachment.filename ?? "unknown"
                    let attachmentId = attachment.body?.attachmentId ?? "N/A"
                    let size = attachment.body?.size ?? 0
                    response += "  - \(filename) (attachment_id: \(attachmentId), size: \(size) bytes)\n"
                }
            }

            let body = message.getPlainTextBody()
            response += "Body:\n\(body.prefix(4000))"
            return response
        } catch {
            return "{\"error\": \"Failed to read message: \(error.localizedDescription)\"}"
        }
    }

    private func normalizedGmailAction(_ action: String) -> String {
        action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmptyGmailField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func compactJSONObject(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.compactMapValues { value in
            switch value {
            case let string as String:
                return string
            case let int as Int:
                return int
            case let bool as Bool:
                return bool
            case let strings as [String]:
                return strings
            default:
                return nil
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

    private func executeGmailQuery(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings and complete OAuth authentication."}"#
        }
        
        var query: String? = nil
        var limit: Int = 10
        
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(GmailQueryArguments.self, from: argsData) {
            query = args.query
            limit = args.limit ?? 10
        }
        
        do {
            let emails = try await GmailService.shared.queryEmails(query: query, limit: limit)
            
            // Format response for LLM
            var response = "Found \(emails.count) email(s)"
            if let q = query, !q.isEmpty {
                response += " matching '\(q)'"
            }
            response += ":\n\n"
            
            for email in emails {
                let from = email.getHeader("From") ?? "Unknown"
                let subject = email.getHeader("Subject") ?? "(No subject)"
                let date = email.getHeader("Date") ?? ""
                let snippet = email.snippet ?? ""
                
                response += "---\n"
                response += "Message ID: \(email.id)\n"
                response += "Thread ID: \(email.threadId)\n"
                response += "From: \(from)\n"
                response += "Subject: \(subject)\n"
                response += "Date: \(date)\n"
                response += "Preview: \(snippet.prefix(200))...\n"
                
                // List attachments with their attachment IDs (used by gmailreader download_attachment)
                let attachments = email.payload?.getAttachmentParts() ?? []
                if !attachments.isEmpty {
                    response += "Attachments:\n"
                    for attachment in attachments {
                        let filename = attachment.filename ?? "unknown"
                        let attachmentId = attachment.body?.attachmentId ?? "N/A"
                        let size = attachment.body?.size ?? 0
                        response += "  - \(filename) (attachment_id: \(attachmentId), size: \(size) bytes)\n"
                    }
                }
            }
            
            return response
        } catch {
            return "{\"error\": \"Gmail query failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailSend(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailSendArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_send arguments"}"#
        }
        
        guard isLikelyValidEmailAddress(args.to) else {
            return #"{"error": "Invalid email address format"}"#
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return #"{"error": "Invalid cc or bcc email address format"}"#
        }
        
        do {
            // Load multiple attachments if specified
            var attachments: [(data: Data, name: String, mimeType: String)] = []
            
            if let filenames = args.attachmentFilenames {
                for filename in filenames {
                    let fileURL = documentsDirectory.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        let data = try Data(contentsOf: fileURL)
                        let mimeType = getMimeType(for: filename)
                        attachments.append((data: data, name: filename, mimeType: mimeType))
                    } else {
                        return "{\"error\": \"Attachment file not found: \(filename). Use list_documents to see available files.\"}"
                    }
                }
            }
            
            let success = try await GmailService.shared.sendEmail(
                to: args.to,
                subject: args.subject,
                body: args.body,
                threadId: args.threadId,
                inReplyTo: args.inReplyTo,
                cc: args.cc,
                bcc: args.bcc,
                attachments: attachments
            )
            
            if success {
                var message = "Email sent successfully to \(args.to)"
                if args.threadId != nil {
                    message += " (as reply in thread)"
                }
                if !attachments.isEmpty {
                    message += " with \(attachments.count) attachment(s)"
                }
                return "{\"success\": true, \"message\": \"\(message)\"}"
            } else {
                return #"{"error": "Failed to send email"}"#
            }
        } catch {
            return "{\"error\": \"Gmail send failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailThread(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailThreadArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_thread arguments"}"#
        }
        
        do {
            let thread = try await GmailService.shared.getThread(id: args.threadId)
            
            var response = "=== EMAIL THREAD ===\n"
            response += "Thread ID: \(thread.id)\n"
            response += "Messages: \(thread.messages?.count ?? 0)\n\n"
            
            for (index, message) in (thread.messages ?? []).enumerated() {
                let from = message.getHeader("From") ?? "Unknown"
                let to = message.getHeader("To") ?? ""
                let subject = message.getHeader("Subject") ?? "(No subject)"
                let date = message.getHeader("Date") ?? ""
                let body = message.getPlainTextBody()
                
                response += "--- Message \(index + 1) ---\n"
                response += "Message ID: \(message.id)\n"
                response += "From: \(from)\n"
                response += "To: \(to)\n"
                response += "Subject: \(subject)\n"
                response += "Date: \(date)\n"
                
                // List attachments with their attachment IDs (used by gmailreader download_attachment)
                let attachments = message.payload?.getAttachmentParts() ?? []
                if !attachments.isEmpty {
                    response += "Attachments:\n"
                    for attachment in attachments {
                        let filename = attachment.filename ?? "unknown"
                        let attachmentId = attachment.body?.attachmentId ?? "N/A"
                        let size = attachment.body?.size ?? 0
                        response += "  - \(filename) (attachment_id: \(attachmentId), size: \(size) bytes)\n"
                    }
                }
                
                response += "Body:\n\(body.prefix(2000))\n\n"
            }
            
            return response
        } catch {
            return "{\"error\": \"Failed to get thread: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailForward(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailForwardArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_forward arguments"}"#
        }

        guard isLikelyValidEmailAddress(args.to) else {
            return #"{"error": "Invalid email address format"}"#
        }
        
        do {
            let success = try await GmailService.shared.forwardEmail(
                to: args.to,
                messageId: args.messageId,
                comment: args.comment
            )
            
            if success {
                return "{\"success\": true, \"message\": \"Email forwarded to \(args.to)\"}"
            } else {
                return #"{"error": "Failed to forward email"}"#
            }
        } catch {
            return "{\"error\": \"Gmail forward failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailAttachment(_ call: ToolCall) async -> ToolResultMessage {
        print("[ToolExecutor] executeGmailAttachment called")
        guard await GmailService.shared.isAuthenticated else {
            print("[ToolExecutor] Gmail not authenticated")
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#)
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailAttachmentArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse gmail_attachment arguments")
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to parse gmail_attachment arguments. Make sure to include message_id, attachment_id, and filename for gmailreader action='download_attachment'."}"#)
        }
        
        print("[ToolExecutor] Downloading attachment: messageId=\(args.messageId), attachmentId=\(args.attachmentId), filename=\(args.filename)")
        do {
            let result = try await GmailService.shared.downloadAttachment(
                messageId: args.messageId,
                attachmentId: args.attachmentId
            )
            
            // Use the filename from the LLM arguments (more reliable than the lookup in GmailService)
            let filename = args.filename
            let mimeType = getMimeType(for: filename)
            
            // Save to documents folder
            let savedFilename = await saveAttachmentToDocuments(
                data: result.data,
                filename: filename,
                mimeType: mimeType
            )
            
            // Create file attachment for multimodal injection (just like read_document)
            let attachment = FileAttachment(data: result.data, mimeType: mimeType, filename: savedFilename)
            print("[ToolExecutor] Created FileAttachment: \(filename) (\(mimeType), \(result.data.count) bytes)")
            
            // Queue for description generation after agentic loop completes
            ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: mimeType)
            
            // Result text (no base64 needed - file will be injected as multimodal content)
            let visibilityMessage: String
            if isInlineMimeTypeSupportedForLLM(mimeType) {
                visibilityMessage = "Attachment '\(filename)' downloaded and visible. You can now analyze its contents directly."
            } else if mimeType == "application/zip" || filename.lowercased().hasSuffix(".zip") {
                visibilityMessage = "Attachment '\(filename)' downloaded. ZIP files are not viewable inline; extract with the bash tool (e.g. `unzip`) if needed."
            } else {
                visibilityMessage = "Attachment '\(filename)' downloaded but not viewable inline in this model."
            }
            let resultJson = """
            {"success": true, "filename": "\(filename)", "mimeType": "\(mimeType)", "sizeBytes": \(result.data.count), "savedFilename": "\(savedFilename)", "message": "\(visibilityMessage)"}
            """
            
            let resultMessage = ToolResultMessage(toolCallId: call.id, content: resultJson, fileAttachment: attachment)
            print("[ToolExecutor] Created ToolResultMessage with \(resultMessage.fileAttachments.count) attachment(s)")
            return resultMessage
        } catch {
            print("[ToolExecutor] Gmail attachment download ERROR: \(error)")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Gmail attachment download failed: \(error.localizedDescription)\"}")
        }
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

struct DownloadEmailAttachmentArguments: Codable {
    let emailUid: String
    let partId: String?  // Optional when download_all is true
    let downloadAll: Bool?  // If true, download all attachments from the email
    
    enum CodingKeys: String, CodingKey {
        case emailUid = "email_uid"
        case partId = "part_id"
        case downloadAll = "download_all"
    }
}

struct DownloadEmailAttachmentResult: Codable {
    let success: Bool
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let contentType: String  // "image", "pdf", "text", "binary"
    let base64Data: String   // Raw data for Gemini to process natively
    let savedFilename: String  // Filename saved to documents folder
    let message: String
}

// MARK: - Batch Download Types

struct BatchAttachmentResult: Codable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let savedFilename: String
}

struct BatchDownloadResult: Codable {
    let success: Bool
    let totalAttachments: Int
    let downloadedCount: Int
    let files: [BatchAttachmentResult]
    let errors: [String]?
    let message: String
}

// MARK: - Get Email Thread Types

struct GetEmailThreadArguments: Codable {
    let messageId: String
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

struct GetEmailThreadResult: Codable {
    let success: Bool
    let threadEmailCount: Int
    let emails: [EmailMessage]
    let message: String
}

// MARK: - Get Email Thread Execution

extension ToolExecutor {
    func executeGetEmailThread(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeGetEmailThread called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GetEmailThreadArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse get_email_thread arguments")
            return "{\"error\": \"Failed to parse get_email_thread arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - message_id: \(args.messageId)")
        
        // Validate message_id format (should be <...>)
        guard args.messageId.hasPrefix("<") && args.messageId.hasSuffix(">") else {
            print("[ToolExecutor] Invalid message_id format: \(args.messageId)")
            return "{\"error\": \"Invalid message_id format. Must be in format <id@domain>\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.fetchEmailThread(messageId: args.messageId)
            
            print("[ToolExecutor] fetchEmailThread returned \(emails.count) emails")
            
            let result = GetEmailThreadResult(
                success: true,
                threadEmailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found in thread" : "Found \(emails.count) email(s) in thread (sorted oldest first)"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"threadEmailCount\": \(emails.count)}"
        } catch {
            print("[ToolExecutor] Error fetching email thread: \(error)")
            return "{\"error\": \"Failed to fetch email thread: \(error.localizedDescription)\"}"
        }
    }
    
    // MARK: - Contact Tool Execution
    
    private func parseListContactsCursor(_ cursor: String) -> Int? {
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
    
    func executeManageContacts(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageContactsArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_contacts arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "find":
            guard let query = args.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'find', query is required"}"#
            }

            let contacts = await ContactsService.shared.searchContacts(query: query)
            let contactResponses = contacts.prefix(20).map { contact in
                ContactResponse(
                    id: contact.id.uuidString,
                    firstName: contact.firstName,
                    lastName: contact.lastName,
                    fullName: contact.fullName,
                    email: contact.email,
                    phone: contact.phone,
                    organization: contact.organization
                )
            }

            let result = FindContactResult(
                success: true,
                contactCount: contactResponses.count,
                contacts: Array(contactResponses),
                message: contactResponses.isEmpty ? "No contacts found matching '\(query)'" : "Found \(contactResponses.count) contact(s) matching '\(query)'"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"contactCount\": \(contactResponses.count)}"

        case "add":
            guard let firstName = args.firstName,
                  !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'add', first_name is required"}"#
            }

            let contact = await ContactsService.shared.addContact(
                firstName: firstName,
                lastName: args.lastName,
                email: args.email,
                phone: args.phone,
                organization: args.organization
            )

            let result = AddContactResult(
                success: true,
                contactId: contact.id.uuidString,
                fullName: contact.fullName,
                message: "Contact '\(contact.fullName)' added successfully"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Contact added"}"#

        case "list":
            let defaultLimit = 40
            let maxLimit = 40
            var limit = defaultLimit
            var pageOffset = 0
            var cursorUsed: String?
            
            if let requestedLimit = args.limit {
                limit = min(max(requestedLimit, 1), maxLimit)
            }
            
            if let rawCursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCursor.isEmpty {
                guard let parsedOffset = parseListContactsCursor(rawCursor) else {
                    return #"{"error":"Invalid cursor '\#(rawCursor)'. Use next_cursor from the previous manage_contacts list response."}"#
                }
                pageOffset = parsedOffset
                cursorUsed = rawCursor
            }

            let contacts = await ContactsService.shared.getAllContacts()
            let totalContacts = contacts.count
            let start = min(max(pageOffset, 0), totalContacts)
            let end = min(start + limit, totalContacts)
            let pageContacts = start < end ? Array(contacts[start..<end]) : []
            let nextCursor = end < totalContacts ? String(end) : nil
            
            let contactResponses = pageContacts.map { contact in
                ContactResponse(
                    id: contact.id.uuidString,
                    firstName: contact.firstName,
                    lastName: contact.lastName,
                    fullName: contact.fullName,
                    email: contact.email,
                    phone: contact.phone,
                    organization: contact.organization
                )
            }

            let message: String
            if totalContacts == 0 {
                message = "No contacts found. Import contacts via Settings or use manage_contacts with action='add' to create one."
            } else if pageContacts.isEmpty {
                message = "No contacts found for cursor \(pageOffset). Use a smaller cursor to see available pages."
            } else if let nextCursor {
                message = "Showing \(contactResponses.count) of \(totalContacts) contact(s). Use cursor '\(nextCursor)' for the next page."
            } else {
                message = "Showing \(contactResponses.count) of \(totalContacts) contact(s). End of list."
            }

            let result = ListContactsResult(
                success: true,
                totalCount: totalContacts,
                returnedCount: contactResponses.count,
                limit: limit,
                nextCursor: nextCursor,
                cursorUsed: cursorUsed,
                contacts: Array(contactResponses),
                message: message
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"totalCount\": \(totalContacts)}"

        case "delete":
            var ids = args.contactIds?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if ids.isEmpty,
               let singleId = args.contactId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !singleId.isEmpty {
                ids = [singleId]
            }
            ids = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
            guard !ids.isEmpty else {
                return #"{"error":"For action 'delete', provide contact_id or contact_ids (array/JSON array string/CSV)"}"#
            }
            
            var deletedCount = 0
            var failedIds: [String] = []
            
            for idString in ids {
                if let uuid = UUID(uuidString: idString) {
                    let success = await ContactsService.shared.deleteContact(id: uuid)
                    if success {
                        deletedCount += 1
                    } else {
                        failedIds.append(idString)
                    }
                } else {
                    failedIds.append(idString)
                }
            }
            
            let result = DeleteContactsResult(
                success: deletedCount > 0,
                deletedCount: deletedCount,
                failedIds: failedIds.isEmpty ? nil : failedIds,
                message: deletedCount > 0 ? "Successfully deleted \(deletedCount) contact(s)." : "Failed to delete contacts."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Contacts deleted"}"#

        default:
            return #"{"error":"Invalid action. Supported actions: find, add, list, delete"}"#
        }
    }
}

// MARK: - Contact Tool Argument Types

struct ManageContactsArguments: Codable {
    let action: String
    let query: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    let phone: String?
    let organization: String?
    let limit: Int?
    let cursor: String?
    let contactId: String?
    let contactIds: [String]?
    
    enum CodingKeys: String, CodingKey {
        case action
        case query
        case firstName = "first_name"
        case lastName = "last_name"
        case email, phone, organization
        case limit
        case cursor
        case contactId = "contact_id"
        case contactIds = "contact_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)

        if let intLimit = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limit = intLimit
        } else if let stringLimit = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let parsed = Int(stringLimit.trimmingCharacters(in: .whitespacesAndNewlines)) {
            limit = parsed
        } else {
            limit = nil
        }

        if let stringCursor = try? container.decodeIfPresent(String.self, forKey: .cursor) {
            cursor = stringCursor
        } else if let intCursor = try? container.decodeIfPresent(Int.self, forKey: .cursor) {
            cursor = String(intCursor)
        } else {
            cursor = nil
        }

        contactId = try container.decodeIfPresent(String.self, forKey: .contactId)

        if let array = try? container.decodeIfPresent([String].self, forKey: .contactIds) {
            contactIds = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .contactIds))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                contactIds = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                contactIds = csv.isEmpty ? nil : csv
            }
        } else {
            contactIds = nil
        }
    }
}

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
    
    /// Store for downloaded attachments that need description generation
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
    
    /// Get and clear files that need description generation
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
    
    /// Queue a file for description generation after the agentic loop completes
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
            let attachment = FileAttachment(data: imageData, mimeType: mimeType, filename: fileName)
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
                
                fileAttachment = FileAttachment(data: finalOutputData, mimeType: mimeType, filename: savedFilename)
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
            // LLM can use web_fetch_image tool to download specific images it wants to see
            return result.asJSON()
        } catch {
            return "{\"error\": \"Failed to fetch URL: \(error.localizedDescription)\"}"
        }
    }

    /// Download a specific image from a URL for multimodal injection
    /// LLM uses this after viewing page metadata to selectively download interesting images
    func executeWebFetchImage(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebFetchImageArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse web_fetch_image arguments\"}")
        }

        // Validate URL format
        guard args.imageUrl.hasPrefix("http://") || args.imageUrl.hasPrefix("https://") else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}")
        }
        
        // Download the image, surfacing a precise error so the agent doesn't silently hang.
        let downloadedImage: DownloadedImage
        do {
            downloadedImage = try await webOrchestrator.downloadImageOrThrow(url: args.imageUrl, caption: args.caption ?? "")
        } catch WebOrchestrator.ImageDownloadFailure.unsupportedFormat(let mime) {
            let msg = "Vision models cannot read \(mime) images (e.g. SVG badges, PDFs). Supported formats: jpeg, png, gif, webp. Use web_fetch with a specific prompt to describe the content, or download_from_url to save the file locally."
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \(jsonStringLit(msg))}")
        } catch WebOrchestrator.ImageDownloadFailure.notAnImage(let mime) {
            let msg = "URL did not return an image (Content-Type: \(mime)). Use web_fetch or download_from_url for non-image content."
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \(jsonStringLit(msg))}")
        } catch WebOrchestrator.ImageDownloadFailure.httpError(let code) {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Image fetch failed with HTTP \(code). The URL may be expired (common for GitHub camo proxies) or require auth.\"}")
        } catch WebOrchestrator.ImageDownloadFailure.tooLarge(let bytes) {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Image too large: \(bytes) bytes. Max supported size is 10 MB.\"}")
        } catch WebOrchestrator.ImageDownloadFailure.invalidURL {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid URL.\"}")
        } catch WebOrchestrator.ImageDownloadFailure.network(let reason) {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \(jsonStringLit("Network error downloading image: \(reason)"))}")
        } catch {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \(jsonStringLit("Failed to download image: \(error.localizedDescription)"))}")
        }

        // Create file attachment for multimodal injection. Filename extension reflects the real mime.
        let ext: String
        switch downloadedImage.mimeType {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        let filename = "page_image_\(UUID().uuidString.prefix(8)).\(ext)"
        let attachment = FileAttachment(data: downloadedImage.data, mimeType: downloadedImage.mimeType, filename: filename)

        print("[ToolExecutor] Downloaded page image for multimodal injection: \(downloadedImage.data.count) bytes from \(args.imageUrl)")

        let result = """
        {"success": true, "mimeType": "\(downloadedImage.mimeType)", "sizeBytes": \(downloadedImage.data.count), "message": "Image downloaded successfully. You can now see and analyze it."}
        """

        return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: attachment)
    }
    
    func executeDownloadFromUrl(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(DownloadFromUrlArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse download_from_url arguments\"}"
        }
        
        // Validate URL format
        guard let url = URL(string: args.url),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}"
        }
        
        do {
            // Download the file
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            
            // Add common headers to avoid blocks
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return "{\"error\": \"Download failed with HTTP status \(statusCode)\"}"
            }
            
            // Determine filename
            let filename: String
            if let preferredFilename = args.filename, !preferredFilename.isEmpty {
                filename = preferredFilename
            } else {
                // Try to derive from Content-Disposition header or URL
                if let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
                   let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
                    filename = String(contentDisposition[filenameMatch]).replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")
                } else if let lastComponent = url.pathComponents.last, lastComponent.contains(".") {
                    filename = lastComponent
                } else {
                    // Generate filename based on content type
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                    let ext = extensionForMimeType(contentType)
                    filename = "download_\(UUID().uuidString.prefix(8)).\(ext)"
                }
            }
            
            // Save to the same documents directory used by list_documents and Telegram uploads
            let fileURL = documentsDirectory.appendingPathComponent(filename)
            
            try data.write(to: fileURL)
            
            // Also save to images directory if it's an image (for Gemini vision access)
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.hasPrefix("image/") {
                let imageFileURL = imagesDirectory.appendingPathComponent(filename)
                try? data.write(to: imageFileURL)
            }
            
            print("[ToolExecutor] Downloaded file: \(filename) (\(data.count) bytes)")
            
            let result = DownloadFromUrlResult(
                success: true,
                filename: filename,
                fileSize: data.count,
                contentType: contentType,
                message: "File downloaded successfully. You can reference it as '\(filename)' or attach it to emails."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let resultData = try? encoder.encode(result), let json = String(data: resultData, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"filename\": \"\(filename)\", \"message\": \"File downloaded\"}"
        } catch {
            return "{\"error\": \"Download failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func extensionForMimeType(_ mimeType: String) -> String {
        let type = mimeType.lowercased().components(separatedBy: ";").first ?? mimeType.lowercased()
        switch type {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "application/zip": return "zip"
        default: return "bin"
        }
    }
}

// MARK: - URL Tool Argument Types

struct WebFetchArguments: Codable {
    let url: String
    let prompt: String
}

struct WebFetchImageArguments: Codable {
    let imageUrl: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case imageUrl = "image_url"
        case caption
    }
}

struct DownloadFromUrlArguments: Codable {
    let url: String
    let filename: String?
}

struct DownloadFromUrlResult: Codable {
    let success: Bool
    let filename: String
    let fileSize: Int
    let contentType: String
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, filename, message, contentType
        case fileSize = "file_size"
    }
}

// MARK: - Send Document to Chat Tool

extension ToolExecutor {
    func executeSendDocumentToChat(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_document_to_chat arguments\"}"
        }
        
        // Find the document file
        let documentURL = documentsDirectory.appendingPathComponent(args.documentFilename)
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return "{\"error\": \"Document not found: \(args.documentFilename). Use list_documents to see available files.\"}"
        }
        
        do {
            let documentData = try Data(contentsOf: documentURL)
            recordDocumentOpened(filename: args.documentFilename)
            
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
                filename: args.documentFilename,
                mimeType: mimeType,
                caption: args.caption
            ))
            
            print("[ToolExecutor] Queued document for sending: \(args.documentFilename) (\(documentData.count) bytes)")
            
            let result = SendDocumentToChatResult(
                success: true,
                documentFilename: args.documentFilename,
                sizeBytes: documentData.count,
                message: "Document '\(args.documentFilename)' will be sent to the chat."
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
    let documentFilename: String
    let caption: String?
    
    enum CodingKeys: String, CodingKey {
        case documentFilename = "document_filename"
        case caption
    }
}

struct SendDocumentToChatResult: Codable {
    let success: Bool
    let documentFilename: String
    let sizeBytes: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, message
        case documentFilename = "document_filename"
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

struct SubagentInvocationArguments: Codable {
    let subagent_type: String
    let description: String
    let prompt: String
    let run_in_background: String?
    let model: String?
}

extension ToolExecutor {
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

        let runInBg = Self.parseBoolFlag(args.run_in_background)
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
            openRouterService: openRouter,
            toolExecutor: self,
            imagesDirectory: imagesDir,
            documentsDirectory: documentsDir,
            parentTools: parentTools
        )
        return result.asJSON()
    }

    private static func parseBoolFlag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        default: return false
        }
    }

    func executeListRunningSubagents(_ call: ToolCall) async -> String {
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
        let payload: [String: Any] = [
            "count": rows.count,
            "running": rows
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode list_running_subagents result\"}"
    }

    func executeCancelSubagent(_ call: ToolCall) async -> String {
        struct Args: Decodable { let handle: String? }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let handle = args.handle, !handle.isEmpty else {
            return "{\"cancelled\": false, \"reason\": \"missing 'handle' argument\"}"
        }
        let ok = await SubagentBackgroundRegistry.shared.cancel(id: handle)
        let payload: [String: Any]
        if ok {
            payload = [
                "cancelled": true,
                "handle": handle,
                "note": "Cancellation requested. Takes effect at the subagent's next turn boundary — you will still receive a [SUBAGENT COMPLETE] message."
            ]
        } else {
            payload = [
                "cancelled": false,
                "handle": handle,
                "reason": "not found"
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode cancel_subagent result\"}"
    }
}
