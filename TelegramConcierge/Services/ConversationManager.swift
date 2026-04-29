import Foundation
import AppKit
import PDFKit
import SwiftUI

@MainActor
class ConversationManager: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isPolling: Bool = false
    @Published var statusMessage: String = "Not started"
    @Published var error: String?
    @Published var isPrivacyModeEnabled: Bool = false
    
    private let telegramService = TelegramBotService()
    private let openRouterService = OpenRouterService()
    private let toolExecutor = ToolExecutor()
    private let archiveService = ConversationArchiveService()
    
    private var pollingTask: Task<Void, Never>?
    private var activeProcessingTask: Task<Void, Never>?
    private var activeRunId: UUID?

    /// Per-turn tool-use log. Populated as the tool loop runs; cleared at turn
    /// start. Surfaces via /status so the user can ask "what's going on?"
    /// instead of being bombarded by a progress ping per tool call.
    private var currentTurnToolLog: [(name: String, startedAt: Date)] = []
    /// Whether the current log belongs to an actively-running turn or the
    /// most recently completed one. /status uses this to label its output.
    private var currentTurnLogIsActive: Bool = false
    private var pairedChatId: Int?
    
    // Pending media buffer - media is buffered until text triggers processing
    private var pendingImages: [(fileName: String, fileSize: Int)] = []
    private var pendingDocuments: [(fileName: String, fileSize: Int)] = []
    private var pendingReferencedImages: [(fileName: String, fileSize: Int)] = []
    private var pendingReferencedDocuments: [(fileName: String, fileSize: Int)] = []
    private var pendingForwardContext: String?
    private var pendingReplyContext: String?
    private let toolRunLogPrefix = "[TOOL RUN LOG - compact]"
    private let maxRetainedToolRunLogs = 5
    private let maxAssistantMessageChars = 4000
    private let defaultToolSpendLimitPerTurnUSD = 0.20
    private let minimumToolSpendLimitPerTurnUSD = 0.001
    private var maxToolRoundsSafetyLimit: Int {
        AgentTurnOverrides.override(forAgent: "main") ?? AgentTurnOverrides.mainAgentDefault
    }
    private let shouldResumePollingDefaultsKey = "should_resume_polling_on_launch"
    private let privacyModeDefaultsKey = "telegram_privacy_mode_enabled"
    private let systemPromptTimestampKey = "system_prompt_cache_epoch"
    private let defaultMaxContextTokens = 100_000
    private let defaultTargetContextTokens = 50_000

    // Frozen calendar/email context — populated on first turn of a session, refreshed
    // only on Watermark prune events or local-day rollover. Between refreshes, the
    // system-prompt block stays byte-identical so the provider prompt cache holds.
    // New emails arrive as ambient channel messages via the poller; the snapshot in
    // the system prompt is a post-context-loss refresh point, not live awareness.
    private var frozenCalendarContext: String?
    private var frozenEmailContext: String?
    private var frozenContextDay: Date?

    /// Actual prompt_tokens from the most recent API response. Used as the
    /// real HIGH watermark trigger for pruning instead of rough estimates.
    /// Also exposed (read-only) to the UI for the context gauge.
    @Published private(set) var lastPromptTokens: Int?
    /// Completion tokens from the most recent turn's final API response.
    /// Used to compute per-message measured tokens via delta arithmetic.
    private var lastCompletionTokens: Int?

    private struct ToolAwareResponse {
        let finalText: String
        let compactToolLog: String?
        let toolInteractions: [ToolInteraction]
        let accessedProjects: [String]?
        /// Sum of measured token costs across all tool interactions in this turn.
        let measuredToolTokens: Int?
        /// Measured token cost of the user message that triggered this turn,
        /// derived from prompt_tokens delta between turns.
        let measuredUserTokens: Int?
        /// Stored-history token cost for the assistant message: final visible
        /// text plus replayable tool interaction cost.
        let measuredAssistantTokens: Int?
        /// Completion tokens for only the assistant's final visible text.
        /// Unlike measuredAssistantTokens, this excludes replayed tool messages
        /// and is used for next-turn prompt delta attribution.
        let measuredAssistantCompletionTokens: Int?
        /// Absolute paths of pre-existing files modified during the turn (FilesLedger diff).
        let editedFilePaths: [String]
        /// Absolute paths of files newly created during the turn (FilesLedger diff).
        let generatedFilePaths: [String]
        /// Subagent session events that occurred during this turn.
        var subagentSessionEvents: [SubagentSessionEvent]
    }

    private struct SpendLimitStatus {
        let todaySpentUSD: Double
        let monthSpentUSD: Double
        let dailyBaseLimitUSD: Double?
        let monthlyBaseLimitUSD: Double?
        let dailyExtraUSD: Double
        let monthlyExtraUSD: Double

        var effectiveDailyLimitUSD: Double? {
            dailyBaseLimitUSD.map { $0 + dailyExtraUSD }
        }

        var effectiveMonthlyLimitUSD: Double? {
            monthlyBaseLimitUSD.map { $0 + monthlyExtraUSD }
        }

        var dailyExceeded: Bool {
            effectiveDailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        }

        var monthlyExceeded: Bool {
            effectiveMonthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        }
    }

    private let appFolder: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("LocalAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    
    private var conversationFileURL: URL {
        appFolder.appendingPathComponent("conversation.json")
    }
    
    private var imagesDirectory: URL {
        let dir = appFolder.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    var documentsDirectory: URL {
        let dir = appFolder.appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var toolAttachmentsDirectory: URL {
        let dir = appFolder.appendingPathComponent("tool_attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    init() {
        isPrivacyModeEnabled = UserDefaults.standard.bool(forKey: privacyModeDefaultsKey)
        loadConversation()

        // Wire up archive status notifications to Telegram
        let telegramSvc = telegramService
        let archiveSvc = archiveService
        Task { @MainActor [weak self] in
            guard let self else { return }
            let chatId = self.pairedChatId
            await archiveSvc.setStatusNotificationHandler { message in
                guard let chatId else { return }
                Task { try? await telegramSvc.sendMessage(chatId: chatId, text: message) }
            }
        }

        if shouldResumePollingOnLaunch && hasRequiredPollingConfiguration() {
            Task { [weak self] in
                await self?.startPolling()
            }
        }
    }

    private func currentVoiceTranscriptionProvider() -> VoiceTranscriptionProvider {
        VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )
    }

    private func openAITranscriptionAPIKey() -> String {
        (KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configuredGeminiImageModel() -> String {
        let configuredModel = (KeychainHelper.load(key: KeychainHelper.geminiImageModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configuredModel.isEmpty ? GeminiImagePricing.defaultModel : configuredModel
    }

    private func configuredGeminiImagePricing() -> GeminiImagePricing {
        func configuredRate(for key: String, defaultValue: Double) -> Double {
            guard let rawValue = KeychainHelper.load(key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = Double(rawValue),
                  parsed.isFinite,
                  parsed >= 0 else {
                return defaultValue
            }
            return parsed
        }

        return GeminiImagePricing(
            inputCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.inputCostPerMillionTokensUSD
            ),
            outputTextCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputTextCostPerMillionTokensUSD
            ),
            outputImageCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputImageCostPerMillionTokensUSD
            )
        )
    }
    
    // MARK: - Configuration
    
    func configure() async {
        let currentLLMProvider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        guard let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
              let chatIdString = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey),
              let chatId = Int(chatIdString) else {
            error = "Please configure Telegram settings first"
            return
        }
        let apiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        if currentLLMProvider == .openRouter && apiKey.isEmpty {
            error = "Please configure your OpenRouter API key"
            return
        }
        
        // Get optional web search keys
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        
        pairedChatId = chatId
        await telegramService.configure(token: token)
        await openRouterService.configure(apiKey: apiKey)
        
        // Configure tool executor if web search keys are available
        if !serperKey.isEmpty {
            await toolExecutor.configure(openRouterKey: apiKey, serperKey: serperKey, jinaKey: jinaKey)
        }

        // Wire the Agent (subagent) tool so it can drive its own LLM loop.
        await toolExecutor.configureOpenRouter(
            openRouterService,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory
        )
        
        // Configure archive service and recover any pending chunks from previous crash
        await archiveService.configure(apiKey: apiKey)
        let recoveryChunkSummaries = await archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        let recoveryContext = buildSummarizationContext(
            chunkSummaries: recoveryChunkSummaries,
            currentMessages: messages
        )
        await archiveService.recoverPendingChunks(defaultContext: recoveryContext)
        
        // Google Workspace via `gws` CLI — single source of truth for ambient
        // inbox + calendar awareness. Replaces IMAP (EmailService) and Gmail-API
        // (GmailService) paths. The service retries + fails gracefully if `gws`
        // is missing on this machine, so startup never blocks on it.
        await GoogleWorkspaceService.shared.setNewEmailHandler { [weak self] newEmails in
            await self?.processNewUnreadEmails(newEmails)
        }
        await GoogleWorkspaceService.shared.startBackgroundPoll()
        
        // Configure Gemini image service if API key is available
        if let geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey), !geminiApiKey.isEmpty {
            await GeminiImageService.shared.configure(
                apiKey: geminiApiKey,
                model: configuredGeminiImageModel(),
                pricing: configuredGeminiImagePricing()
            )
        }
        
        error = nil
    }
    
    // MARK: - Polling Control
    
    func startPolling() async {
        // Prevent duplicate polling tasks
        guard !isPolling else {
            print("[ConversationManager] Polling already running, ignoring duplicate start")
            return
        }
        
        await configure()
        
        guard error == nil else { return }
        
        isPolling = true
        shouldResumePollingOnLaunch = true
        statusMessage = "Polling for messages..."
        
        // Warm up Whisper only when local transcription is active.
        if currentVoiceTranscriptionProvider() == .local {
            Task {
                await WhisperKitService.shared.checkModelStatus()
            }
        }
        
        pollingTask = Task {
            while !Task.isCancelled && isPolling {
                do {
                    // Check for due reminders first
                    await checkDueReminders()

                    // Nag the agent to clean the scratch dir if it's over threshold
                    await checkScratchDiskPressure()

                    // Check for completed background bash processes
                    await checkBackgroundBashCompletions()

                    // Check for completed background subagents
                    await checkBackgroundSubagentCompletions()

                    // Check for pending bash_manage watch matches (mid-stream output triggers)
                    await checkBashWatchMatches()

                    if DebugTelemetry.shared.verbose {
                        DebugTelemetry.log(.pollTick, summary: "poll tick")
                    }

                    let updates = try await telegramService.getUpdates()
                    
                    for update in updates {
                        await processUpdate(update)
                    }
                    
                    statusMessage = "Listening... (Last check: \(formattedTime()))"
                    
                    // Poll every 1 second
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    if !Task.isCancelled {
                        statusMessage = "Error: \(error.localizedDescription)"
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds before retry
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeRunId = nil
        Task { await toolExecutor.cancelAllRunningProcesses() }
        ToolExecutor.clearPendingToolOutputs()
        
        isPolling = false
        shouldResumePollingOnLaunch = false
        pollingTask?.cancel()
        pollingTask = nil
        statusMessage = "Stopped"
    }

    private var shouldResumePollingOnLaunch: Bool {
        get {
            if UserDefaults.standard.object(forKey: shouldResumePollingDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: shouldResumePollingDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: shouldResumePollingDefaultsKey)
        }
    }

    private func hasRequiredPollingConfiguration() -> Bool {
        guard let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
              let chatIdString = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey),
              let apiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) else {
            return false
        }

        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !chatIdString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // MARK: - Message Processing
    
    private func processUpdate(_ update: TelegramUpdate) async {
        // Clear any previous error when starting to process a new message
        error = nil
        
        guard let telegramMessage = update.message else {
            return
        }
        
        // Only process messages from the paired chat
        guard telegramMessage.chat.id == pairedChatId else {
            return
        }
        
        // Skip messages from the bot itself
        if telegramMessage.from?.isBot == true {
            return
        }
        
        if let text = telegramMessage.text,
           await handleControlCommandIfNeeded(text) {
            return
        }
        
        if activeRunId != nil {
            DebugTelemetry.log(
                .messageDrop,
                summary: "dropped msg during active turn",
                detail: String((telegramMessage.text ?? "<non-text>").prefix(200)),
                isError: true
            )
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(
                    chatId: chatId,
                    text: "⏳ I'm still working on your previous request. Send /stop to interrupt it."
                )
                DebugTelemetry.log(.busyReply, summary: "sent busy auto-reply")
            }
            return
        }
        
        // Extract forward context if this is a forwarded message (accumulate with pending)
        if telegramMessage.isForwarded {
            var forwardSource = "unknown"
            
            if let origin = telegramMessage.forwardOrigin {
                forwardSource = origin.description
            } else if let fromUser = telegramMessage.forwardFrom {
                let name = [fromUser.firstName, fromUser.lastName].compactMap { $0 }.joined(separator: " ")
                forwardSource = name.isEmpty ? "a user" : name
            } else if let fromChat = telegramMessage.forwardFromChat {
                forwardSource = fromChat.title ?? "a chat"
            }
            
            let newForwardContext = "[Forwarded from \(forwardSource)]"
            if let existing = pendingForwardContext {
                pendingForwardContext = existing + "\n" + newForwardContext
            } else {
                pendingForwardContext = newForwardContext
            }
            print("[ConversationManager] User forwarded message from: \(forwardSource)")
        }
        
        // Extract reply context if user is replying to a previous message
        if let replyToMsg = telegramMessage.replyToMessage {
            var replyContent = ""
            
            if let text = replyToMsg.text, !text.isEmpty {
                replyContent = text
            } else if let caption = replyToMsg.caption, !caption.isEmpty {
                replyContent = caption
            } else if replyToMsg.photo != nil {
                replyContent = "[Image]"
            } else if let doc = replyToMsg.document {
                replyContent = "[Document: \(doc.fileName ?? "file")]"
            } else if replyToMsg.voice != nil {
                replyContent = "[Voice message]"
            } else if let video = replyToMsg.video {
                replyContent = "[Video: \(video.duration)s]"
            }
            
            if !replyContent.isEmpty {
                let senderInfo: String
                if replyToMsg.from?.isBot == true {
                    senderInfo = "your previous message"
                } else {
                    senderInfo = "their previous message"
                }
                let newReplyContext = "[Replying to \(senderInfo): \"\(replyContent)\"]"
                if let existing = pendingReplyContext {
                    pendingReplyContext = existing + "\n" + newReplyContext
                } else {
                    pendingReplyContext = newReplyContext
                }
                print("[ConversationManager] User replied to: \(replyContent.prefix(100))")
            }
            
            // Download attachments from replied-to message (add to pending referenced)
            if let photos = replyToMsg.photo, !photos.isEmpty {
                statusMessage = "Downloading referenced image..."
                let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
                
                do {
                    let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).jpg"
                    let fileURL = imagesDirectory.appendingPathComponent(fileName)
                    try imageData.write(to: fileURL)
                    
                    pendingReferencedImages.append((fileName: fileName, fileSize: imageData.count))
                    print("[ConversationManager] Buffered referenced image: \(fileName) (\(imageData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced image: \(error)")
                }
            }
            
            if let document = replyToMsg.document {
                statusMessage = "Downloading referenced document..."
                
                do {
                    let documentData = try await telegramService.downloadDocument(fileId: document.fileId)
                    let originalName = document.fileName ?? "document"
                    let ext = URL(fileURLWithPath: originalName).pathExtension
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try documentData.write(to: fileURL)
                    
                    pendingReferencedDocuments.append((fileName: fileName, fileSize: documentData.count))
                    print("[ConversationManager] Buffered referenced document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced document: \(error)")
                }
            }
            
            // Download referenced video if user replied to a video message
            if let video = replyToMsg.video {
                statusMessage = "Downloading referenced video..."
                
                do {
                    let videoData = try await telegramService.downloadDocument(fileId: video.fileId)
                    let ext: String
                    if let mimeType = video.mimeType {
                        switch mimeType {
                        case "video/mp4": ext = "mp4"
                        case "video/quicktime": ext = "mov"
                        case "video/webm": ext = "webm"
                        default: ext = "mp4"
                        }
                    } else {
                        ext = "mp4"
                    }
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try videoData.write(to: fileURL)
                    
                    pendingReferencedDocuments.append((fileName: fileName, fileSize: videoData.count))
                    print("[ConversationManager] Buffered referenced video: \(fileName) (\(videoData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced video: \(error)")
                }
            }
        }
        
        // Determine what type of message this is and whether to trigger processing
        var triggerText: String? = nil
        
        // Text message → triggers processing
        if let text = telegramMessage.text, !text.isEmpty {
            triggerText = text
        }
        // Photo message
        else if let photos = telegramMessage.photo, !photos.isEmpty {
            statusMessage = "Downloading image..."
            
            let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
            
            do {
                let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                
                let fileName = "\(UUID().uuidString.prefix(8)).jpg"
                let fileURL = imagesDirectory.appendingPathComponent(fileName)
                try imageData.write(to: fileURL)
                
                // Also save to documents directory for email attachments
                let documentsFileURL = documentsDirectory.appendingPathComponent(fileName)
                try imageData.write(to: documentsFileURL)
                
                pendingImages.append((fileName: fileName, fileSize: imageData.count))
                print("[ConversationManager] Buffered image: \(fileName) (\(imageData.count) bytes)")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download image: \(error.localizedDescription)"
                statusMessage = "Image download failed"
                return
            }
        }
        // Voice message → transcription triggers processing
        else if let voice = telegramMessage.voice {
            let transcriptionProvider = currentVoiceTranscriptionProvider()
            statusMessage = transcriptionProvider == .openAI
                ? "Transcribing audio with OpenAI..."
                : "Transcribing audio locally..."
            
            do {
                let audioURL = try await telegramService.downloadVoiceFile(fileId: voice.fileId)
                defer { try? FileManager.default.removeItem(at: audioURL) }

                let transcription: String?
                switch transcriptionProvider {
                case .openAI:
                    let apiKey = openAITranscriptionAPIKey()
                    guard !apiKey.isEmpty else {
                        self.error = "OpenAI API key not set. Add it in Settings > Voice Transcription."
                        statusMessage = "OpenAI API key missing"
                        return
                    }
                    transcription = await OpenAITranscriptionService.shared.transcribeAudioFile(url: audioURL, apiKey: apiKey)
                case .local:
                    guard WhisperKitService.shared.isModelReady else {
                        self.error = "Voice model not ready. Please download it in Settings."
                        statusMessage = "Voice model not ready"
                        return
                    }
                    transcription = await WhisperKitService.shared.transcribeAudioFile(url: audioURL)
                }

                if let transcription {
                    triggerText = transcription
                    print("[ConversationManager] Transcribed voice: \(transcription)")
                } else {
                    self.error = "Failed to transcribe audio"
                    statusMessage = "Transcription failed"
                    return
                }
            } catch {
                self.error = "Failed to download voice file: \(error.localizedDescription)"
                statusMessage = "Voice download failed"
                return
            }
        }
        // Document message
        else if let document = telegramMessage.document {
            statusMessage = "Downloading document..."
            
            do {
                let documentData = try await telegramService.downloadDocument(fileId: document.fileId)
                
                let originalName = document.fileName ?? "document"
                let ext = URL(fileURLWithPath: originalName).pathExtension
                let fileName = "\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                let fileURL = documentsDirectory.appendingPathComponent(fileName)
                try documentData.write(to: fileURL)
                
                pendingDocuments.append((fileName: fileName, fileSize: documentData.count))
                print("[ConversationManager] Buffered document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download document: \(error.localizedDescription)"
                statusMessage = "Document download failed"
                return
            }
        }
        // Video message - treated as a document for storage and email purposes
        else if let video = telegramMessage.video {
            statusMessage = "Downloading video..."
            
            do {
                let videoData = try await telegramService.downloadDocument(fileId: video.fileId)
                
                // Use original filename if available, otherwise generate one with proper extension
                let ext: String
                if let mimeType = video.mimeType {
                    switch mimeType {
                    case "video/mp4": ext = "mp4"
                    case "video/quicktime": ext = "mov"
                    case "video/webm": ext = "webm"
                    case "video/x-matroska": ext = "mkv"
                    default: ext = "mp4"
                    }
                } else {
                    ext = "mp4"
                }
                
                let fileName = video.fileName ?? "\(UUID().uuidString.prefix(8)).\(ext)"
                let fileURL = documentsDirectory.appendingPathComponent(fileName)
                try videoData.write(to: fileURL)
                
                pendingDocuments.append((fileName: fileName, fileSize: videoData.count))
                print("[ConversationManager] Buffered video: \(fileName) (\(videoData.count) bytes, \(video.duration)s, \(video.width)x\(video.height))")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download video: \(error.localizedDescription)"
                statusMessage = "Video download failed"
                return
            }
        }
        
        // If no trigger text, just show status and return (media is buffered)
        guard let promptText = triggerText else {
            let imageCount = pendingImages.count
            let docCount = pendingDocuments.count
            if imageCount > 0 || docCount > 0 {
                var parts: [String] = []
                if imageCount > 0 { parts.append("\(imageCount) image\(imageCount > 1 ? "s" : "")") }
                if docCount > 0 { parts.append("\(docCount) file\(docCount > 1 ? "s" : "")") }
                statusMessage = "📎 \(parts.joined(separator: ", ")) waiting for your message..."
            }
            return
        }
        
        // Build message content with forward and reply context
        var messageContent = promptText
        if let fwdContext = pendingForwardContext {
            messageContent = fwdContext + "\n\n" + messageContent
        }
        if let replyCtx = pendingReplyContext {
            messageContent = replyCtx + "\n\n" + messageContent
        }
        
        // Combine all pending media into the message
        let userMessage = Message(
            role: .user,
            content: messageContent,
            imageFileNames: pendingImages.map { $0.fileName },
            documentFileNames: pendingDocuments.map { $0.fileName },
            imageFileSizes: pendingImages.map { $0.fileSize },
            documentFileSizes: pendingDocuments.map { $0.fileSize },
            referencedImageFileNames: pendingReferencedImages.map { $0.fileName },
            referencedDocumentFileNames: pendingReferencedDocuments.map { $0.fileName },
            referencedDocumentFileSizes: pendingReferencedDocuments.map { $0.fileSize }
        )
        
        // Clear all buffers
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        pendingReferencedImages.removeAll()
        pendingReferencedDocuments.removeAll()
        pendingForwardContext = nil
        pendingReplyContext = nil
        
        messages.append(userMessage)
        saveConversation()
        
        statusMessage = "Generating response..."
        startActiveProcessing(for: userMessage)
    }

    private func startActiveProcessing(for userMessage: Message) {
        guard activeRunId == nil, activeProcessingTask == nil else {
            print("[ConversationManager] Ignoring startActiveProcessing because a run is already active")
            return
        }

        let runId = UUID()
        activeRunId = runId

        activeProcessingTask = Task { [weak self] in
            await self?.runActiveProcessing(for: userMessage, runId: runId)
        }
    }

    private func runActiveProcessing(
        for userMessage: Message,
        runId: UUID
    ) async {
        defer {
            if activeRunId == runId {
                activeRunId = nil
                activeProcessingTask = nil
                currentTurnLogIsActive = false
            }
        }

        // Reset the per-turn tool log so /status shows only this turn.
        currentTurnToolLog = []
        currentTurnLogIsActive = true

        let turnStartedAt = Date()
        DebugTelemetry.log(
            .turnStart,
            summary: "turn for msg \(userMessage.id.uuidString.prefix(8))",
            detail: String(userMessage.content.prefix(200))
        )

        do {
            let turnStartDate = turnStartedAt
            try Task.checkCancellation()
            let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)
            try Task.checkCancellation()
            
            guard activeRunId == runId else { return }
            
            var didMutateHistory = false

            // Agent can stay silent on ambient triggers (email arrivals, subagent
            // completions, reminders) by returning [SKIP] or empty text. We still
            // record the turn in history for diagnostics but suppress the Telegram
            // push so the user isn't pinged for every ad, newsletter, or
            // inconsequential background event. User-initiated turns never silently
            // skip — a missing reply there would be a bug.
            let trimmedResponse = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAmbientTrigger = userMessage.kind != .userText
            let agentChoseSilence = isAmbientTrigger && (trimmedResponse.isEmpty || trimmedResponse == "[SKIP]")

            // Add assistant message with tool interactions, compact log, downloaded files, and accessed projects
            let finalResponseRaw: String
            if agentChoseSilence {
                finalResponseRaw = "[SKIP]"
            } else if trimmedResponse.isEmpty {
                finalResponseRaw = "I completed the requested actions."
            } else {
                finalResponseRaw = response.finalText
            }
            let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
            let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
            // Store measured token count on the user message that triggered this turn
            if let measuredUser = response.measuredUserTokens,
               let idx = messages.lastIndex(where: { $0.id == userMessage.id }) {
                messages[idx].measuredTokens = measuredUser
            }
            // Update final-text completion tokens for next-turn delta attribution.
            // Tool replay is already included in the prior prompt; subtracting it
            // here would undercount the next user message, especially after heavy
            // tool/file turns.
            if let assistantCompletionTokens = response.measuredAssistantCompletionTokens {
                lastCompletionTokens = assistantCompletionTokens
            }
            let assistantMessage = Message(
                role: .assistant,
                content: finalResponse,
                downloadedDocumentFileNames: downloadedFilenames,
                editedFilePaths: response.editedFilePaths,
                generatedFilePaths: response.generatedFilePaths,
                accessedProjectIds: response.accessedProjects ?? [],
                subagentSessionEvents: response.subagentSessionEvents,
                toolInteractions: response.toolInteractions,
                compactToolLog: response.compactToolLog,
                measuredToolTokens: response.measuredToolTokens,
                measuredTokens: response.measuredAssistantTokens
            )
            messages.append(assistantMessage)
            didMutateHistory = true

            if didMutateHistory {
                saveConversation()
            }

            if let chatId = pairedChatId, !agentChoseSilence {
                try Task.checkCancellation()
                guard activeRunId == runId else { return }
                try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                
                // Send any generated images (from tool executor, renamed to avoid conflict)
                let toolGeneratedImages = ToolExecutor.getPendingImages()
                for (imageData, mimeType, prompt) in toolGeneratedImages {
                    try Task.checkCancellation()
                    guard activeRunId == runId else { return }
                    
                    do {
                        let caption = "🎨 Generated: \(prompt.prefix(200))\(prompt.count > 200 ? "..." : "")"
                        try await telegramService.sendPhoto(chatId: chatId, imageData: imageData, caption: caption, mimeType: mimeType)
                        print("[ConversationManager] Sent generated image (\(imageData.count) bytes)")
                    } catch {
                        print("[ConversationManager] Failed to send generated image: \(error)")
                    }
                }
                
                // Send any queued documents (or photos if the file is an image)
                let toolPendingDocuments = ToolExecutor.getPendingDocuments()
                for (documentData, filename, mimeType, caption) in toolPendingDocuments {
                    try Task.checkCancellation()
                    guard activeRunId == runId else { return }
                    
                    do {
                        if mimeType.hasPrefix("image/") {
                            try await telegramService.sendPhoto(chatId: chatId, imageData: documentData, caption: caption, mimeType: mimeType)
                            print("[ConversationManager] Sent image as photo: \(filename) (\(documentData.count) bytes)")
                        } else {
                            try await telegramService.sendDocument(chatId: chatId, documentData: documentData, filename: filename, caption: caption, mimeType: mimeType)
                            print("[ConversationManager] Sent document: \(filename) (\(documentData.count) bytes)")
                        }
                    } catch {
                        print("[ConversationManager] Failed to send document \(filename): \(error)")
                    }
                }
            }
            
            // Descriptions are generated lazily at Watermark prune time, just
            // before inline media/tool attachments leave prompt context. Drain the
            // legacy pending-data queue so large blobs do not leak across turns.
            _ = ToolExecutor.getPendingFilesForDescription()
            
            guard activeRunId == runId else { return }
            let turnMs = Int(Date().timeIntervalSince(turnStartedAt) * 1000)
            DebugTelemetry.log(.turnEnd, summary: "turn complete", durationMs: turnMs)
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        } catch is CancellationError {
            ToolExecutor.clearPendingToolOutputs()
            DebugTelemetry.log(.turnCancelled, summary: "turn cancelled")
            if activeRunId == runId {
                statusMessage = "Cancelled"
            }
            print("[ConversationManager] Active run cancelled")
        } catch {
            ToolExecutor.clearPendingToolOutputs()
            DebugTelemetry.log(
                .turnError,
                summary: "turn failed",
                detail: String(describing: error),
                isError: true
            )
            if activeRunId == runId {
                self.error = "Failed to generate response: \(error.localizedDescription)"
                statusMessage = "Error generating response"
            }

            // Surface the failure to the user. Previously a thrown turn just
            // updated a local `error` property and died silently — from the
            // user's side that looks identical to "stuck", because no Telegram
            // reply ever arrives. Append a visible error message to history
            // AND send a Telegram ping so the user knows the turn is dead and
            // a retry is needed. The text includes enough detail to diagnose
            // common cases (rate limit, network, provider outage) without
            // leaking internal stack details.
            let errText = "❌ Turn failed: \(error.localizedDescription). Send another message to retry."
            let errMessage = Message(role: .assistant, content: errText)
            messages.append(errMessage)
            saveConversation()
            if let chatId = pairedChatId {
                do {
                    try await telegramService.sendMessage(chatId: chatId, text: errText)
                } catch {
                    print("[ConversationManager] Also failed to send error reply to Telegram: \(error)")
                }
            }
        }
    }
    
    private func commandToken(from text: String) -> String {
        let firstToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased() ?? ""
        return firstToken.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
    }
    
    private func handleControlCommandIfNeeded(_ text: String) async -> Bool {
        let token = commandToken(from: text)
        
        switch token {
        case "/stop":
            await stopActiveExecution()
            return true
        case "/spend":
            await sendSpendSnapshot()
            return true
        case "/more1":
            await increaseSpendLimitIfNeeded(by: 1)
            return true
        case "/more5":
            await increaseSpendLimitIfNeeded(by: 5)
            return true
        case "/more10":
            await increaseSpendLimitIfNeeded(by: 10)
            return true
        case "/hide":
            await setPrivacyMode(enabled: true)
            return true
        case "/show":
            await setPrivacyMode(enabled: false)
            return true
        case "/transcribe_local":
            await switchVoiceTranscriptionProvider(to: .local)
            return true
        case "/transcribe_openai":
            await switchVoiceTranscriptionProvider(to: .openAI)
            return true
        case "/prune":
            await manualPruneToolInteractions()
            return true
        case "/status":
            await sendTurnStatus()
            return true
        default:
            return false
        }
    }

    /// Reply with a chronological snapshot of tool activity in the current
    /// (or most recently completed) turn. Replaces the old always-on
    /// progress-ping model — user pulls the info on demand rather than
    /// being bombarded with one message per tool call.
    private func sendTurnStatus() async {
        guard let chatId = pairedChatId else { return }
        let log = currentTurnToolLog

        let contextLine = formatContextGaugeLine()

        if log.isEmpty {
            let msg = activeRunId != nil
                ? "⏳ Working on it — no tool calls yet.\n\(contextLine)"
                : "💤 Idle. No tool activity to report.\n\(contextLine)"
            try? await telegramService.sendMessage(chatId: chatId, text: msg)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let header = currentTurnLogIsActive
            ? "⚙️ Current turn — \(log.count) tool call\(log.count == 1 ? "" : "s") so far:"
            : "✅ Last turn — \(log.count) tool call\(log.count == 1 ? "" : "s"):"

        var lines: [String] = [header]
        for entry in log {
            let emoji = Self.progressEmoji(forToolName: entry.name)
            let time = formatter.string(from: entry.startedAt)
            lines.append("  [\(time)] \(emoji) \(entry.name)")
        }
        lines.append("")
        lines.append(contextLine)

        try? await telegramService.sendMessage(chatId: chatId, text: lines.joined(separator: "\n"))
    }

    private func formatContextGaugeLine() -> String {
        let max = configuredMaxContextTokens()
        if let current = lastPromptTokens {
            let currentStr = Self.formatTokenCountCompact(current)
            let maxStr = Self.formatTokenCountCompact(max)
            let pct = Int(round(Double(current) / Double(max) * 100))
            return "📊 Context: \(currentStr)/\(maxStr) (\(pct)%)"
        }
        let maxStr = Self.formatTokenCountCompact(max)
        return "📊 Context: —/\(maxStr)"
    }

    private static func formatTokenCountCompact(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M"
                : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(count)"
    }

    /// Emoji for a single tool name — used by /status to render each row.
    /// Same palette as `getProgressMessage` but indexed by tool name instead
    /// of batch characterization.
    private static func progressEmoji(forToolName name: String) -> String {
        if name.hasPrefix("mcp__playwright__") { return "🌐" }
        if name.hasPrefix("mcp__nano-banana__") { return "🎨" }
        if name.hasPrefix("mcp__") { return "🔌" }
        switch name {
        case "web_research_sweep": return "🧠🔍"
        case "web_search": return "🔍"
        case "web_fetch": return "🌐"
        case "Agent": return "🤖"
        case "subagent_manage": return "🤖"
        case "generate_image": return "🎨"
        case "manage_reminders": return "⏰"
        case "write_file", "edit_file", "apply_patch": return "✏️"
        case "read_file", "grep", "glob", "list_dir", "list_recent_files": return "🔎"
        case "lsp": return "🔬"
        case "bash", "bash_manage": return "💻"
        case "send_document_to_chat": return "📎"
        case "shortcuts", "run_shortcut", "list_shortcuts": return "⌘"
        case "todo_write": return "📋"
        case "view_conversation_chunk": return "🗂"
        default: return "🔧"
        }
    }

    private func manualPruneToolInteractions() async {
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messages)
        let providerIsLMStudio = currentProviderIsLMStudio()

        // Estimate current context with a rough system prompt estimate
        var totalTokens = 3000 // System prompt overhead estimate
        let persona = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        totalTokens += persona.count / 4

        var prunableToolTokens = 0
        for (i, message) in messages.enumerated() {
            totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
            let msgToolTokens = toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            totalTokens += msgToolTokens
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += msgToolTokens
            }
        }

        guard prunableToolTokens > 0 else {
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(chatId: chatId, text: "No prunable tool interactions (the latest turn is always protected).")
            }
            return
        }

        let beforeTokens = totalTokens

        // Single chronological pass: prune oldest content first (tools + media)
        var prunedToolCount = 0
        var prunedMediaCount = 0
        for i in 0..<messages.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }

            if messages[i].role == .assistant && !messages[i].toolInteractions.isEmpty {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: false,
                    includeToolAttachments: true,
                    sourceMessages: messages
                )
                let savedTokens = toolInteractionTokens(messages[i].toolInteractions, isLMStudio: providerIsLMStudio)
                messages[i].toolInteractions = []
                totalTokens -= savedTokens
                prunedToolCount += 1
            }

            guard totalTokens > targetTokens else { break }

            if messages[i].hasUnprunedMedia {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: true,
                    includeToolAttachments: false,
                    sourceMessages: messages
                )
                let savedTokens = mediaSavingsForMessage(messages[i], isLMStudio: providerIsLMStudio)
                messages[i].mediaPruned = true
                totalTokens -= savedTokens
                prunedMediaCount += 1
            }
        }

        if prunedToolCount > 0 {
            pruneOldCompactToolLogs()
        }
        if prunedToolCount > 0 || prunedMediaCount > 0 {
            saveConversation()
            cleanupOrphanedToolAttachmentSnapshots()
            refreshSystemPromptTimestamp()
        }

        if let chatId = pairedChatId {
            let msg = (prunedToolCount > 0 || prunedMediaCount > 0)
                ? "✂️ Pruned tools from \(prunedToolCount) turn(s), media from \(prunedMediaCount) message(s). Context: ~\(beforeTokens / 1000)K → ~\(totalTokens / 1000)K tokens (target: \(targetTokens / 1000)K). Latest turn protected."
                : "Context already under target (~\(totalTokens / 1000)K ≤ \(targetTokens / 1000)K). Nothing to prune."
            try? await telegramService.sendMessage(chatId: chatId, text: msg)
        }
    }
    
    private func switchVoiceTranscriptionProvider(to provider: VoiceTranscriptionProvider) async {
        let currentProvider = currentVoiceTranscriptionProvider()
        let providerDisplayName = provider.displayName
        let switchedMessage: String

        if currentProvider == provider {
            switchedMessage = "✅ Voice transcription already set to \(providerDisplayName)."
        } else {
            do {
                try KeychainHelper.save(
                    key: KeychainHelper.voiceTranscriptionProviderKey,
                    value: provider.rawValue
                )
                switchedMessage = "✅ Switched voice transcription to \(providerDisplayName)."
            } catch {
                let errorMessage = "❌ Failed to switch voice transcription to \(providerDisplayName): \(error.localizedDescription)"
                if let chatId = pairedChatId {
                    try? await telegramService.sendMessage(chatId: chatId, text: errorMessage)
                }
                if activeRunId == nil {
                    statusMessage = "Listening... (Last check: \(formattedTime()))"
                }
                return
            }
        }

        var advisoryNotes: [String] = []
        if provider == .openAI {
            if openAITranscriptionAPIKey().isEmpty {
                advisoryNotes.append("⚠️ OpenAI API key missing. Add it in Settings > Voice Transcription.")
            }
        } else {
            await WhisperKitService.shared.checkModelStatus()
            if !WhisperKitService.shared.isModelReady {
                advisoryNotes.append("⚠️ \(WhisperKitService.shared.statusMessage). Configure the Whisper model in Settings > Voice Transcription.")
            }
        }

        let message = ([switchedMessage] + advisoryNotes).joined(separator: "\n")
        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    private func sendSpendSnapshot() async {
        let snapshot = KeychainHelper.openRouterSpendSnapshot(referenceDate: Date())
        let extra = KeychainHelper.openRouterSpendLimitIncreaseSnapshot(referenceDate: Date())
        var lines = [
            "💸 API spend",
            "Today: $\(formatUSD(snapshot.today))",
            "This month: $\(formatUSD(snapshot.month))"
        ]
        if extra.daily > 0 {
            lines.append("Today's extra limit: +$\(formatUSD(extra.daily))")
        }
        if extra.monthly > 0 {
            lines.append("This month's extra limit: +$\(formatUSD(extra.monthly))")
        }
        let message = lines.joined(separator: "\n")

        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    private func setPrivacyMode(enabled: Bool) async {
        guard isPrivacyModeEnabled != enabled else {
            if let chatId = pairedChatId {
                let message = enabled
                    ? "Privacy mode is already enabled. The on-screen conversation and context viewer stay hidden until you send /show."
                    : "Privacy mode is already disabled. The conversation and context viewer are visible again."
                try? await telegramService.sendMessage(chatId: chatId, text: message)
            }

            if activeRunId == nil {
                statusMessage = "Listening... (Last check: \(formattedTime()))"
            }
            return
        }

        isPrivacyModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: privacyModeDefaultsKey)

        if let chatId = pairedChatId {
            let message = enabled
                ? "Privacy mode enabled. The macOS app now hides the conversation and disables the context viewer until you send /show."
                : "Privacy mode disabled. The macOS app shows the conversation and re-enables the context viewer."
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = enabled
                ? "Privacy mode enabled"
                : "Listening... (Last check: \(formattedTime()))"
        }
    }
    
    private func stopActiveExecution() async {
        let wasRunning = activeRunId != nil

        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeRunId = nil
        currentTurnLogIsActive = false

        // Kill every background subagent too — /stop is a blanket halt for all
        // active cost-accruing work the user invoked. (In-flight archiving /
        // user-context extraction are deliberately NOT cancelled here; they
        // run on detached tasks that continue to completion so we don't lose
        // summaries or fact extraction mid-flight.)
        let killedBackgroundSubagents = await SubagentBackgroundRegistry.shared.cancelAll()

        await toolExecutor.cancelAllRunningProcesses()
        ToolExecutor.clearPendingToolOutputs()

        if let chatId = pairedChatId {
            var text = wasRunning ? "⛔ Stopped current execution." : "Nothing is currently running."
            if killedBackgroundSubagents > 0 {
                text += " Also cancelled \(killedBackgroundSubagents) background subagent\(killedBackgroundSubagents == 1 ? "" : "s")."
            }
            try? await telegramService.sendMessage(chatId: chatId, text: text)
        }

        statusMessage = wasRunning ? "Cancelled" : "Listening... (Last check: \(formattedTime()))"
    }

    private func increaseSpendLimitIfNeeded(by amountUSD: Double) async {
        let status = currentSpendLimitStatus(referenceDate: Date())
        let applyToDaily = status.dailyExceeded && status.dailyBaseLimitUSD != nil
        let applyToMonthly = status.monthlyExceeded && status.monthlyBaseLimitUSD != nil

        let message: String
        if applyToDaily || applyToMonthly {
            KeychainHelper.addOpenRouterSpendLimitIncrease(
                amountUSD,
                applyToDaily: applyToDaily,
                applyToMonthly: applyToMonthly
            )

            let updatedStatus = currentSpendLimitStatus(referenceDate: Date())
            if applyToDaily, applyToMonthly {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to both reached spend limits.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            } else if applyToDaily {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to today's spend limit.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                """
            } else {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to this month's spend limit.
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            }
        } else {
            message = "No daily or monthly spend limit is currently reached. `/more1`, `/more5`, and `/more10` only work after a daily or monthly cap has been hit."
        }

        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }
    
    // MARK: - Tool-Aware Response Generation
    
    private func generateResponseWithTools(currentUserMessageId: UUID, turnStartDate: Date) async throws -> ToolAwareResponse {
        try Task.checkCancellation()
        defer {
            // File descriptions are now created at prune time from persisted
            // message/tool attachment state, not from this transient byte queue.
            _ = ToolExecutor.getPendingFilesForDescription()
        }

        // Snapshot FilesLedger up-front so we can report the set of files that were
        // edited/generated during the turn on the resulting assistant Message. This
        // is surfaced in the UI (MessageBubbleView) and in archived summaries.
        let ledgerPreSnapshot = await FilesLedgerDiff.snapshot()

        // Local helper: compute the diff now. Closure-captured so every return path
        // below produces the same `editedFilePaths` / `generatedFilePaths` pair.
        // NB: any ledger writes that happen AFTER this call (none are expected —
        // all tool writes are recorded synchronously via FilesLedger.shared.record)
        // will bleed into the next turn's snapshot rather than this one.
        @Sendable func computeLedgerDiff() async -> FilesLedgerDiff.Changed {
            let post = await FilesLedgerDiff.snapshot()
            return FilesLedgerDiff.diff(pre: ledgerPreSnapshot, post: post)
        }

        // Check if tools are available
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""

        // Fetch all context data in PARALLEL for performance.
        // Calendar + email use the frozen session-level cache: populated on first turn,
        // refreshed only on prune events and local-day rollover. The helper returns
        // instantly on cache hits, so awaiting it in parallel with the others is free.
        let contextStartTime = Date()
        async let frozenContextTask = getFrozenSystemContext()
        async let chunkSummariesTask = archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        async let totalChunkCountTask = archiveService.getAllChunks()
        async let contextResultTask = openRouterService.processContextWindow(messages)

        // Await all parallel operations.
        // calendarContext / emailContext remain `var` because prune events below
        // force a cache refresh and we want the new values to flow to the LLM call.
        let frozenContext = await frozenContextTask
        var calendarContext = frozenContext.calendar
        var emailContext = frozenContext.email
        let chunkSummaries = await chunkSummariesTask
        let allChunks = await totalChunkCountTask
        let totalChunkCount = allChunks.count
        let contextResult = await contextResultTask
        try Task.checkCancellation()
        print("[TIMING] Context fetch took: \(String(format: "%.2f", Date().timeIntervalSince(contextStartTime)))s")
        
        // Archive messages if threshold exceeded (based on conversation text weight only).
        // Summarization is critical: we MUST complete it before proceeding to avoid data loss.
        //
        // The archive loop runs on a DETACHED task so it's immune to /stop — the user
        // can abort the turn's LLM + tool work without losing the expensive summary
        // generation (which also drives user-context fact extraction inside
        // ConversationArchiveService). Task<Void, Never>.value waits to completion
        // regardless of the parent's cancellation state.
        if contextResult.needsArchiving && !contextResult.messagesToArchive.isEmpty {
            let archiveStartTime = Date()
            let messagesToArchive = contextResult.messagesToArchive
            let summarizationContext = buildSummarizationContext(
                chunkSummaries: chunkSummaries,
                currentMessages: contextResult.messagesToSend
            )
            let chatIdForNotice = pairedChatId
            let telegramSvc = telegramService
            let archiveSvc = archiveService

            if let chatId = chatIdForNotice {
                try? await telegramService.sendMessage(chatId: chatId, text: "🧠 Summarizing conversation history...")
            }

            let archiveTask = Task.detached {
                var archived = false
                var retryCount = 0
                let baseDelay: UInt64 = 2_000_000_000
                let maxDelay: UInt64 = 60_000_000_000
                while !archived {
                    do {
                        _ = try await archiveSvc.archiveMessages(messagesToArchive, context: summarizationContext)
                        print("[ConversationManager] Archived \(messagesToArchive.count) messages successfully")
                        archived = true
                    } catch {
                        retryCount += 1
                        let delay = min(baseDelay * UInt64(pow(2.0, Double(min(retryCount - 1, 5)))), maxDelay)
                        print("[ConversationManager] Archive failed (attempt \(retryCount)): \(error). Retrying in \(delay / 1_000_000_000)s...")
                        if retryCount == 1, let chatId = chatIdForNotice {
                            try? await telegramSvc.sendMessage(chatId: chatId, text: "📦 Archiving conversation history, please wait...")
                        }
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
            }
            // Wait for the archive task. For Task<Void, Never>, the await doesn't
            // throw on parent cancellation — it just waits until the detached work
            // completes. /stop can't sabotage the archive mid-flight.
            await archiveTask.value

            // Now back on the main actor — remove archived messages from the
            // in-memory conversation. This is the ONLY place we mutate `messages`
            // after archiving, and we're guaranteed the archive finished.
            let archivedCount = messagesToArchive.count
            if messages.count >= archivedCount {
                messages.removeFirst(archivedCount)
                lastPromptTokens = nil
                saveConversation()
                cleanupOrphanedToolAttachmentSnapshots()
                print("[ConversationManager] Removed \(archivedCount) archived messages from active conversation")
            }
            print("[TIMING] Archive took: \(String(format: "%.2f", Date().timeIntervalSince(archiveStartTime)))s")
        }

        // Prune stored tool interactions if full context exceeds budget
        let didPrune = await pruneToolInteractionsIfNeeded(
            currentUserMessageId: currentUserMessageId,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries
        )
        if didPrune {
            refreshSystemPromptTimestamp()
            // Cache is already invalidated by the prune — take the opportunity to
            // refresh stale calendar/email context with current data for free.
            let refreshed = await getFrozenSystemContext(forceRefresh: true)
            calendarContext = refreshed.calendar
            emailContext = refreshed.email
        }

        // Use the frozen system prompt timestamp (only refreshes on prune events or day change)
        let systemPromptDate = currentSystemPromptTimestamp()

        // Capture messages after archival + pruning for the agentic loop (var for mid-loop pruning)
        var messagesForLLM = messages

        // Tool interaction loop with per-turn, daily, and monthly spend caps (USD).
        let toolSpendLimitPerTurnUSD = configuredToolSpendLimitPerTurnUSD()
        let spendLimitStatus = currentSpendLimitStatus(referenceDate: Date())
        let toolSpendLimitDailyUSD = spendLimitStatus.effectiveDailyLimitUSD
        let toolSpendLimitMonthlyUSD = spendLimitStatus.effectiveMonthlyLimitUSD
        var cumulativeToolSpendUSD: Double = 0
        var toolInteractions: [ToolInteraction] = []
        var didHitToolSpendLimit = false
        var todaySpentUSD = spendLimitStatus.todaySpentUSD
        var monthSpentUSD = spendLimitStatus.monthSpentUSD

        if let exceededMessage = spendLimitExceededMessage(
            todaySpentUSD: todaySpentUSD,
            monthSpentUSD: monthSpentUSD,
            dailyLimitUSD: toolSpendLimitDailyUSD,
            monthlyLimitUSD: toolSpendLimitMonthlyUSD
        ) {
            print("[ConversationManager] Daily/monthly spend limit already reached before tool loop: \(exceededMessage)")
            let changed = await computeLedgerDiff()
            return ToolAwareResponse(
                finalText: exceededMessage,
                compactToolLog: nil,
                toolInteractions: [],
                accessedProjects: [],
                measuredToolTokens: nil,
                measuredUserTokens: nil,
                measuredAssistantTokens: nil,
                measuredAssistantCompletionTokens: nil,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: []
            )
        }

        var sessionEvents: [SubagentSessionEvent] = []

        // Track prompt_tokens across rounds to compute per-interaction deltas
        var prevRoundPromptTokens: Int? = lastPromptTokens
        let turnStartPromptTokens = lastPromptTokens
        let turnStartCompletionTokens = lastCompletionTokens
        var measuredUserTokens: Int?
        var finalCompletionTokens: Int?

        toolLoop: for round in 1...maxToolRoundsSafetyLimit {
            try Task.checkCancellation()
            print("[ConversationManager] Tool round \(round) (turn spend: $\(formatUSD(cumulativeToolSpendUSD)) / $\(formatUSD(toolSpendLimitPerTurnUSD)), today: $\(formatUSD(todaySpentUSD)), month: $\(formatUSD(monthSpentUSD)))")
            
            // Call LLM (with tools available for chaining)
            let llmStartTime = Date()
            // Sync MCPAgentRouting's cache so SubagentTypes.all() and the
            // per-agent filter below see up-to-date installed-server state.
            await MCPAgentRouting.refreshFromRegistry()

            let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
            // Phase 2 default: main agent sees no MCP tools unless the user
            // opts them in via ~/LocalAgent/mcp-routing.json ("main": {...}).
            // "always" tools go in the tools array; "deferred" get a summary
            // in the system prompt for on-demand discovery.
            let mainMcpTools = MCPAgentRouting.filterMcpTools(
                forAgent: "main",
                allTools: allMcpTools,
                fallbackPatterns: nil
            )
            let deferredServerNames = MCPAgentRouting.deferredServers(
                forAgent: "main",
                allTools: allMcpTools,
                fallbackPatterns: nil
            )
            let deferredSummaries = await MCPRegistry.shared.serverSummaries(for: deferredServerNames)

            let nativeTools = AvailableTools.all(
                includeWebSearch: !serperKey.isEmpty,
                hasDeferredMCPs: !deferredSummaries.isEmpty
            )
            let toolsForRound = nativeTools + mainMcpTools
            let allowedToolNames = Set(toolsForRound.map { $0.function.name })
            let response = try await openRouterService.generateResponse(
                messages: messagesForLLM,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                tools: toolsForRound,  // Always pass tools so LLM can chain calls
                toolResultMessages: toolInteractions.isEmpty ? nil : toolInteractions,
                calendarContext: calendarContext,
                emailContext: emailContext,
                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                totalChunkCount: totalChunkCount,
                currentUserMessageId: currentUserMessageId,
                turnStartDate: systemPromptDate,
                deferredMCPSummaries: deferredSummaries.isEmpty ? nil : deferredSummaries
            )
            print("[TIMING] LLM API call took: \(String(format: "%.2f", Date().timeIntervalSince(llmStartTime)))s")
            let roundSpendUSD = spendUSD(from: response)
            if let roundSpendUSD, roundSpendUSD > 0 {
                cumulativeToolSpendUSD += roundSpendUSD
                todaySpentUSD += roundSpendUSD
                monthSpentUSD += roundSpendUSD
                KeychainHelper.recordOpenRouterSpend(roundSpendUSD)
                print("[ConversationManager] Round \(round) spend: +$\(formatUSD(roundSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
            } else {
                print("[ConversationManager] Round \(round) spend unavailable or zero")
            }
            
            switch response {
            case .text(let content, let promptTokens, let completionTokens, _):
                // LLM decided to respond with text - we're done
                if let tokens = promptTokens {
                    lastPromptTokens = tokens
                    // Attribute delta to the last tool interaction if one exists
                    if let prev = prevRoundPromptTokens, !toolInteractions.isEmpty {
                        let delta = tokens - prev
                        applyMeasuredTokenDelta(delta, to: &toolInteractions[toolInteractions.count - 1])
                    }
                    // Compute user message tokens from first-round delta
                    if measuredUserTokens == nil, let start = turnStartPromptTokens {
                        let totalDelta = tokens - start
                        let prevAssistant = turnStartCompletionTokens ?? 0
                        measuredUserTokens = max(totalDelta - prevAssistant, 0)
                    }
                    print("[ConversationManager] LLM returned text response after \(round) round(s) (\(tokens) prompt tokens)")
                } else {
                    print("[ConversationManager] LLM returned text response after \(round) round(s)")
                }
                finalCompletionTokens = completionTokens
                // Sum measured costs across all tool interactions
                let totalMeasured = toolInteractionTokens(toolInteractions)
                let accessedProjects = extractAccessedProjects(from: toolInteractions)
                let changed = await computeLedgerDiff()
                return ToolAwareResponse(
                    finalText: content,
                    compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                    toolInteractions: toolInteractions,
                    accessedProjects: accessedProjects,
                    measuredToolTokens: totalMeasured > 0 ? totalMeasured : nil,
                    measuredUserTokens: measuredUserTokens,
                    measuredAssistantTokens: {
                        let total = (finalCompletionTokens ?? 0) + totalMeasured
                        return total > 0 ? total : nil
                    }(),
                    measuredAssistantCompletionTokens: finalCompletionTokens,
                    editedFilePaths: changed.edited,
                    generatedFilePaths: changed.generated,
                    subagentSessionEvents: sessionEvents
                )

            case .toolCalls(let assistantMessage, let calls, let roundPromptTokens, _, _):
                // Model wants to use more tools
                print("[ConversationManager] Round \(round): LLM requested \(calls.count) tool(s): \(calls.map { $0.function.name })")

                // Track prompt tokens and attribute delta to previous interaction
                if let tokens = roundPromptTokens {
                    lastPromptTokens = tokens
                    if let prev = prevRoundPromptTokens, !toolInteractions.isEmpty {
                        let delta = tokens - prev
                        applyMeasuredTokenDelta(delta, to: &toolInteractions[toolInteractions.count - 1])
                    }
                    // Compute user message tokens from first-round delta
                    if measuredUserTokens == nil, let start = turnStartPromptTokens {
                        let totalDelta = tokens - start
                        let prevAssistant = turnStartCompletionTokens ?? 0
                        measuredUserTokens = max(totalDelta - prevAssistant, 0)
                    }
                    prevRoundPromptTokens = tokens
                }
                
                if cumulativeToolSpendUSD >= toolSpendLimitPerTurnUSD {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(toolSpendLimitPerTurnUSD))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = spendLimitExceededMessage(
                    todaySpentUSD: todaySpentUSD,
                    monthSpentUSD: monthSpentUSD,
                    dailyLimitUSD: toolSpendLimitDailyUSD,
                    monthlyLimitUSD: toolSpendLimitMonthlyUSD
                ) {
                    print("[ConversationManager] Daily/monthly spend limit reached during tool loop: \(exceededMessage)")
                    let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
                    let changed = await computeLedgerDiff()
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions),
                        measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                        measuredUserTokens: measuredUserTokens,
                        measuredAssistantTokens: nil,
                        measuredAssistantCompletionTokens: nil,
                        editedFilePaths: changed.edited,
                        generatedFilePaths: changed.generated,
                        subagentSessionEvents: sessionEvents
                    )
                }

                let (executableCalls, blockedResults) = partitionToolCallsForExecution(
                    calls,
                    allowedToolNames: allowedToolNames,
                    priorInteractions: toolInteractions,
                    historicalMessages: messagesForLLM
                )
                if !blockedResults.isEmpty {
                    print("[ConversationManager] Round \(round): blocked \(blockedResults.count) tool call(s) due to turn policy or tool availability")
                }
                
                // Record each tool use into the per-turn log so the user can
                // retrieve the chronology on demand via /status. We intentionally
                // do NOT push a Telegram progress message here — a single turn
                // can fire dozens of tools and spamming the user is worse than
                // letting them ask for status when they're curious.
                if !executableCalls.isEmpty {
                    let now = Date()
                    for call in executableCalls {
                        currentTurnToolLog.append((name: call.function.name, startedAt: now))
                    }
                }
                statusMessage = "Executing tools (round \(round))..."
                
                // Execute available tools only. Return explicit errors for blocked/unavailable tool calls.
                // Then reorder results to match the assistant's tool call order for deterministic follow-up prompts.
                var toolResults: [ToolResultMessage] = []
                if !executableCalls.isEmpty {
                    let executedResults = try await toolExecutor.executeParallel(executableCalls)
                    toolResults.append(contentsOf: executedResults)
                }
                if !blockedResults.isEmpty {
                    toolResults.append(contentsOf: blockedResults)
                }
                try Task.checkCancellation()
                
                var orderedToolResults: [ToolResultMessage] = []
                var remainingToolResults = toolResults
                for call in assistantMessage.toolCalls {
                    if let index = remainingToolResults.firstIndex(where: { $0.toolCallId == call.id }) {
                        orderedToolResults.append(remainingToolResults.remove(at: index))
                    }
                }
                if !remainingToolResults.isEmpty {
                    print("[ConversationManager] Round \(round): appending \(remainingToolResults.count) unmatched tool result(s) after ordered results")
                    orderedToolResults.append(contentsOf: remainingToolResults)
                }

                // Extract subagent session events from Agent tool results.
                for (idx, call) in calls.enumerated() where call.function.name == "Agent" {
                    if let result = orderedToolResults.first(where: { $0.toolCallId == call.id }),
                       let data = result.content.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sid = json["session_id"] as? String {
                        let isNew = (json["is_new_session"] as? Bool) ?? true
                        let desc = (json["final_message"] as? String).map { String($0.prefix(80)) } ?? ""
                        if let argData = call.function.arguments.data(using: .utf8),
                           let argJson = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                           let subType = argJson["subagent_type"] as? String {
                            sessionEvents.append(SubagentSessionEvent(
                                kind: isNew ? .opened : .continued,
                                sessionId: sid,
                                subagentType: subType,
                                description: (argJson["description"] as? String) ?? ""
                            ))
                        }
                    }
                }

                let toolInternalSpendUSD = toolSpendUSD(from: orderedToolResults)
                if toolInternalSpendUSD > 0 {
                    cumulativeToolSpendUSD += toolInternalSpendUSD
                    todaySpentUSD += toolInternalSpendUSD
                    monthSpentUSD += toolInternalSpendUSD
                    KeychainHelper.recordOpenRouterSpend(toolInternalSpendUSD)
                    print("[ConversationManager] Round \(round) research tool spend: +$\(formatUSD(toolInternalSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
                }
                
                print("[ConversationManager] Round \(round) tool execution complete")
                
                // Append real-time chronology to the end of each tool result
                // This lets the model know exactly how much time passed without breaking the prompt cache prefix
                let postToolTimeFormatter = DateFormatter()
                postToolTimeFormatter.dateFormat = "HH:mm:ss"
                let currentRealTime = postToolTimeFormatter.string(from: Date())
                
                for i in 0..<orderedToolResults.count {
                    let existingContent = orderedToolResults[i].content
                    orderedToolResults[i].content = existingContent + "\n\n[System Note: Current time is now \(currentRealTime)]"
                }
                
                // Add this interaction to the chain
                let interaction = ToolInteraction(
                    assistantMessage: assistantMessage,
                    results: orderedToolResults
                )
                toolInteractions.append(interaction)

                // Mid-loop: prune stored tool interactions from older turns if context is growing too large
                let midLoopDidPrune = await pruneStoredToolInteractionsMidLoop(
                    messagesForLLM: &messagesForLLM,
                    currentTurnInteractions: toolInteractions,
                    calendarContext: calendarContext,
                    emailContext: emailContext,
                    chunkSummaries: chunkSummaries
                )
                if midLoopDidPrune {
                    // Cache is already invalidated by the prune — take the opportunity
                    // to refresh stale calendar/email context with current data for free.
                    let refreshed = await getFrozenSystemContext(forceRefresh: true)
                    calendarContext = refreshed.calendar
                    emailContext = refreshed.email
                }

                if cumulativeToolSpendUSD >= toolSpendLimitPerTurnUSD {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached after tool execution ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(toolSpendLimitPerTurnUSD))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = spendLimitExceededMessage(
                    todaySpentUSD: todaySpentUSD,
                    monthSpentUSD: monthSpentUSD,
                    dailyLimitUSD: toolSpendLimitDailyUSD,
                    monthlyLimitUSD: toolSpendLimitMonthlyUSD
                ) {
                    print("[ConversationManager] Daily/monthly spend limit reached after tool execution: \(exceededMessage)")
                    let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
                    let changed = await computeLedgerDiff()
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions),
                        measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                        measuredUserTokens: measuredUserTokens,
                        measuredAssistantTokens: nil,
                        measuredAssistantCompletionTokens: nil,
                        editedFilePaths: changed.edited,
                        generatedFilePaths: changed.generated,
                        subagentSessionEvents: sessionEvents
                    )
                }
                
                statusMessage = "Processing results..."
            }
        }
        
        let didHitSafetyLimit = !didHitToolSpendLimit
        if didHitSafetyLimit {
            print("[ConversationManager] Safety tool round limit (\(maxToolRoundsSafetyLimit)) reached, forcing final response")
        }

        // Force one final call WITHOUT tools to produce a user-facing response
        let finalResponseInstruction: String
        if didHitToolSpendLimit {
            finalResponseInstruction = """
            The tool spend limit for this turn has been reached (spent approximately $\(formatUSD(cumulativeToolSpendUSD)), limit $\(formatUSD(toolSpendLimitPerTurnUSD))).
            Provide the best possible final response to the user using the information you already have. Do not call additional tools.
            """
        } else {
            finalResponseInstruction = """
            You have reached the tool-round safety limit for this turn.
            Provide the best possible final response to the user using the information you already have. Do not call additional tools.
            """
        }

        try Task.checkCancellation()
        let finalResponse = try await openRouterService.generateResponse(
            messages: messagesForLLM,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory,
            tools: nil,  // No tools to force text response
            toolResultMessages: toolInteractions,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
            totalChunkCount: totalChunkCount,
            currentUserMessageId: currentUserMessageId,
            turnStartDate: systemPromptDate,
            finalResponseInstruction: finalResponseInstruction
        )
        if let finalSpendUSD = spendUSD(from: finalResponse), finalSpendUSD > 0 {
            KeychainHelper.recordOpenRouterSpend(finalSpendUSD)
        }
        
        let finalPromptTokens: Int?
        let finalCompTokens: Int?
        switch finalResponse {
        case .text(_, let pt, let ct, _):
            finalPromptTokens = pt
            finalCompTokens = ct
        case .toolCalls(_, _, let pt, let ct, _):
            finalPromptTokens = pt
            finalCompTokens = ct
        }
        if let tokens = finalPromptTokens {
            lastPromptTokens = tokens
            if let prev = prevRoundPromptTokens, !toolInteractions.isEmpty {
                applyMeasuredTokenDelta(tokens - prev, to: &toolInteractions[toolInteractions.count - 1])
            }
            if measuredUserTokens == nil, let start = turnStartPromptTokens {
                let totalDelta = tokens - start
                let prevAssistant = turnStartCompletionTokens ?? 0
                measuredUserTokens = max(totalDelta - prevAssistant, 0)
            }
        }

        let totalMeasuredSpend = toolInteractionTokens(toolInteractions)
        let accessedProjects = extractAccessedProjects(from: toolInteractions)
        let changed = await computeLedgerDiff()

        let assistantTokens: Int? = {
            let comp = finalCompTokens ?? 0
            let tools = totalMeasuredSpend
            let total = comp + tools
            return total > 0 ? total : nil
        }()

        switch finalResponse {
        case .text(let content, _, _, _):
            return ToolAwareResponse(
                finalText: content,
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects,
                measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                measuredUserTokens: measuredUserTokens,
                measuredAssistantTokens: assistantTokens,
                measuredAssistantCompletionTokens: finalCompTokens,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: sessionEvents
            )
        case .toolCalls(_, _, _, _, _):
            return ToolAwareResponse(
                finalText: "I completed the requested actions but had trouble summarizing the results.",
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects,
                measuredToolTokens: totalMeasuredSpend > 0 ? totalMeasuredSpend : nil,
                measuredUserTokens: measuredUserTokens,
                measuredAssistantTokens: assistantTokens,
                measuredAssistantCompletionTokens: finalCompTokens,
                editedFilePaths: changed.edited,
                generatedFilePaths: changed.generated,
                subagentSessionEvents: sessionEvents
            )
        }
    }
    
    private func configuredToolSpendLimitPerTurnUSD() -> Double {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return defaultToolSpendLimitPerTurnUSD
        }
        return parsed
    }

    private func configuredDailyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func configuredMonthlyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func currentSpendLimitStatus(referenceDate: Date = Date()) -> SpendLimitStatus {
        let spendSnapshot = KeychainHelper.openRouterSpendSnapshot(referenceDate: referenceDate)
        let extraSnapshot = KeychainHelper.openRouterSpendLimitIncreaseSnapshot(referenceDate: referenceDate)
        return SpendLimitStatus(
            todaySpentUSD: spendSnapshot.today,
            monthSpentUSD: spendSnapshot.month,
            dailyBaseLimitUSD: configuredDailyToolSpendLimitUSD(),
            monthlyBaseLimitUSD: configuredMonthlyToolSpendLimitUSD(),
            dailyExtraUSD: extraSnapshot.daily,
            monthlyExtraUSD: extraSnapshot.monthly
        )
    }

    private func spendLimitExceededMessage(
        todaySpentUSD: Double,
        monthSpentUSD: Double,
        dailyLimitUSD: Double?,
        monthlyLimitUSD: Double?
    ) -> String? {
        let dailyExceeded = dailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        let monthlyExceeded = monthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        guard dailyExceeded || monthlyExceeded else { return nil }

        if dailyExceeded, monthlyExceeded, let dailyLimitUSD, let monthlyLimitUSD {
            return "I paused tool usage because both spend limits were reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD)); this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise the limits in Settings > OpenRouter."
        }
        if dailyExceeded, let dailyLimitUSD {
            return "I paused tool usage because the daily spend limit was reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise it in Settings > OpenRouter."
        }
        if monthlyExceeded, let monthlyLimitUSD {
            return "I paused tool usage because the monthly spend limit was reached (this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise it in Settings > OpenRouter."
        }
        return nil
    }
    
    private func spendUSD(from response: LLMResponse) -> Double? {
        switch response {
        case .text(_, _, _, let spendUSD):
            return spendUSD
        case .toolCalls(_, _, _, _, let spendUSD):
            return spendUSD
        }
    }

    private func toolSpendUSD(from results: [ToolResultMessage]) -> Double {
        results
            .compactMap(\.spendUSD)
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0, +)
    }

    // MARK: - Context Budget & Tool Interaction Pruning

    /// Max context tokens exposed for the UI context gauge.
    var maxContextTokens: Int { configuredMaxContextTokens() }

    private func configuredMaxContextTokens() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.maxContextTokensKey),
           let value = Int(raw), value >= 10000 {
            return value
        }
        return defaultMaxContextTokens
    }

    private func configuredTargetContextTokens() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.targetContextTokensKey),
           let value = Int(raw), value >= 5000 {
            return value
        }
        return defaultTargetContextTokens
    }

    private func normalizedMimeType(_ mimeType: String) -> String {
        mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()
    }

    private func isVoiceMessage(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["ogg", "oga"].contains(ext)
    }

    private func isInlineMimeTypeSupportedForBudget(_ mimeType: String) -> Bool {
        let normalized = normalizedMimeType(mimeType)
        if normalized.hasPrefix("image/") { return true }
        return [
            "application/pdf",
            "text/plain",
            "text/markdown",
            "application/json",
            "text/csv",
            "text/html",
            "application/xml"
        ].contains(normalized)
    }

    private func fileSize(at url: URL, fallback: Int? = nil) -> Int {
        if let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return value
        }
        return fallback ?? 0
    }

    private func mimeTypeForPrimaryImage(_ fileName: String) -> String {
        fileName.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
    }

    private func mimeTypeForDocument(_ fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    private func estimatedImageTokens(data: Data?, url: URL?, fallbackBytes: Int) -> Int {
        let image: NSImage? = {
            if let data { return NSImage(data: data) }
            if let url { return NSImage(contentsOf: url) }
            return nil
        }()
        if let image {
            let pixelWidth = image.representations.map(\.pixelsWide).filter { $0 > 0 }.max()
                ?? max(Int(image.size.width), 1)
            let pixelHeight = image.representations.map(\.pixelsHigh).filter { $0 > 0 }.max()
                ?? max(Int(image.size.height), 1)
            let tiles = max(1, Int(ceil(Double(pixelWidth) / 512.0)) * Int(ceil(Double(pixelHeight) / 512.0)))
            return max(300, min(12_000, 85 + tiles * 170))
        }
        return max(300, min(8_000, fallbackBytes / 1024 + 300))
    }

    private func estimatedPDFTokens(data: Data?, url: URL?, fallbackBytes: Int, isLMStudio: Bool? = nil) -> Int {
        let document: PDFDocument? = {
            if let data { return PDFDocument(data: data) }
            if let url { return PDFDocument(url: url) }
            return nil
        }()
        let pageCount = max(document?.pageCount ?? max(1, fallbackBytes / 100_000), 1)
        if isLMStudio ?? currentProviderIsLMStudio() {
            return min(80_000, pageCount * 1_000)
        }
        let byteBased = max(300, fallbackBytes / 4)
        return min(80_000, max(pageCount * 300, min(byteBased, pageCount * 1_800)))
    }

    private func estimatedImageTokens(width: Int, height: Int) -> Int {
        let tiles = max(1, Int(ceil(Double(width) / 512.0)) * Int(ceil(Double(height) / 512.0)))
        return max(300, min(12_000, 85 + tiles * 170))
    }

    private func estimatedPDFTokens(pageCount: Int, byteSize: Int, isLMStudio: Bool) -> Int {
        let pages = max(pageCount, 1)
        if isLMStudio {
            return min(80_000, pages * 1_000)
        }
        let byteBased = max(300, byteSize / 4)
        return min(80_000, max(pages * 300, min(byteBased, pages * 1_800)))
    }

    private func estimatedInlineFileTokens(filename: String, data: Data? = nil, url: URL? = nil, mimeType: String, fallbackBytes: Int = 0, isLMStudio: Bool? = nil) -> Int {
        guard isInlineMimeTypeSupportedForBudget(mimeType) else {
            return estimatedMediaHintTokens(filename: filename)
        }

        let normalized = normalizedMimeType(mimeType)
        let bytes = data?.count ?? fileSize(at: url ?? URL(fileURLWithPath: filename), fallback: fallbackBytes)
        if normalized.hasPrefix("image/") {
            return estimatedImageTokens(data: data, url: url, fallbackBytes: bytes)
        }
        if normalized == "application/pdf" {
            return estimatedPDFTokens(data: data, url: url, fallbackBytes: bytes, isLMStudio: isLMStudio)
        }
        return max(20, min(80_000, bytes / 4 + 20))
    }

    private func estimatedInlineFileTokens(reference: FileAttachmentReference, isLMStudio: Bool) -> Int {
        guard isInlineMimeTypeSupportedForBudget(reference.mimeType) else {
            return estimatedMediaHintTokens(filename: reference.filename)
        }

        let normalized = normalizedMimeType(reference.mimeType)
        let bytes = reference.byteSize ?? 0
        if normalized.hasPrefix("image/"),
           let width = reference.imageWidth,
           let height = reference.imageHeight {
            return estimatedImageTokens(width: width, height: height)
        }
        if normalized == "application/pdf", let pageCount = reference.pdfPageCount {
            return estimatedPDFTokens(pageCount: pageCount, byteSize: bytes, isLMStudio: isLMStudio)
        }

        if bytes > 0 {
            if normalized.hasPrefix("image/") {
                return max(300, min(8_000, bytes / 1024 + 300))
            }
            return max(20, min(80_000, bytes / 4 + 20))
        }

        let url = reference.resolvedURL(imagesDirectory: imagesDirectory, documentsDirectory: documentsDirectory)
        return estimatedInlineFileTokens(filename: reference.filename, url: url, mimeType: reference.mimeType, isLMStudio: isLMStudio)
    }

    private func currentProviderIsLMStudio() -> Bool {
        LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) == .lmStudio
    }

    private func estimatedMediaHintTokens(filename: String) -> Int {
        isVoiceMessage(filename) ? 10 : 50
    }

    private func estimatedMediaTokensForMessage(_ message: Message, inline: Bool, isLMStudio: Bool? = nil) -> Int {
        var tokens = 0

        for fileName in message.referencedImageFileNames {
            let url = imagesDirectory.appendingPathComponent(fileName)
            tokens += inline
                ? estimatedInlineFileTokens(filename: fileName, url: url, mimeType: mimeTypeForPrimaryImage(fileName), isLMStudio: isLMStudio)
                : estimatedMediaHintTokens(filename: fileName)
        }
        for fileName in message.referencedDocumentFileNames {
            let url = documentsDirectory.appendingPathComponent(fileName)
            let mime = mimeTypeForDocument(fileName)
            tokens += inline
                ? estimatedInlineFileTokens(filename: fileName, url: url, mimeType: mime, isLMStudio: isLMStudio)
                : estimatedMediaHintTokens(filename: fileName)
        }
        for (index, fileName) in message.imageFileNames.enumerated() {
            let url = imagesDirectory.appendingPathComponent(fileName)
            let fallback = index < message.imageFileSizes.count ? message.imageFileSizes[index] : 0
            tokens += inline
                ? estimatedInlineFileTokens(filename: fileName, url: url, mimeType: mimeTypeForPrimaryImage(fileName), fallbackBytes: fallback, isLMStudio: isLMStudio)
                : estimatedMediaHintTokens(filename: fileName)
        }
        for (index, fileName) in message.documentFileNames.enumerated() {
            let url = documentsDirectory.appendingPathComponent(fileName)
            let fallback = index < message.documentFileSizes.count ? message.documentFileSizes[index] : 0
            let mime = mimeTypeForDocument(fileName)
            tokens += inline
                ? estimatedInlineFileTokens(filename: fileName, url: url, mimeType: mime, fallbackBytes: fallback, isLMStudio: isLMStudio)
                : estimatedMediaHintTokens(filename: fileName)
        }

        return tokens
    }

    private func estimatedPromptTokens(for message: Message, isLMStudio: Bool? = nil) -> Int {
        var tokens = max(message.content.count / 4 + 1, 1)
        if message.hasUnprunedMedia || message.mediaFileCount > 0 {
            tokens += estimatedMediaTokensForMessage(message, inline: !message.mediaPruned, isLMStudio: isLMStudio)
        }
        return tokens
    }

    private func estimatedStoredToolInteractionTokens(_ interaction: ToolInteraction) -> Int {
        var tokens = (interaction.assistantMessage.content?.count ?? 0) / 4
        for call in interaction.assistantMessage.toolCalls {
            tokens += call.function.arguments.count / 4
            tokens += call.function.name.count / 4 + 20
        }
        for result in interaction.results {
            tokens += result.content.count / 4 + 20
        }
        return max(tokens, 1)
    }

    private func estimatedPersistedAttachmentTokens(_ interaction: ToolInteraction, isLMStudio: Bool) -> Int {
        interaction.results.reduce(0) { total, result in
            total + result.fileAttachmentReferences.reduce(0) { subtotal, reference in
                subtotal + estimatedInlineFileTokens(reference: reference, isLMStudio: isLMStudio)
            }
        }
    }

    private func currentTurnInteractionTokens(_ interaction: ToolInteraction, isLMStudio: Bool) -> Int {
        if let measured = interaction.measuredTokenCost, measured > 0 {
            return measured
        }
        return estimatedStoredToolInteractionTokens(interaction) + estimatedPersistedAttachmentTokens(interaction, isLMStudio: isLMStudio)
    }

    private func applyMeasuredTokenDelta(_ delta: Int, to interaction: inout ToolInteraction) {
        let measured = max(delta, 0)
        interaction.measuredTokenCost = measured

        // Tool attachments are persisted by reference and replayed until
        // pruning, so the measured current-turn delta is also the replay cost.
        interaction.measuredReplayTokenCost = measured
    }

    private func estimatedTokensAddedSinceLastPrompt(currentUserMessageId: UUID?, isLMStudio: Bool) -> Int {
        var tokens = lastCompletionTokens ?? 0
        if let currentUserMessageId,
           let currentUser = messages.first(where: { $0.id == currentUserMessageId }) {
            tokens += estimatedPromptTokens(for: currentUser, isLMStudio: isLMStudio)
        }
        return tokens
    }

    /// Token cost for persisted tool interactions. Uses replay-only measured
    /// cost when available, falling back to the older measured delta and then
    /// to character-based estimation.
    private func toolInteractionTokens(_ interactions: [ToolInteraction], isLMStudio: Bool? = nil) -> Int {
        let providerIsLMStudio = isLMStudio ?? currentProviderIsLMStudio()
        var tokens = 0
        for interaction in interactions {
            if let measured = interaction.measuredReplayTokenCost, measured > 0 {
                tokens += measured
            } else if let measured = interaction.measuredTokenCost, measured > 0 {
                tokens += measured
            } else {
                tokens += estimatedStoredToolInteractionTokens(interaction)
                tokens += estimatedPersistedAttachmentTokens(interaction, isLMStudio: providerIsLMStudio)
            }
        }
        return tokens
    }

    /// Token cost for a message's tool interactions. Prefers the per-message
    /// measured total (sum of all round deltas), falls back to per-interaction.
    private func toolTokensForMessage(_ message: Message, isLMStudio: Bool? = nil) -> Int {
        if let measured = message.measuredToolTokens, measured > 0 {
            return measured
        }
        return toolInteractionTokens(message.toolInteractions, isLMStudio: isLMStudio)
    }

    /// Estimated token savings from pruning a message's inline media to text hints.
    /// Uses measured total tokens when available to derive actual media cost;
    /// falls back to 1450 tokens/file estimate.
    private func mediaSavingsForMessage(_ message: Message, isLMStudio: Bool? = nil) -> Int {
        if let measured = message.measuredTokens {
            let textTokens = message.content.count / 4 + 1
            let toolTokens = message.measuredToolTokens ?? toolInteractionTokens(message.toolInteractions, isLMStudio: isLMStudio)
            let mediaCost = max(measured - textTokens - toolTokens, 0)
            let hintCost = estimatedMediaTokensForMessage(message, inline: false, isLMStudio: isLMStudio)
            return max(mediaCost - hintCost, 0)
        }
        let inlineCost = estimatedMediaTokensForMessage(message, inline: true, isLMStudio: isLMStudio)
        let hintCost = estimatedMediaTokensForMessage(message, inline: false, isLMStudio: isLMStudio)
        return max(inlineCost - hintCost, 0)
    }

    /// Estimate system prompt size from its components
    private func estimateSystemPromptTokens(
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) -> Int {
        var chars = 3000 // Fixed instruction overhead
        let persona = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        chars += persona.count
        if let cal = calendarContext { chars += cal.count }
        if let email = emailContext { chars += email.count }
        for summary in chunkSummaries {
            chars += summary.summary.count + 100
        }
        return chars / 4
    }

    /// Index of the most recent assistant message with tool interactions (protected from pruning).
    private func lastAssistantIndexWithTools(in msgs: [Message]) -> Int? {
        msgs.indices.last { msgs[$0].role == .assistant && !msgs[$0].toolInteractions.isEmpty }
    }

    /// Prune stored tool interactions from oldest turns to stay under context budget.
    /// The most recent turn with tools is always protected.
    /// Returns true if any pruning occurred (cache was broken).
    private func pruneToolInteractionsIfNeeded(
        currentUserMessageId: UUID?,
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) async -> Bool {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messages)
        let providerIsLMStudio = currentProviderIsLMStudio()

        // Use real prompt_tokens from API when available, fall back to estimation
        var totalTokens: Int
        if let real = lastPromptTokens {
            let addedSinceLastPrompt = estimatedTokensAddedSinceLastPrompt(currentUserMessageId: currentUserMessageId, isLMStudio: providerIsLMStudio)
            totalTokens = real + addedSinceLastPrompt
            print("[ConversationManager] Using real prompt_tokens: \(real) + ~\(addedSinceLastPrompt) new tokens")
        } else {
            totalTokens = estimateSystemPromptTokens(
                calendarContext: calendarContext,
                emailContext: emailContext,
                chunkSummaries: chunkSummaries
            )
            for message in messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            print("[ConversationManager] Using estimated tokens: \(totalTokens)")
        }

        // Calculate prunable savings — use measured data when available
        var prunableToolTokens = 0
        var prunableMediaTokens = 0
        for (i, message) in messages.enumerated() {
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += toolTokensForMessage(message, isLMStudio: providerIsLMStudio)
            }
            if i != protectedIndex && message.hasUnprunedMedia {
                prunableMediaTokens += mediaSavingsForMessage(message, isLMStudio: providerIsLMStudio)
            }
        }

        guard totalTokens > maxTokens else {
            print("[ConversationManager] Context budget OK: ~\(totalTokens) tokens <= \(maxTokens)")
            return false
        }

        // Skip if nothing is prunable
        guard prunableToolTokens > 0 || prunableMediaTokens > 0 else {
            print("[ConversationManager] Context budget exceeded (~\(totalTokens) > \(maxTokens)) but nothing prunable — skipping")
            return false
        }

        print("[ConversationManager] Context budget exceeded: ~\(totalTokens) tokens > \(maxTokens). Pruning to ~\(targetTokens)...")

        // Single chronological pass: prune oldest content first (tools + media),
        // regardless of type, so a turn-2 file is pruned before turn-5 tools.
        var prunedToolCount = 0
        var prunedMediaCount = 0
        for i in 0..<messages.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }

            // Prune tool interactions on this message
            if messages[i].role == .assistant && !messages[i].toolInteractions.isEmpty {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: false,
                    includeToolAttachments: true,
                    sourceMessages: messages
                )
                let savedTokens = toolTokensForMessage(messages[i], isLMStudio: providerIsLMStudio)
                messages[i].toolInteractions = []
                messages[i].measuredToolTokens = nil
                if let m = messages[i].measuredTokens { messages[i].measuredTokens = max(m - savedTokens, 0) }
                totalTokens -= savedTokens
                prunedToolCount += 1
            }

            guard totalTokens > targetTokens else { break }

            // Prune inline media on this message
            if messages[i].hasUnprunedMedia {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: true,
                    includeToolAttachments: false,
                    sourceMessages: messages
                )
                let savedTokens = mediaSavingsForMessage(messages[i], isLMStudio: providerIsLMStudio)
                messages[i].mediaPruned = true
                if let m = messages[i].measuredTokens { messages[i].measuredTokens = max(m - savedTokens, 0) }
                totalTokens -= savedTokens
                prunedMediaCount += 1
            }
        }

        // Parallel pass: collapse stale synthetic user messages (emails, subagent
        // completions, reminders) into one-line metadata stubs. This is the same
        // cache-invalidation event as the tool-interaction collapse, so piggy-backing
        // avoids extra cache misses. `.userText` and `.bashComplete` are skipped.
        let compressedCount = pruneCompressibleUserMessages(upToIndex: messages.count)

        if prunedToolCount > 0 {
            pruneOldCompactToolLogs()
        }
        let anyPruned = prunedToolCount > 0 || prunedMediaCount > 0 || compressedCount > 0
        if anyPruned {
            saveConversation()
            cleanupOrphanedToolAttachmentSnapshots()
            print("[ConversationManager] Pruned tools from \(prunedToolCount) turn(s), media from \(prunedMediaCount) message(s), compressed \(compressedCount) synthetic message(s). New estimate: ~\(totalTokens) tokens")
        }

        return anyPruned
    }

    /// Mid-loop variant: prunes stored tool interactions from historical turns when the
    /// current turn's growing context would exceed the budget. Only touches historical
    /// messages (messagesForLLM), never the current turn's in-memory toolInteractions.
    /// The most recent historical turn with tools is always protected.
    private func pruneStoredToolInteractionsMidLoop(
        messagesForLLM: inout [Message],
        currentTurnInteractions: [ToolInteraction],
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) async -> Bool {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messagesForLLM)
        let providerIsLMStudio = currentProviderIsLMStudio()

        // Use real prompt_tokens when available, fall back to estimation
        var totalTokens: Int
        if let real = lastPromptTokens {
            let unsentInteractionTokens = currentTurnInteractions.last.map { currentTurnInteractionTokens($0, isLMStudio: providerIsLMStudio) } ?? 0
            totalTokens = real + unsentInteractionTokens
        } else {
            totalTokens = estimateSystemPromptTokens(
                calendarContext: calendarContext,
                emailContext: emailContext,
                chunkSummaries: chunkSummaries
            )
            for message in messagesForLLM {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            totalTokens += currentTurnInteractions.reduce(0) { $0 + currentTurnInteractionTokens($1, isLMStudio: providerIsLMStudio) }
        }
        var prunableToolTokens = 0
        var prunableMediaTokens = 0
        for (i, message) in messagesForLLM.enumerated() {
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += toolTokensForMessage(message, isLMStudio: providerIsLMStudio)
            }
            if i != protectedIndex && message.hasUnprunedMedia {
                prunableMediaTokens += mediaSavingsForMessage(message, isLMStudio: providerIsLMStudio)
            }
        }

        guard totalTokens > maxTokens, (prunableToolTokens > 0 || prunableMediaTokens > 0) else { return false }

        print("[ConversationManager] Mid-loop context exceeded: ~\(totalTokens) > \(maxTokens). Pruning...")

        // Single chronological pass: prune oldest content first (tools + media)
        var prunedToolCount = 0
        var prunedMediaCount = 0
        for i in 0..<messagesForLLM.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }

            if messagesForLLM[i].role == .assistant && !messagesForLLM[i].toolInteractions.isEmpty {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: false,
                    includeToolAttachments: true,
                    sourceMessages: messagesForLLM
                )
                let savedTokens = toolTokensForMessage(messagesForLLM[i], isLMStudio: providerIsLMStudio)
                messagesForLLM[i].toolInteractions = []
                messagesForLLM[i].measuredToolTokens = nil
                if let m = messagesForLLM[i].measuredTokens { messagesForLLM[i].measuredTokens = max(m - savedTokens, 0) }
                totalTokens -= savedTokens
                prunedToolCount += 1
            }

            guard totalTokens > targetTokens else { break }

            if messagesForLLM[i].hasUnprunedMedia {
                await generateDescriptionsBeforePruning(
                    messageIndex: i,
                    includeInlineMedia: true,
                    includeToolAttachments: false,
                    sourceMessages: messagesForLLM
                )
                let savedTokens = mediaSavingsForMessage(messagesForLLM[i], isLMStudio: providerIsLMStudio)
                messagesForLLM[i].mediaPruned = true
                if let m = messagesForLLM[i].measuredTokens { messagesForLLM[i].measuredTokens = max(m - savedTokens, 0) }
                totalTokens -= savedTokens
                prunedMediaCount += 1
            }
        }

        if prunedToolCount > 0 {
            // Persist to self.messages (indices correspond since no mutations during the loop)
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id
                    && messagesForLLM[i].toolInteractions.isEmpty
                    && !messages[i].toolInteractions.isEmpty {
                    messages[i].toolInteractions = []
                    messages[i].measuredToolTokens = nil
                    messages[i].measuredTokens = messagesForLLM[i].measuredTokens
                }
            }
            pruneOldCompactToolLogs()
            // Also sync log pruning to messagesForLLM
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id {
                    messagesForLLM[i].compactToolLog = messages[i].compactToolLog
                }
            }
        }

        // Persist media pruning to self.messages
        if prunedMediaCount > 0 {
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id
                    && messagesForLLM[i].mediaPruned
                    && !messages[i].mediaPruned {
                    messages[i].mediaPruned = true
                    messages[i].measuredTokens = messagesForLLM[i].measuredTokens
                }
            }
        }

        // Parallel pass on the compressible synthetic user messages. Runs in the
        // same cache-invalidation event as the tool-interaction collapse.
        let compressedCount = pruneCompressibleUserMessages(upToIndex: messages.count)
        if compressedCount > 0 {
            // Mirror the compressed content into the in-flight messagesForLLM slice so
            // the current turn sees the stubbed form too.
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id {
                    messagesForLLM[i] = messages[i]
                }
            }
        }

        let anyPruned = prunedToolCount > 0 || prunedMediaCount > 0 || compressedCount > 0
        if anyPruned {
            saveConversation()
            cleanupOrphanedToolAttachmentSnapshots(additionalLiveInteractions: currentTurnInteractions)
            print("[ConversationManager] Mid-loop pruned tools from \(prunedToolCount) turn(s), media from \(prunedMediaCount) message(s), compressed \(compressedCount) synthetic message(s). New estimate: ~\(totalTokens) tokens")
        }

        return anyPruned
    }

    /// Deletes snapshotted tool-output bytes that are no longer referenced by the
    /// active conversation. This never follows `sourcePath` and never removes
    /// anything outside LocalAgent's managed `tool_attachments` cache directory.
    private func cleanupOrphanedToolAttachmentSnapshots(additionalLiveInteractions: [ToolInteraction] = []) {
        let fm = FileManager.default
        let dir = toolAttachmentsDirectory
        guard let snapshotFiles = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let liveSnapshotPaths = liveToolAttachmentSnapshotPaths(additionalLiveInteractions: additionalLiveInteractions)
        var removedCount = 0

        for url in snapshotFiles {
            guard isManagedToolAttachmentSnapshot(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            let path = url.standardizedFileURL.path
            guard !liveSnapshotPaths.contains(path) else { continue }

            do {
                try fm.removeItem(at: url)
                removedCount += 1
            } catch {
                print("[ConversationManager] Failed to remove orphaned tool attachment snapshot \(url.path): \(error)")
            }
        }

        if removedCount > 0 {
            print("[ConversationManager] Removed \(removedCount) orphaned tool attachment snapshot(s)")
        }
    }

    private func liveToolAttachmentSnapshotPaths(additionalLiveInteractions: [ToolInteraction] = []) -> Set<String> {
        var paths = Set<String>()

        for message in messages {
            for interaction in message.toolInteractions {
                collectLiveSnapshotPaths(from: interaction, into: &paths)
            }
        }

        for interaction in additionalLiveInteractions {
            collectLiveSnapshotPaths(from: interaction, into: &paths)
        }

        return paths
    }

    private func collectLiveSnapshotPaths(from interaction: ToolInteraction, into paths: inout Set<String>) {
        for result in interaction.results {
            for reference in result.fileAttachmentReferences {
                guard let snapshotPath = reference.snapshotPath else { continue }
                let url = URL(fileURLWithPath: snapshotPath)
                guard isManagedToolAttachmentSnapshot(url) else { continue }
                paths.insert(url.standardizedFileURL.path)
            }
        }
    }

    private func isManagedToolAttachmentSnapshot(_ url: URL) -> Bool {
        let directoryPath = toolAttachmentsDirectory.standardizedFileURL.path
        let snapshotPath = url.standardizedFileURL.path
        return snapshotPath.hasPrefix(directoryPath + "/")
    }

    // MARK: - Compressible synthetic-user-message pruning

    /// Stable-history cutoff for compression. We don't touch the tail of the
    /// conversation — compressing a message the model just reacted to is wasted
    /// risk, and keeping a tail uncompressed matches the spirit of the "Low
    /// Watermark" (hot region stays fully inflated).
    private static let compressibleSyntheticTailProtection = 4

    /// The set of message kinds that the Watermark pruner is allowed to collapse
    /// into a one-line stub. Hard constraint: `.userText` and `.bashComplete`
    /// are deliberately NOT in this set.
    private static let compressibleSyntheticKinds: Set<MessageKind> = [
        .emailArrived, .subagentComplete, .reminderFired
    ]

    /// Replace the `content` of stale synthetic user messages (emails, subagent
    /// completions, reminders) with a one-line metadata stub. Called from inside
    /// the Watermark pruners so it piggy-backs on the same cache-invalidation
    /// event as the tool-interaction collapse.
    ///
    /// - `upToIndex` is exclusive — messages at indices `[0, upToIndex - tailProtection)`
    ///   are considered stable history. The last few messages stay fully inflated.
    /// - Already-compressed messages are skipped via the `[... archived]` prefix check.
    /// - Only touches indices into `self.messages`; callers that also hold an
    ///   `inout [Message]` mirror should sync afterwards.
    ///
    /// Returns the number of messages actually rewritten.
    @discardableResult
    private func pruneCompressibleUserMessages(upToIndex: Int) -> Int {
        let tail = Self.compressibleSyntheticTailProtection
        let end = min(upToIndex, messages.count)
        let stableEnd = max(0, end - tail)
        guard stableEnd > 0 else { return 0 }

        var count = 0
        for i in 0..<stableEnd {
            let msg = messages[i]
            guard msg.role == .user else { continue }
            guard Self.compressibleSyntheticKinds.contains(msg.kind) else { continue }
            // Safety: never compress twice. Cheap prefix check matches the stub format.
            if msg.content.hasPrefix("[Email archived]")
                || msg.content.hasPrefix("[Subagent archived]")
                || msg.content.hasPrefix("[Reminder archived]") {
                continue
            }

            let stub: String
            switch msg.kind {
            case .emailArrived:     stub = Self.compactEmailStub(from: msg.content)
            case .subagentComplete: stub = Self.compactSubagentStub(from: msg.content)
            case .reminderFired:    stub = Self.compactReminderStub(from: msg.content)
            case .userText, .bashComplete:
                continue // defensive — filtered above
            }

            messages[i].content = stub
            count += 1
        }
        return count
    }

    // MARK: Stub builders (inline parsers for the three compressible kinds)

    /// Extract `from:`/`subject:` headers from the original email-arrival body and
    /// build a one-line stub. Falls back to a generic message if parsing fails.
    private static func compactEmailStub(from body: String) -> String {
        let (from, subject, snippet) = parseEmailHeaders(body)
        if from == nil && subject == nil {
            return "[Email archived] (compressed; body no longer in context)"
        }
        var parts = ["[Email archived]"]
        if let from = from { parts.append("from: \(from)") }
        if let subject = subject { parts.append("subject: \(subject)") }
        if let snippet = snippet, !snippet.isEmpty {
            parts.append("snippet: \(snippet)")
        }
        return parts.joined(separator: ", ")
            .replacingOccurrences(of: "[Email archived],", with: "[Email archived]")
    }

    /// Parse the first `From:`/`Subject:` pair (and body snippet) from a
    /// `[SYSTEM: NEW EMAILS ARRIVED]` block. Headers are case-insensitive and
    /// may appear after a `---` separator line.
    private static func parseEmailHeaders(_ body: String) -> (from: String?, subject: String?, snippet: String?) {
        var from: String?
        var subject: String?
        var snippet: String?
        var sawBody = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if from == nil, lower.hasPrefix("from:") {
                from = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if subject == nil, lower.hasPrefix("subject:") {
                subject = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if snippet == nil, lower.hasPrefix("body:") {
                sawBody = true
                let rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { snippet = String(rest.prefix(80)) }
            } else if sawBody, snippet == nil, !trimmed.isEmpty {
                snippet = String(trimmed.prefix(80))
            }
            if from != nil && subject != nil && snippet != nil { break }
        }
        return (from, subject, snippet)
    }

    /// Parse the `[SUBAGENT COMPLETE]` block up to the `final_message:` line and
    /// emit a one-line stub. The final_message body is discarded.
    private static func compactSubagentStub(from body: String) -> String {
        var handle: String?
        var subagentType: String?
        var description: String?
        var turns: String?
        var spend: String?
        var filesTouched: String?

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("final_message") { break }
            if let value = Self.keyValue(line, key: "handle") { handle = value }
            else if let value = Self.keyValue(line, key: "subagent_type") { subagentType = value }
            else if let value = Self.keyValue(line, key: "description") { description = value }
            else if let value = Self.keyValue(line, key: "turns_used") { turns = value }
            else if let value = Self.keyValue(line, key: "spend_usd") { spend = value }
            else if let value = Self.keyValue(line, key: "files_touched") { filesTouched = value }
        }

        var parts = ["[Subagent archived]"]
        if let handle = handle { parts.append("handle: \(handle)") }
        if let subagentType = subagentType { parts.append("type: \(subagentType)") }
        if let description = description { parts.append("description: \(description)") }
        if let turns = turns { parts.append("turns: \(turns)") }
        if let spend = spend { parts.append("spend_usd: \(spend)") }
        if let filesTouched = filesTouched {
            // `(none)` → 0; otherwise count comma-separated entries.
            let count: Int
            if filesTouched == "(none)" {
                count = 0
            } else {
                count = filesTouched.split(separator: ",").count
            }
            parts.append("files_touched: \(count)")
        }
        if parts.count == 1 {
            // Fallback when parsing yields nothing useful.
            return "[Subagent archived] (compressed; details no longer in context)"
        }
        return parts.joined(separator: ", ")
            .replacingOccurrences(of: "[Subagent archived],", with: "[Subagent archived]")
    }

    /// Emit a one-line stub for a `reminderFired` message. The original body is a
    /// framed `[SCHEDULED REMINDER ...]` block; pull out the inner prompt and
    /// truncate it to 80 chars.
    private static func compactReminderStub(from body: String) -> String {
        // Strip the leading/trailing frame lines if present, then truncate.
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = lines.filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("[SCHEDULED REMINDER")
                && !t.hasPrefix("[END OF REMINDER")
                && !t.isEmpty
        }
        let inner = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let snippet = String(inner.prefix(80))
        if snippet.isEmpty {
            return "[Reminder archived] (compressed; prompt no longer in context)"
        }
        return "[Reminder archived] \(snippet)"
    }

    /// Parse a `key: value` line case-sensitively. Returns nil if the line does
    /// not match the requested key.
    private static func keyValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Keep at most 5 active compact tool logs (messages where interactions were pruned but log remains).
    /// Clears the oldest logs beyond the limit.
    private func pruneOldCompactToolLogs() {
        let maxRetainedCompactLogs = 5
        let activeLogIndices = messages.indices.filter {
            messages[$0].compactToolLog != nil && messages[$0].toolInteractions.isEmpty
        }
        let excessCount = activeLogIndices.count - maxRetainedCompactLogs
        guard excessCount > 0 else { return }

        for i in activeLogIndices.prefix(excessCount) {
            messages[i].compactToolLog = nil
        }
        print("[ConversationManager] Cleared \(excessCount) old compact tool log(s), keeping \(maxRetainedCompactLogs)")
    }

    // MARK: - System Prompt Cache Epoch

    /// Returns a frozen timestamp for the system prompt. Only refreshes on prune events
    /// or when the date changes (to keep "today" accurate).
    private func currentSystemPromptTimestamp() -> Date {
        if let stored = UserDefaults.standard.object(forKey: systemPromptTimestampKey) as? Date {
            if Calendar.current.isDateInToday(stored) {
                return stored
            }
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: systemPromptTimestampKey)
        return now
    }

    /// Force-refresh the system prompt timestamp (called when cache is already broken by pruning)
    private func refreshSystemPromptTimestamp() {
        UserDefaults.standard.set(Date(), forKey: systemPromptTimestampKey)
    }

    /// Returns frozen calendar + email context for the system prompt. Fetches fresh
    /// values only when (a) the session-level cache is empty (first turn), (b) the
    /// caller forces a refresh (prune events, where the prompt cache is broken
    /// anyway), or (c) the local day has rolled over (so TODAY/TOMORROW calendar
    /// labels stay accurate). Between those events the cached strings are returned
    /// byte-identical — new emails surface via ambient poller messages instead of
    /// drifting the system prompt prefix.
    private func getFrozenSystemContext(forceRefresh: Bool = false) async -> (calendar: String, email: String) {
        let today = Calendar.current.startOfDay(for: Date())
        let dayRolled = (frozenContextDay != today)
        let needsFetch = forceRefresh || dayRolled || frozenCalendarContext == nil || frozenEmailContext == nil

        if needsFetch {
            // Source both blocks from the single gws-backed service. The service
            // itself retries + returns "" on persistent failure so the system
            // prompt simply skips the block instead of erroring the turn.
            async let cal = GoogleWorkspaceService.shared.getCalendarContextForSystemPrompt(forceRefresh: forceRefresh || dayRolled)
            async let eml = GoogleWorkspaceService.shared.getEmailContextForSystemPrompt()
            let freshCal = await cal
            let freshEml = await eml
            frozenCalendarContext = freshCal
            frozenEmailContext = freshEml
            frozenContextDay = today
            let reason = forceRefresh ? "prune" : (dayRolled ? "day-rollover" : "session-start")
            print("[ConversationManager] Refreshed frozen calendar+email context (reason: \(reason))")
        }
        return (frozenCalendarContext ?? "", frozenEmailContext ?? "")
    }

    private func formatUSD(_ value: Double) -> String {
        var formatted = String(format: "%.6f", value)
        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }
    
    private func extractAccessedProjects(from interactions: [ToolInteraction]) -> [String] {
        // Legacy project-tools removed in Phase 2; nothing to extract.
        return []
    }


    private func blockedToolResult(for call: ToolCall) -> ToolResultMessage {
        blockedToolResult(for: call, errorMessage: "Tool '\(call.function.name)' is not available in this turn.")
    }

    private func blockedToolResult(for call: ToolCall, errorMessage: String) -> ToolResultMessage {
        let escapedError = errorMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ToolResultMessage(toolCallId: call.id, content: #"{"error":"\#(escapedError)"}"#)
    }

    private func partitionToolCallsForExecution(
        _ calls: [ToolCall],
        allowedToolNames: Set<String>,
        priorInteractions: [ToolInteraction],
        historicalMessages: [Message] = []
    ) -> (executableCalls: [ToolCall], blockedResults: [ToolResultMessage]) {
        var executableCalls: [ToolCall] = []
        var blockedResults: [ToolResultMessage] = []

        for call in calls {
            if allowedToolNames.contains(call.function.name) {
                executableCalls.append(call)
            } else {
                blockedResults.append(blockedToolResult(for: call))
            }
        }

        return (executableCalls, blockedResults)
    }


    /// Get appropriate progress message for tool calls
    private func getProgressMessage(for calls: [ToolCall]) -> String {
        let toolNames = Set(calls.map { $0.function.name })

        // Research / search — highest priority since these are long-running.
        if toolNames.contains("web_research_sweep") {
            return "🧠🔍 Sweeping the web..."
        }
        if toolNames.contains("web_search") {
            return "🔍 Searching the web..."
        }
        if toolNames.contains("web_fetch") {
            return "🌐 Fetching web content..."
        }

        // Subagent delegation.
        if toolNames.contains("Agent") {
            return "🤖 Running subagent..."
        }
        if toolNames.contains("subagent_manage") {
            return "🤖 Managing subagents..."
        }

        // Image generation.
        if toolNames.contains("generate_image") {
            return "🎨 Generating image..."
        }

        // Reminders / calendar (now via gws CLI, but reminders tool still exists).
        if toolNames.contains("manage_reminders") {
            return "⏰ Managing reminders..."
        }

        // Filesystem writes.
        if toolNames.contains("write_file")
            || toolNames.contains("edit_file")
            || toolNames.contains("apply_patch") {
            return "✏️ Editing files..."
        }

        // Filesystem reads / discovery.
        if toolNames.contains("read_file")
            || toolNames.contains("grep")
            || toolNames.contains("glob")
            || toolNames.contains("list_dir")
            || toolNames.contains("list_recent_files") {
            return "🔎 Reading files..."
        }

        // LSP semantic queries.
        if toolNames.contains("lsp") {
            return "🔬 Analyzing code..."
        }

        // Bash (catch-all for shell). Check AFTER more specific patterns so
        // "bash gws gmail" etc. falls here only if no other match applied.
        if toolNames.contains("bash")
            || toolNames.contains("bash_manage") {
            return "💻 Running command..."
        }

        // Document / media sends.
        if toolNames.contains("send_document_to_chat") {
            return "📎 Handling files..."
        }

        // Shortcuts.
        if toolNames.contains("shortcuts") || toolNames.contains("run_shortcut") || toolNames.contains("list_shortcuts") {
            return "⌘ Running shortcut..."
        }

        // Planning / memory.
        if toolNames.contains("todo_write") {
            return "📋 Updating plan..."
        }
        if toolNames.contains("view_conversation_chunk") {
            return "🗂 Reading memory..."
        }

        // MCP tools — grouped by server so "mcp__playwright__*" all get one message.
        if toolNames.contains(where: { $0.hasPrefix("mcp__playwright__") }) {
            return "🌐 Browsing..."
        }
        if toolNames.contains(where: { $0.hasPrefix("mcp__nano-banana__") }) {
            return "🎨 Working with images..."
        }
        if toolNames.contains(where: { $0.hasPrefix("mcp__") }) {
            // Extract the server name from the first matching MCP tool for a
            // friendlier generic message. Format: mcp__<server>__<tool>.
            if let first = toolNames.first(where: { $0.hasPrefix("mcp__") }) {
                let parts = first.components(separatedBy: "__")
                if parts.count >= 2, !parts[1].isEmpty {
                    return "🔌 Using \(parts[1]) MCP..."
                }
            }
            return "🔌 Using MCP tool..."
        }

        // Fallback for unrecognized / mixed tool combos.
        return "🔧 Processing..."
    }
    
    /// Build a compact per-step tool log to persist in conversation memory
    /// right before the final assistant response.
    private func buildCompactToolExecutionLog(from interactions: [ToolInteraction]) -> String? {
        guard !interactions.isEmpty else { return nil }
        
        var lines: [String] = [toolRunLogPrefix]
        var stepIndex = 1
        
        for interaction in interactions {
            var resultByCallId: [String: ToolResultMessage] = [:]
            for result in interaction.results {
                resultByCallId[result.toolCallId] = result
            }
            
            for call in interaction.assistantMessage.toolCalls {
                let outcome = summarizeToolOutcome(resultByCallId[call.id])
                lines.append("\(stepIndex). \(call.function.name): \(outcome)")
                stepIndex += 1
            }
        }
        
        guard stepIndex > 1 else { return nil }
        return lines.joined(separator: "\n")
    }
    
    private func summarizeToolOutcome(_ result: ToolResultMessage?) -> String {
        guard let result else { return "no-result" }
        
        let fileSuffix = result.fileAttachments.isEmpty
            ? ""
            : " (+\(result.fileAttachments.count) file\(result.fileAttachments.count == 1 ? "" : "s"))"
        
        if let dict = parseJSONDictionary(from: result.content) {
            if let error = dict["error"] as? String, !error.isEmpty {
                return "error - \(compact(error, maxLength: 90))\(fileSuffix)"
            }
            
            if let message = dict["message"] as? String, !message.isEmpty {
                return "ok - \(compact(message, maxLength: 90))\(fileSuffix)"
            }
            
            if let summary = dict["summary"] as? String, !summary.isEmpty {
                return "ok - \(compact(summary, maxLength: 90))\(fileSuffix)"
            }
            
            if let downloadedCount = dict["downloadedCount"] as? Int {
                return "ok - downloaded \(downloadedCount)\(fileSuffix)"
            }
            
            if let count = dict["count"] as? Int {
                return "ok - count \(count)\(fileSuffix)"
            }
            
            if let eventCount = dict["eventCount"] as? Int {
                return "ok - events \(eventCount)\(fileSuffix)"
            }
            
            if let success = dict["success"] as? Bool {
                return (success ? "ok" : "failed") + fileSuffix
            }
            
            return "ok\(fileSuffix)"
        }
        
        let fallback = compact(result.content, maxLength: 90)
        return (fallback.isEmpty ? "ok" : fallback) + fileSuffix
    }
    
    private func parseJSONDictionary(from content: String) -> [String: Any]? {
        guard let jsonContent = extractJSONObjectString(from: content),
              let data = jsonContent.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func extractJSONObjectString(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startIndex = trimmed.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaping = false

        for index in trimmed[startIndex...].indices {
            let character = trimmed[index]

            if inString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(trimmed[startIndex...index])
                }
            default:
                continue
            }
        }

        return nil
    }
    
    private func compact(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength)) + "..."
    }
    
    private func isToolRunLogMessage(_ message: Message) -> Bool {
        message.role == .assistant && message.content.hasPrefix(toolRunLogPrefix)
    }
    
    /// Keep only the most recent N compact tool-log messages to avoid context bloat.
    @discardableResult
    private func pruneOldToolLogMessages() -> Int {
        let logIndices = messages.indices.filter { isToolRunLogMessage(messages[$0]) }
        let excessCount = logIndices.count - maxRetainedToolRunLogs
        guard excessCount > 0 else { return 0 }
        
        let indicesToRemove = logIndices.prefix(excessCount).sorted(by: >)
        for index in indicesToRemove {
            messages.remove(at: index)
        }
        
        return excessCount
    }
    
    // MARK: - Reminder Processing
    
    private func checkDueReminders() async {
        // Clear any previous error when checking reminders
        error = nil
        
        // Don't run reminder workflows while a user-triggered run is active
        guard activeRunId == nil else { return }
        
        let dueReminders = await ReminderService.shared.getDueReminders()
        
        guard !dueReminders.isEmpty else { return }
        
        for reminder in dueReminders {
            // Mark as triggered FIRST to prevent race conditions with next poll iteration
            await ReminderService.shared.markTriggered(id: reminder.id)
            
            // If this is a recurring reminder, schedule the next occurrence
            if reminder.recurrence != nil {
                if let nextReminder = await ReminderService.shared.rescheduleRecurring(id: reminder.id) {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .medium
                    dateFormatter.timeStyle = .short
                    print("[ConversationManager] Recurring reminder rescheduled for: \(dateFormatter.string(from: nextReminder.triggerDate))")
                }
            }
            
            print("[ConversationManager] Processing due reminder: \(reminder.id)")
            statusMessage = "Processing reminder..."
            
            // Notify user that a reminder is being processed
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(chatId: chatId, text: "⏰ Reminder triggered!")
            }
            
            // Format the reminder as a user message so the LLM can respond to it
            let reminderPrompt = """
            [SCHEDULED REMINDER - This is a message you wrote to yourself earlier]
            
            \(reminder.prompt)
            
            [END OF REMINDER - Please act on these instructions now]
            """
            
            // Add the reminder as a user message
            let userMessage = Message(role: .user, content: reminderPrompt, kind: .reminderFired)
            messages.append(userMessage)
            saveConversation()
            
            // Generate LLM response with tools available
            do {
                let turnStartDate = Date()
                let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)
                
                if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                    messages.append(Message(role: .assistant, content: toolLog))
                    pruneOldToolLogMessages()
                }
                
                // Add assistant message (guard against empty response)
                let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "I completed the reminder actions."
                    : response.finalText
                let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
                let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
                let assistantMessage = Message(
                    role: .assistant,
                    content: finalResponse,
                    downloadedDocumentFileNames: downloadedFilenames,
                    editedFilePaths: response.editedFilePaths,
                    generatedFilePaths: response.generatedFilePaths,
                    accessedProjectIds: response.accessedProjects ?? []
                )
                messages.append(assistantMessage)
                saveConversation()

                // Send reply via Telegram
                if let chatId = pairedChatId {
                    try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                }

                print("[ConversationManager] Reminder \(reminder.id) processed successfully")
            } catch {
                self.error = "Failed to process reminder: \(error.localizedDescription)"
                print("[ConversationManager] Failed to process reminder: \(error)")
            }
        }
        
        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }

    // MARK: - Scratch disk pressure

    /// If the scratch repos dir has crossed `ScratchDiskMonitor.thresholdBytes`, inject a
    /// synthetic reminder-kind message listing the stalest clones so the agent can decide
    /// which to delete. The monitor enforces a 6h cooldown — no nag loops if the agent
    /// [SKIP]s because every clone is still active work.
    private func checkScratchDiskPressure() async {
        guard activeRunId == nil else { return }

        let measurement = ScratchDiskMonitor.measure()
        guard ScratchDiskMonitor.shouldPromptNow(measurement: measurement) else { return }

        print("[ConversationManager] Scratch disk pressure: \(measurement.totalBytes) bytes across \(measurement.entries.count) entries — prompting agent")
        statusMessage = "Processing scratch-disk cleanup..."

        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: "🧹 Scratch dir over threshold — asking the agent to curate.")
        }

        let prompt = ScratchDiskMonitor.formatCleanupPrompt(from: measurement)
        let userMessage = Message(role: .user, content: prompt, kind: .reminderFired)
        messages.append(userMessage)
        saveConversation()

        do {
            let turnStartDate = Date()
            let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)

            if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                messages.append(Message(role: .assistant, content: toolLog))
                pruneOldToolLogMessages()
            }

            let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "I reviewed the scratch dir."
                : response.finalText
            let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
            let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
            let assistantMessage = Message(
                role: .assistant,
                content: finalResponse,
                downloadedDocumentFileNames: downloadedFilenames,
                editedFilePaths: response.editedFilePaths,
                generatedFilePaths: response.generatedFilePaths,
                accessedProjectIds: response.accessedProjects ?? []
            )
            messages.append(assistantMessage)
            saveConversation()

            if let chatId = pairedChatId {
                try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
            }
        } catch {
            self.error = "Failed to process scratch cleanup: \(error.localizedDescription)"
            print("[ConversationManager] Failed to process scratch cleanup: \(error)")
        }

        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }

    // MARK: - Background bash completion handling

    /// Drain completed background bash processes and inject each one as a synthetic user
    /// message, triggering a new agent turn so the agent can react (e.g. Telegram the user).
    private func checkBackgroundBashCompletions() async {
        guard activeRunId == nil else { return }
        let completions = await BackgroundProcessRegistry.shared.drainCompletions()
        guard !completions.isEmpty else { return }

        for completion in completions {
            let statusLabel: String
            switch completion.status {
            case .exited:  statusLabel = completion.exitCode == 0 ? "exited cleanly" : "exited with code \(completion.exitCode)"
            case .killed:  statusLabel = "killed"
            case .crashed: statusLabel = "crashed with signal"
            case .running: statusLabel = "unexpectedly still running"
            }

            let bashIsError: Bool = {
                switch completion.status {
                case .exited: return completion.exitCode != 0
                case .killed, .crashed: return true
                case .running: return true
                }
            }()
            DebugTelemetry.log(
                .bashComplete,
                summary: "bash \(completion.handleId) \(statusLabel)",
                detail: "command: \(completion.command)\nexit: \(completion.exitCode)\nduration: \(completion.durationSeconds)s",
                durationMs: completion.durationSeconds * 1000,
                isError: bashIsError
            )

            let durationStr: String = {
                let secs = completion.durationSeconds
                if secs < 60 { return "\(secs)s" }
                if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
                return "\(secs / 3600)h \((secs % 3600) / 60)m"
            }()

            var body = """
            [BACKGROUND BASH COMPLETE]

            handle: \(completion.handleId)
            command: \(completion.command)
            status: \(statusLabel)
            duration: \(durationStr)
            """
            if let desc = completion.description, !desc.isEmpty {
                body += "\ndescription: \(desc)"
            }
            body += "\n\n--- stdout (tail) ---\n\(completion.stdoutTail)"
            if !completion.stderrTail.isEmpty {
                body += "\n\n--- stderr (tail) ---\n\(completion.stderrTail)"
            }
            body += "\n\n[END OF BACKGROUND TASK - If the user asked you to notify them when this finished, do so now.]"

            let userMessage = Message(role: .user, content: body, kind: .bashComplete)
            messages.append(userMessage)
            saveConversation()

            do {
                let turnStartDate = Date()
                let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)

                if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                    messages.append(Message(role: .assistant, content: toolLog))
                    pruneOldToolLogMessages()
                }

                let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Background task \(completion.handleId) finished."
                    : response.finalText
                let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
                let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
                let assistantMessage = Message(
                    role: .assistant,
                    content: finalResponse,
                    downloadedDocumentFileNames: downloadedFilenames,
                    editedFilePaths: response.editedFilePaths,
                    generatedFilePaths: response.generatedFilePaths,
                    accessedProjectIds: response.accessedProjects ?? []
                )
                messages.append(assistantMessage)
                saveConversation()

                if let chatId = pairedChatId {
                    try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                }
                print("[ConversationManager] Background completion \(completion.handleId) processed")
            } catch {
                self.error = "Failed to process bash completion: \(error.localizedDescription)"
                print("[ConversationManager] Failed to process bash completion: \(error)")
            }
        }

        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }

    // MARK: - Background subagent completion handling

    /// Drain completed background subagents and inject each as a synthetic user message,
    /// triggering a new agent turn so the parent can react (e.g. notify the user, continue
    /// work that depended on the subagent's findings). Mirrors the bash completion flow.
    private func checkBackgroundSubagentCompletions() async {
        guard activeRunId == nil else { return }
        let completions = await SubagentBackgroundRegistry.shared.drainCompletions()
        guard !completions.isEmpty else { return }

        for completion in completions {
            let duration = completion.completedAt.timeIntervalSince(completion.handle.startedAt)
            let durationStr = String(format: "%.1fs", duration)

            let subagentErr = completion.result.error ?? ""
            DebugTelemetry.log(
                .subagentComplete,
                summary: "subagent \(completion.handle.id) (\(completion.handle.subagentType)) done",
                detail: "description: \(completion.handle.description)\nturns: \(completion.result.turnsUsed)\nspend: $\(String(format: "%.4f", completion.result.spendUSD))\(subagentErr.isEmpty ? "" : "\nerror: \(subagentErr)")",
                durationMs: Int(duration * 1000),
                isError: !subagentErr.isEmpty
            )

            let toolsStr = completion.result.toolsCalled.isEmpty
                ? "(none)"
                : completion.result.toolsCalled.joined(separator: ", ")
            let filesStr = completion.result.filesTouched.isEmpty
                ? "(none)"
                : completion.result.filesTouched.joined(separator: ", ")
            let spendStr = String(format: "%.4f", completion.result.spendUSD)

            // Persist background subagent spend to the authoritative daily/monthly
            // counters in Keychain so it counts toward the user-configured spend
            // limits. The generateResponseWithTools call that follows will re-seed
            // its local spend status from Keychain at the top of the loop.
            if completion.result.spendUSD.isFinite, completion.result.spendUSD > 0 {
                KeychainHelper.recordOpenRouterSpend(completion.result.spendUSD)
                print("[ConversationManager] Background subagent \(completion.handle.id) spend: +$\(formatUSD(completion.result.spendUSD))")
            }

            var body = """
            [SUBAGENT COMPLETE]
            handle: \(completion.handle.id)
            subagent_type: \(completion.handle.subagentType)
            description: \(completion.handle.description)
            turns_used: \(completion.result.turnsUsed)
            tools_called: \(toolsStr)
            files_touched: \(filesStr)
            spend_usd: \(spendStr)
            duration: \(durationStr)
            """
            if let err = completion.result.error, !err.isEmpty {
                body += "\nerror: \(err)"
                body += "\nfinal_message (possibly partial):"
            } else {
                body += "\nfinal_message:"
            }
            body += "\n\(completion.result.finalMessage)"

            let userMessage = Message(role: .user, content: body, kind: .subagentComplete)
            messages.append(userMessage)
            saveConversation()

            do {
                let turnStartDate = Date()
                let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)

                if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                    messages.append(Message(role: .assistant, content: toolLog))
                    pruneOldToolLogMessages()
                }

                let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Background subagent \(completion.handle.id) finished."
                    : response.finalText
                let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
                let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
                let assistantMessage = Message(
                    role: .assistant,
                    content: finalResponse,
                    downloadedDocumentFileNames: downloadedFilenames,
                    editedFilePaths: response.editedFilePaths,
                    generatedFilePaths: response.generatedFilePaths,
                    accessedProjectIds: response.accessedProjects ?? []
                )
                messages.append(assistantMessage)
                saveConversation()

                if let chatId = pairedChatId {
                    try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                }
                print("[ConversationManager] Background subagent \(completion.handle.id) processed")
            } catch {
                self.error = "Failed to process subagent completion: \(error.localizedDescription)"
                print("[ConversationManager] Failed to process subagent completion: \(error)")
            }
        }

        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }

    // MARK: - Background bash_manage watch match handling

    /// Drain pending `bash_manage watch` regex matches and inject them into the conversation as
    /// synthetic user messages, coalesced by handle so that a burst of matches within a
    /// single poll tick produces ONE wake-up (not N re-entries into the agentic loop).
    /// Reuses the `.bashComplete` message kind — these are ephemeral notifications that
    /// do not need history compression.
    private func checkBashWatchMatches() async {
        guard activeRunId == nil else { return }
        let matches = await BackgroundProcessRegistry.shared.drainWatchMatches()
        guard !matches.isEmpty else { return }

        // Group by handle, preserving arrival order within each group.
        var orderedHandles: [String] = []
        var grouped: [String: [BackgroundProcessRegistry.WatchMatch]] = [:]
        for m in matches {
            if grouped[m.handle] == nil {
                orderedHandles.append(m.handle)
                grouped[m.handle] = []
            }
            grouped[m.handle]?.append(m)
        }

        for handle in orderedHandles {
            guard let group = grouped[handle], !group.isEmpty else { continue }

            // One coalesced message per handle. If multiple watches fired on the same
            // handle in this tick, list all their matches; collapse pattern/watch
            // metadata per line for the agent's benefit.
            let first = group[0]
            let totalCount = group.count

            DebugTelemetry.log(
                .watchMatch,
                summary: "watch match on \(first.handle) (\(totalCount) line\(totalCount == 1 ? "" : "s"))",
                detail: "pattern: \(first.pattern)\nfirst line: \(first.line)"
            )
            var body = "[BASH WATCH MATCH]\n"
            body += "handle: \(first.handle)\n"

            // If every match is from the same watch, show the pattern once.
            let uniquePatterns = Set(group.map { $0.pattern })
            if uniquePatterns.count == 1 {
                body += "pattern: \"\(first.pattern)\"\n"
            }
            body += "matches (\(totalCount)):\n"
            for m in group {
                if uniquePatterns.count > 1 {
                    body += "[\(m.stream)] <\(m.pattern)> \(m.line)\n"
                } else {
                    body += "[\(m.stream)] \(m.line)\n"
                }
            }

            // Status footer: if ANY match in this tick flagged auto-unsubscribe, surface
            // the first such reason; otherwise summarize remaining capacity.
            if let terminal = group.first(where: { $0.autoUnsubscribed }) {
                let reasonNote: String
                switch terminal.unsubscribeReason {
                case "process_exited":
                    reasonNote = "Watch auto-unsubscribed — background process exited."
                case "limit_reached":
                    reasonNote = "Watch auto-unsubscribed — hit match limit (\(terminal.matchesSoFar)/\(terminal.limit))."
                case "regex_timeout":
                    reasonNote = "Watch auto-unsubscribed — regex pattern exceeded 10ms match timeout (possible catastrophic backtracking)."
                default:
                    reasonNote = "Watch auto-unsubscribed."
                }
                body += "\n\(reasonNote)"
            } else {
                let last = group.last!
                let remaining = max(last.limit - last.matchesSoFar, 0)
                body += "\nThe watch is still active (\(remaining) of \(last.limit) remaining). Use bash_manage(mode='output') for full context or bash_manage(mode='kill') to terminate."
            }

            let userMessage = Message(role: .user, content: body, kind: .bashComplete)
            messages.append(userMessage)
            saveConversation()

            do {
                let turnStartDate = Date()
                let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)

                if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                    messages.append(Message(role: .assistant, content: toolLog))
                    pruneOldToolLogMessages()
                }

                let finalTextTrimmed = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalTextTrimmed.isEmpty {
                    let finalResponse = capAssistantMessageForHistoryAndTelegram(response.finalText)
                    let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
                    let assistantMessage = Message(
                        role: .assistant,
                        content: finalResponse,
                        downloadedDocumentFileNames: downloadedFilenames,
                        editedFilePaths: response.editedFilePaths,
                        generatedFilePaths: response.generatedFilePaths,
                        accessedProjectIds: response.accessedProjects ?? []
                    )
                    messages.append(assistantMessage)
                    saveConversation()
                    if let chatId = pairedChatId {
                        try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                    }
                }
                print("[ConversationManager] bash_manage watch match batch for \(handle) processed (\(totalCount) match\(totalCount == 1 ? "" : "es"))")
            } catch {
                self.error = "Failed to process bash_manage watch match: \(error.localizedDescription)"
                print("[ConversationManager] Failed to process bash_manage watch match: \(error)")
            }
        }

        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }

    // MARK: - Smart Email Notifications
    
    /// Process new emails: use Gemini with full context to decide if notification-worthy
    /// and generate a personalized notification message.
    /// Runs in a detached context to avoid blocking user interactions.
    /// Handler fired by GoogleWorkspaceService when a fresh unread email lands
    /// between polls. Builds a synthetic user-role message (kind `.emailArrived`)
    /// so the standard conversation pipeline picks it up and the agent can notify
    /// Matteo via Telegram.
    private func processNewUnreadEmails(_ emails: [GoogleWorkspaceService.UnreadEmail]) async {
        guard pairedChatId != nil, !emails.isEmpty else { return }

        print("[ConversationManager] Processing \(emails.count) new unread email(s) for notification")

        var emailDetails: [String] = []
        for email in emails {
            var detail = """
            ---
            From: \(email.from)
            Subject: \(email.subject)
            Date: \(email.date)
            ID: \(email.id)
            """
            if !email.snippet.isEmpty {
                detail += "\nPreview:\n\(email.snippet)"
            }
            emailDetails.append(detail)
        }

        while activeRunId != nil || activeProcessingTask != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let emailContent = """
        [SYSTEM: NEW EMAILS ARRIVED]
        Decide whether these are worth notifying the user about. If not, reply with exactly `[SKIP]` (and nothing else) — no Telegram notification will be sent. Otherwise, reply normally with a short summary.
        Use `gws` via `bash` for follow-up actions when needed (e.g. `gws gmail +read --id <id>`, `gws gmail +reply`).

        New emails:
        \(emailDetails.joined(separator: "\n"))
        """

        let userMessage = Message(role: .user, content: emailContent, kind: .emailArrived)
        messages.append(userMessage)

        statusMessage = "Processing new emails..."
        startActiveProcessing(for: userMessage)
    }


    /// Process new Gmail emails (Gmail API version of processNewEmails)

    // MARK: - Persistence
    
    private func loadConversation() {
        guard FileManager.default.fileExists(atPath: conversationFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: conversationFileURL)
            messages = try JSONDecoder().decode([Message].self, from: data)
            // Cleanup old compact tool logs from previous runs to keep context lean.
            if pruneOldToolLogMessages() > 0 {
                saveConversation()
            }
        } catch {
            print("Failed to load conversation: \(error)")
        }
    }
    
    private func saveConversation() {
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: conversationFileURL)
        } catch {
            print("Failed to save conversation: \(error)")
        }
    }
    
    func clearConversation() {
        messages = []
        saveConversation()
        
        // Also clear images
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: toolAttachmentsDirectory)
        try? FileManager.default.createDirectory(at: toolAttachmentsDirectory, withIntermediateDirectories: true)
    }
    
    /// Delete all memory: conversation, chunks, summaries, user context, reminders
    /// Keeps: Calendar and Contacts
    func deleteAllMemory() async {
        // 1. Clear conversation and images
        clearConversation()
        
        // 2. Clear all archived chunks
        await archiveService.clearAllArchives()
        
        // 3. Clear all reminders
        await ReminderService.shared.clearAllReminders()
        
        // 4. Clear user context from Keychain
        try? KeychainHelper.delete(key: KeychainHelper.userContextKey)
        try? KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey)
        
        // 5. Clear documents directory
        try? FileManager.default.removeItem(at: documentsDirectory)
        try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        
        // 6. Clear file descriptions
        await FileDescriptionService.shared.clearAll()
        
        print("[ConversationManager] All memory deleted")
    }
    
    /// Reload all data from disk after Mind restore
    /// This refreshes the conversation and archive service to pick up restored data
    func reloadAfterMindRestore() async {
        loadConversation()
        await archiveService.reloadFromDisk()
        print("[ConversationManager] Reloaded data after Mind restore")
    }
    
    // MARK: - Helpers
    
    private func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    private func capAssistantMessageForHistoryAndTelegram(_ text: String) -> String {
        let utf16Count = text.utf16.count
        guard utf16Count > maxAssistantMessageChars else { return text }
        // Truncate by UTF-16 code units (Telegram uses UTF-16 counting for its 4096 limit).
        // Walk the string keeping only characters whose cumulative UTF-16 length fits.
        var used = 0
        var endIndex = text.startIndex
        for idx in text.indices {
            let charUTF16Len = text[idx].utf16.count
            if used + charUTF16Len > maxAssistantMessageChars { break }
            used += charUTF16Len
            endIndex = text.index(after: idx)
        }
        let capped = String(text[text.startIndex..<endIndex])
        print("[ConversationManager] Assistant message capped to first \(maxAssistantMessageChars) UTF-16 units (original: \(utf16Count))")
        return capped
    }
    
    // MARK: - Image Access (for UI)
    
    func imageURL(for message: Message) -> URL? {
        guard let fileName = message.imageFileName else { return nil }
        let url = imagesDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    /// Returns all image URLs for a message (primary attachments)
    func imageURLs(for message: Message) -> [URL] {
        message.imageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns all referenced image URLs for a message (from replied-to messages)
    func referencedImageURLs(for message: Message) -> [URL] {
        message.referencedImageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns the URL for a document file
    func documentURL(fileName: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    // MARK: - Context for Settings Structuring
    
    /// Get conversation context for the "Process & Save" feature in Settings.
    /// Returns recent messages and chunk summaries so Gemini has full awareness.
    func getContextForStructuring() async -> (recentMessages: [Message], chunkSummaries: [ArchivedSummaryItem]) {
        let chunkSummaries = await archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        // Return last 20 messages for recent context
        let recentMessages = Array(messages.suffix(20))
        return (recentMessages, chunkSummaries)
    }
    
    /// Load the full archived text for a specific chunk.
    func getArchivedChunkContent(chunkId: UUID) async throws -> String {
        try await archiveService.getChunkContent(chunkId: chunkId)
    }
    
    // MARK: - Summarization Context Builder
    
    /// Build full context for summarization so the LLM can properly understand
    /// relationships, references, and meaning in the chunk being archived.
    /// Note: Calendar is deliberately excluded - it contains future events not relevant to historical summarization.
    private func buildSummarizationContext(
        chunkSummaries: [ArchivedSummaryItem],
        currentMessages: [Message]
    ) -> ConversationArchiveService.SummarizationContext {
        // Get persona settings
        let personaContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey)
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey)
        
        // Format previous summaries chronologically
        let previousSummaries = chunkSummaries.sorted { $0.startDate < $1.startDate }.map { $0.summary }
        
        // Format current conversation context (last ~10 messages of what's happening now)
        let recentMessages = currentMessages.suffix(10)
        let currentContext: String?
        if !recentMessages.isEmpty {
            currentContext = recentMessages.map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "[\(role)]: \(msg.content.prefix(500))"
            }.joined(separator: "\n")
        } else {
            currentContext = nil
        }
        
        return ConversationArchiveService.SummarizationContext(
            personaContext: personaContext,
            assistantName: assistantName,
            userName: userName,
            previousSummaries: previousSummaries,
            currentConversationContext: currentContext
        )
    }
    
    // MARK: - File Description Helpers
    
    /// Generate file descriptions at the exact pruning event that removes the
    /// original bytes from prompt replay. Context is anchored to the file's own
    /// turn: up to 8 previous messages plus the file-bearing message itself, and
    /// never later conversation.
    private func generateDescriptionsBeforePruning(
        messageIndex: Int,
        includeInlineMedia: Bool,
        includeToolAttachments: Bool,
        sourceMessages: [Message]
    ) async {
        guard sourceMessages.indices.contains(messageIndex) else { return }

        let message = sourceMessages[messageIndex]
        var files: [(filename: String, data: Data, mimeType: String)] = []

        if includeInlineMedia {
            files.append(contentsOf: collectInlineMediaFilesForDescription(from: message))
        }
        if includeToolAttachments {
            files.append(contentsOf: collectToolAttachmentFilesForDescription(from: message))
        }

        files = await filesWithoutStoredDescriptions(files)
        guard !files.isEmpty else { return }

        // ── Per-file limits: skip oversized files, cap PDF pages ──
        var cappedFiles: [(filename: String, data: Data, mimeType: String)] = []
        var fallbackDescriptions: [String: String] = [:]

        for file in files {
            if file.data.count > Self.descriptionMaxFileSizeBytes {
                fallbackDescriptions[file.filename] = "Large file (\(file.data.count / 1024)KB)"
                print("[ConversationManager] Skipping \(file.filename) for description: \(file.data.count) bytes exceeds \(Self.descriptionMaxFileSizeBytes) limit")
                continue
            }
            if file.mimeType.lowercased() == "application/pdf",
               let doc = PDFDocument(data: file.data),
               doc.pageCount > Self.descriptionMaxPDFPages {
                let sliced = PDFDocument()
                for i in 0..<Self.descriptionMaxPDFPages {
                    if let page = doc.page(at: i) { sliced.insert(page, at: i) }
                }
                if let slicedData = sliced.dataRepresentation() {
                    cappedFiles.append((filename: file.filename, data: slicedData, mimeType: file.mimeType))
                    print("[ConversationManager] Capped \(file.filename) from \(doc.pageCount) to \(Self.descriptionMaxPDFPages) pages for description")
                } else {
                    fallbackDescriptions[file.filename] = "PDF document (\(doc.pageCount) pages)"
                }
            } else {
                cappedFiles.append(file)
            }
        }

        // ── Batch limit: cap total files per API call ──
        if cappedFiles.count > Self.descriptionMaxFiles {
            for file in cappedFiles[Self.descriptionMaxFiles...] {
                fallbackDescriptions[file.filename] = "File skipped (batch limit of \(Self.descriptionMaxFiles) reached)"
            }
            cappedFiles = Array(cappedFiles.prefix(Self.descriptionMaxFiles))
        }

        if !fallbackDescriptions.isEmpty {
            await FileDescriptionService.shared.saveMultiple(fallbackDescriptions)
        }

        guard !cappedFiles.isEmpty else { return }

        let context = descriptionContextMessages(
            forMessageAt: messageIndex,
            in: sourceMessages,
            previousLimit: 8
        )

        do {
            let descriptions = try await openRouterService.generateFileDescriptions(
                files: cappedFiles,
                conversationContext: context
            )
            await FileDescriptionService.shared.saveMultiple(descriptions)
        } catch {
            print("[ConversationManager] Failed to generate prune-time file descriptions: \(error)")
        }
    }

    private func descriptionContextMessages(
        forMessageAt index: Int,
        in sourceMessages: [Message],
        previousLimit: Int
    ) -> [Message] {
        guard sourceMessages.indices.contains(index) else { return [] }
        let start = max(0, index - previousLimit)
        return Array(sourceMessages[start...index])
    }

    private func filesWithoutStoredDescriptions(
        _ files: [(filename: String, data: Data, mimeType: String)]
    ) async -> [(filename: String, data: Data, mimeType: String)] {
        var seen = Set<String>()
        var filtered: [(filename: String, data: Data, mimeType: String)] = []

        for file in files {
            guard seen.insert(file.filename).inserted else { continue }
            if await FileDescriptionService.shared.get(filename: file.filename) == nil {
                filtered.append(file)
            }
        }

        return filtered
    }

    /// Collect inline user/referenced media from a message for description generation.
    private func collectInlineMediaFilesForDescription(from message: Message) -> [(filename: String, data: Data, mimeType: String)] {
        var files: [(filename: String, data: Data, mimeType: String)] = []
        
        for imageFileName in message.imageFileNames + message.referencedImageFileNames {
            let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
            if let imageData = try? Data(contentsOf: imageURL) {
                files.append((filename: imageFileName, data: imageData, mimeType: mimeTypeForAttachmentFile(imageFileName)))
            }
        }
        
        for documentFileName in message.documentFileNames + message.referencedDocumentFileNames {
            let documentURL = documentsDirectory.appendingPathComponent(documentFileName)
            if let documentData = try? Data(contentsOf: documentURL) {
                files.append((filename: documentFileName, data: documentData, mimeType: mimeTypeForAttachmentFile(documentFileName)))
            }
        }
        
        return files
    }

    /// Limits for the file-description API call made at prune time.
    private static let descriptionMaxPDFPages = 10
    private static let descriptionMaxFiles = 8
    private static let descriptionMaxFileSizeBytes = 5 * 1024 * 1024 // 5 MB

    /// Tools whose output files deserve a persisted description. Everything
    /// else (read_file, grep, etc.) is transient working data that doesn't
    /// need a natural-language summary.
    private static let describableToolNames: Set<String> = [
        "generate_image", "edit_image", "run_shortcut", "send_document_to_chat"
    ]

    private func collectToolAttachmentFilesForDescription(from message: Message) -> [(filename: String, data: Data, mimeType: String)] {
        var files: [(filename: String, data: Data, mimeType: String)] = []

        for interaction in message.toolInteractions {
            let toolNames = Set(interaction.assistantMessage.toolCalls.map { $0.function.name })
            guard !toolNames.isDisjoint(with: Self.describableToolNames) else { continue }

            // Map toolCallId → tool name so we only collect attachments from allowed tools
            let callIdToName = Dictionary(
                interaction.assistantMessage.toolCalls.map { ($0.id, $0.function.name) },
                uniquingKeysWith: { first, _ in first }
            )

            // Collect FileAttachmentReferences only from allowed tool results
            for result in interaction.results {
                guard let name = callIdToName[result.toolCallId],
                      Self.describableToolNames.contains(name) else { continue }
                for reference in result.fileAttachmentReferences {
                    guard let data = dataForAttachmentReference(reference) else { continue }
                    files.append((filename: reference.filename, data: data, mimeType: reference.mimeType))
                }
            }

            // send_document_to_chat doesn't produce FileAttachmentReferences —
            // extract the filename from the tool arguments and load from disk.
            for call in interaction.assistantMessage.toolCalls where call.function.name == "send_document_to_chat" {
                guard let argsData = call.function.arguments.data(using: .utf8),
                      let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else { continue }
                let url = documentsDirectory.appendingPathComponent(args.documentFilename)
                guard let data = try? Data(contentsOf: url) else { continue }
                files.append((filename: args.documentFilename, data: data, mimeType: mimeTypeForAttachmentFile(args.documentFilename)))
            }
        }

        return files
    }

    private func dataForAttachmentReference(_ reference: FileAttachmentReference) -> Data? {
        guard let url = reference.resolvedURL(
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory
        ) else {
            return nil
        }

        if let snapshotPath = reference.snapshotPath, url.path == snapshotPath {
            return try? Data(contentsOf: url)
        }

        guard normalizedMimeType(reference.mimeType) == "application/pdf",
              let pageRange = reference.pageRange,
              let doc = PDFDocument(url: url),
              let requestedRange = parsePersistedPageRange(pageRange, totalPages: doc.pageCount) else {
            return try? Data(contentsOf: url)
        }

        let sliced = PDFDocument()
        var insertIndex = 0
        for pageNumber in requestedRange {
            if let page = doc.page(at: pageNumber - 1) {
                sliced.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }
        return sliced.dataRepresentation()
    }

    private func parsePersistedPageRange(_ raw: String, totalPages: Int) -> ClosedRange<Int>? {
        let parts = raw.split(separator: "-", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let page = Int(parts[0]), page >= 1, page <= totalPages {
            return page...page
        }
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              lower >= 1,
              upper >= lower,
              upper <= totalPages else {
            return nil
        }
        return lower...upper
    }

    private func mimeTypeForAttachmentFile(_ fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
