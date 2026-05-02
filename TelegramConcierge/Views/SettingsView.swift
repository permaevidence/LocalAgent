import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    let section: AppSection
    @EnvironmentObject var conversationManager: ConversationManager
    
    @State private var telegramToken: String = ""
    @State private var chatId: String = ""
    @State private var llmProvider: String = "lmstudio"
    @State private var lmStudioBaseURL: String = ""
    @State private var lmStudioModel: String = ""
    @State private var lmStudioDescriptionModel: String = ""
    @State private var lmStudioDescriptionBaseURL: String = ""
    @State private var openRouterApiKey: String = ""
    @State private var openRouterModel: String = ""
    @State private var openRouterProviders: String = ""
    @State private var openRouterReasoningEffort: String = "high"
    @State private var openRouterToolSpendLimit: String = ""
    @State private var openRouterDailySpendLimit: String = ""
    @State private var openRouterMonthlySpendLimit: String = ""
    @State private var openRouterTodaySpendUSD: Double = 0
    @State private var openRouterMonthSpendUSD: Double = 0
    @State private var serperApiKey: String = ""
    @State private var jinaApiKey: String = ""
    @State private var showingSaveConfirmation: Bool = false
    @State private var isTesting: Bool = false
    @State private var botInfo: String?
    @State private var testError: String?
    
    // Google Workspace (Gmail, Calendar, Contacts, Drive) is reached through
    // the `gws` CLI — no in-app credentials or contact store. The former email
    // / Gmail-OAuth / contacts @State fields were removed as part of the
    // migration; CLI install + auth happens in a terminal.


    // Image generation settings
    @State private var geminiApiKey: String = ""
    @State private var geminiImageModel: String = KeychainHelper.defaultGeminiImageModel
    @State private var geminiImageInputCostPerMillionTokensUSD: String = ""
    @State private var geminiImageOutputTextCostPerMillionTokensUSD: String = ""
    @State private var geminiImageOutputImageCostPerMillionTokensUSD: String = ""

    // Voice transcription settings
    @State private var voiceTranscriptionProvider: VoiceTranscriptionProvider = .defaultProvider
    @State private var openAITranscriptionApiKey: String = ""
    
    // Persona settings
    @State private var assistantName: String = ""
    @State private var userName: String = ""
    @State private var userContext: String = ""
    @State private var structuredUserContext: String = ""
    @State private var isStructuredContextExpanded: Bool = false
    @State private var isEditingStructuredContext: Bool = false
    @State private var structuredContextDraft: String = ""
    @State private var isStructuring: Bool = false
    @State private var structuringError: String?
    
    // Section save confirmations (legacy, kept for sectionSaveButton)
    @State private var savedSection: String?

    // Auto-save debounce
    @State private var autoSaveTask: Task<Void, Never>?

    // Collapsible sections
    @State private var isSpendLimitsExpanded: Bool = false
    @State private var isDescriptionModelExpanded: Bool = false
    @State private var isImagePricingExpanded: Bool = false

    // Context viewer
    @State private var showingContextViewer: Bool = false
    
    // Archive settings
    @State private var archiveChunkSize: String = ""

    // Context budget settings
    @State private var maxContextTokens: String = ""
    @State private var targetContextTokens: String = ""
    @State private var showingContextBudgetSaved: Bool = false

    // Memory deletion
    @State private var showingDeleteMemoryConfirmation: Bool = false
    @State private var showingDeleteContextConfirmation: Bool = false
    @State private var showingChunkSizeSaved: Bool = false
    
    // Mind export/import
    @State private var isExportingMind: Bool = false
    @State private var isImportingMind: Bool = false
    @State private var mindExportSuccess: String?
    @State private var mindExportError: String?
    @State private var showingRestoreConfirmation: Bool = false
    @State private var pendingImportURL: URL?
    @State private var showingMindFilePicker: Bool = false
    
    // Service keys
    @State private var serviceKeys: [ServiceKey] = []
    @State private var newKeyName: String = ""
    @State private var newKeyValue: String = ""
    @State private var newKeyDescription: String = ""
    @State private var showingAddKey: Bool = false
    @State private var keyToDelete: ServiceKey?
    @State private var showingDeleteKeyConfirmation: Bool = false
    @State private var serviceKeyError: String?

    // Calendar export/import
    @State private var isExportingCalendar: Bool = false
    @State private var isImportingCalendar: Bool = false
    @State private var calendarExportSuccess: String?
    @State private var calendarExportError: String?
    @State private var showingCalendarFilePicker: Bool = false
    @State private var calendarEventCount: Int = 0
    
    private let telegramService = TelegramBotService()
    private let defaultArchiveChunkSize = 10000
    private let minimumArchiveChunkSize = 5000
    private let defaultMaxContextTokens = 200000
    private let defaultTargetContextTokens = 70000
    private let defaultToolSpendLimitPerTurnUSD = 0.20
    private let minimumToolSpendLimitPerTurnUSD = 0.001
    
    private var activeArchiveChunkSize: Int {
        if let savedChunkSize = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let chunkValue = Int(savedChunkSize),
           chunkValue >= minimumArchiveChunkSize {
            return chunkValue
        }
        return defaultArchiveChunkSize
    }

    private var activeToolSpendLimitPerTurnUSD: Double {
        if let saved = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey),
           let value = Double(saved),
           value >= minimumToolSpendLimitPerTurnUSD {
            return value
        }
        return defaultToolSpendLimitPerTurnUSD
    }

    private var trimmedNewKeyLabel: String {
        newKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var derivedInternalName: String {
        ServiceKey.normalizeName(from: trimmedNewKeyLabel)
    }

    private var isNewServiceKeyNameValid: Bool {
        !trimmedNewKeyLabel.isEmpty && !derivedInternalName.isEmpty
    }

    private var newServiceKeyNameExists: Bool {
        serviceKeys.contains { $0.name == derivedInternalName }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Persistent header with Start Agent
            HStack {
                if showingSaveConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Saved & started!")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .transition(.opacity)
                }

                if let error = conversationManager.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("Start Agent") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!isFormValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            switch section {
            case .identity:
                identityTab
            case .telegram:
                telegramTab
            case .llmProvider:
                llmProviderTab
            case .services:
                servicesTab
            case .data:
                dataTab
            default:
                EmptyView()
            }
        }
        .onAppear {
            loadSettings()
            structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
            structuredContextDraft = structuredUserContext
            Task {
                if voiceTranscriptionProvider == .local {
                    await WhisperKitService.shared.checkModelStatus()
                }
                calendarEventCount = await CalendarService.shared.totalEventCount()
            }
        }
        .alert("Restore Mind Backup?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
            Button("Restore", role: .destructive) {
                if let url = pendingImportURL {
                    importMind(from: url)
                }
            }
        } message: {
            Text("This will replace ALL current data (conversation, chunks, files, reminders, calendar, contacts, persona) with the backup. API keys are not affected. This cannot be undone.")
        }
        .alert("Delete All Memory?", isPresented: $showingDeleteMemoryConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await conversationManager.deleteAllMemory() }
            }
        } message: {
            Text("This permanently deletes all conversation history, chunks, summaries, user context, and reminders. Calendar and contacts are preserved. This cannot be undone.")
        }
    }

    // MARK: - Identity Tab

    private var identityTab: some View {
        Form {
            if !conversationManager.isPrivacyModeEnabled {
                Section {
                    personaSettingsContent
                } header: {
                    Label("Persona", systemImage: "person.text.rectangle")
                }
            } else {
                Section {
                    Text("Persona settings are hidden while privacy mode is active. Send /show in Telegram to re-enable.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Label("Persona", systemImage: "person.text.rectangle")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onChange(of: assistantName) { _ in autoSave { savePersonaSection() } }
        .onChange(of: userName) { _ in autoSave { savePersonaSection() } }
        .onChange(of: structuredUserContext) { newValue in
            if !isEditingStructuredContext {
                structuredContextDraft = newValue
            }
        }
    }

    // MARK: - Telegram Tab

    private var telegramTab: some View {
        Form {
            Section {
                SecureField("Bot Token", text: $telegramToken)
                    .textFieldStyle(.roundedBorder)

                TextField("Chat ID", text: $chatId)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Get this from @BotFather on Telegram")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Test") {
                        testConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(telegramToken.isEmpty || isTesting)
                }

                Text("Your Telegram user ID. Send /start to @userinfobot to get it.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isTesting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Testing connection...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let info = botInfo {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(info)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if let error = testError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

            } header: {
                Label("Telegram Bot", systemImage: "paperplane.fill")
            }

            Section {
                voiceTranscriptionContent
            } header: {
                Label("Voice Transcription", systemImage: "waveform")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onChange(of: telegramToken) { _ in autoSave { saveTelegramSection() } }
        .onChange(of: chatId) { _ in autoSave { saveTelegramSection() } }
        .onChange(of: voiceTranscriptionProvider) { _ in
            autoSave { saveVoiceTranscriptionSection() }
            if voiceTranscriptionProvider == .local {
                Task {
                    await WhisperKitService.shared.checkModelStatus()
                }
            }
        }
        .onChange(of: openAITranscriptionApiKey) { _ in autoSave { saveVoiceTranscriptionSection() } }
    }

    // MARK: - LLM Provider Tab

    private var llmProviderTab: some View {
        Form {
            Section {
                Picker("LLM Provider", selection: $llmProvider) {
                    Text("Local Inference").tag("lmstudio")
                    Text("OpenRouter").tag("openrouter")
                }
                .pickerStyle(.segmented)

                if llmProvider == "lmstudio" {
                    Picker("Server", selection: Binding(
                        get: { localServerPreset(from: lmStudioBaseURL) },
                        set: { preset in
                            if let url = localServerPresetURL(preset) { lmStudioBaseURL = url }
                        }
                    )) {
                        Text("LM Studio").tag("lmstudio")
                        Text("Ollama").tag("ollama")
                        Text("vLLM").tag("vllm")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)

                    TextField("Base URL", text: $lmStudioBaseURL)
                        .textFieldStyle(.roundedBorder)

                    Text("The OpenAI-compatible API endpoint. Any provider that implements /v1/chat/completions works.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Model Name", text: $lmStudioModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Recommended: Gemma 4 26B or Gemma 4 31B — excellent reasoning and tool use. Use a multimodal model so the assistant can see images and documents.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Provider-specific caching notes
                    Group {
                        let preset = localServerPreset(from: lmStudioBaseURL)
                        if preset == "vllm" {
                            Text("⚠️ vLLM: prefix caching is OFF by default. Start vLLM with --enable-prefix-caching for our architecture to benefit from cache reuse.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else if preset == "custom" {
                            Text("Prompt caching depends on your server. Most llama.cpp-based servers cache automatically. vLLM needs --enable-prefix-caching. MLX-based servers only cache for full-attention models (not sliding window / Mamba).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Prompt processing is cached automatically via the server's KV cache when message prefixes stay stable (which they do during agentic tool loops).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    DisclosureGroup("Description Model", isExpanded: $isDescriptionModelExpanded) {
                        TextField("Description Model", text: $lmStudioDescriptionModel)
                            .textFieldStyle(.roundedBorder)

                        Text("A separate multimodal model for generating file descriptions at pruning time. Use a faster model here to speed up the process.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("Description Base URL (optional)", text: $lmStudioDescriptionBaseURL)
                            .textFieldStyle(.roundedBorder)

                        Text("If the description model runs on a different port. Leave empty to use the same server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                SecureField("OpenRouter API Key", text: $openRouterApiKey)
                    .textFieldStyle(.roundedBorder)

                if llmProvider == "lmstudio" {
                    Text("OpenRouter API key is still needed for web search and deep research. Your conversation data is not sent to OpenRouter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Get your API key from openrouter.ai")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if llmProvider == "openrouter" {
                    TextField("Model", text: $openRouterModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Default: google/gemini-3-flash-preview")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Allowed Providers", text: $openRouterProviders)
                        .textFieldStyle(.roundedBorder)

                    Text("Comma-separated list (e.g., google, anthropic). Only these providers will be used. Leave empty to allow all.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Reasoning Effort", selection: $openRouterReasoningEffort) {
                        Text("Not Specified").tag("")
                        Text("Minimal").tag("minimal")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.menu)

                    Text("Controls thinking depth for supported models (Gemini 3, o1/o3, Grok).")
                        .font(.caption)
                        .foregroundColor(.secondary)

                }

                DisclosureGroup("Spend Limits", isExpanded: $isSpendLimitsExpanded) {
                    HStack {
                        Text("Per Turn (USD)")
                        Spacer()
                        TextField(formatUSD(activeToolSpendLimitPerTurnUSD), text: $openRouterToolSpendLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Daily (USD)")
                        Spacer()
                        Text("Today: $\(formatUSD(openRouterTodaySpendUSD))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("none", text: $openRouterDailySpendLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Monthly (USD)")
                        Spacer()
                        Text("Month: $\(formatUSD(openRouterMonthSpendUSD))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("none", text: $openRouterMonthlySpendLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }

                    Text("Pauses tool usage when limits are reached. Leave blank for no cap. Min: 0.001.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            } header: {
                Label("LLM Provider", systemImage: "brain.head.profile")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onChange(of: llmProvider) { _ in
            autoSave { saveOpenRouterSection() }
            // Auto-toggle subagents: off for local inference, on for cloud
            UserDefaults.standard.set(llmProvider != "lmstudio", forKey: "localagent.subagentsEnabled")
        }
        .onChange(of: lmStudioBaseURL) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: lmStudioModel) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: lmStudioDescriptionModel) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: lmStudioDescriptionBaseURL) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterApiKey) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterModel) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterProviders) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterReasoningEffort) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterToolSpendLimit) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterDailySpendLimit) { _ in autoSave { saveOpenRouterSection() } }
        .onChange(of: openRouterMonthlySpendLimit) { _ in autoSave { saveOpenRouterSection() } }
    }

    // MARK: - Services Tab

    private var servicesTab: some View {
        Form {
            Section {
                SecureField("Serper API Key", text: $serperApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("For Google search. Get from serper.dev (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                SecureField("Jina API Key", text: $jinaApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("For web scraping. Get from jina.ai (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            } header: {
                Label("Web Search Tool", systemImage: "magnifyingglass")
            }

            // MARK: - Google Workspace Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gmail, Calendar, Contacts, and Drive are reached through the `gws` CLI. Install and authenticate it in a terminal — no credentials live in the app.")
                        .font(.callout)
                    Text("brew install gws")
                        .font(.system(.callout, design: .monospaced))
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Text("gws auth login --credentials /path/to/credentials.json")
                        .font(.system(.callout, design: .monospaced))
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Text("If the CLI is missing or unauthenticated, the ambient inbox/calendar blocks are silently skipped — the app stays usable.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Google Workspace (gws CLI)", systemImage: "envelope.fill")
            }

            Section {
                Text("API Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("Gemini API Key", text: $geminiApiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Image Model (optional)", text: $geminiImageModel)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                Text("Leave blank to use the default image model: \(GeminiImagePricing.defaultModel)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                DisclosureGroup("Pricing Overrides", isExpanded: $isImagePricingExpanded) {
                    HStack {
                        Text("Input $ / 1M tokens")
                        Spacer()
                        TextField(
                            KeychainHelper.defaultGeminiImageInputCostPerMillionTokensUSD,
                            text: $geminiImageInputCostPerMillionTokensUSD
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Output Text $ / 1M")
                        Spacer()
                        TextField(
                            KeychainHelper.defaultGeminiImageOutputTextCostPerMillionTokensUSD,
                            text: $geminiImageOutputTextCostPerMillionTokensUSD
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Output Image $ / 1M")
                        Spacer()
                        TextField(
                            KeychainHelper.defaultGeminiImageOutputImageCostPerMillionTokensUSD,
                            text: $geminiImageOutputImageCostPerMillionTokensUSD
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                    }

                    Text("Leave blank for default rates. Set custom pricing if using a different model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Link("Get your API key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
                
                Text("This key is strictly used for image generation tools. Headless Gemini CLI will use the credentials established in your terminal (Ultra subscription).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            } header: {
                Label("Image Generation (Gemini)", systemImage: "photo.badge.plus")
            }

            // MARK: - Service Keys
            Section {
                if serviceKeys.isEmpty && !showingAddKey {
                    Text("No service keys configured. Add API keys for external services (Vercel, Supabase, OpenAI, etc.). The agent can use them in bash commands without ever seeing the secret values.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(serviceKeys) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.label)
                                    .font(.body)
                                if !key.description.isEmpty {
                                    Text(key.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text("••••••••")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(role: .destructive) {
                                keyToDelete = key
                                showingDeleteKeyConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if showingAddKey {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name (e.g. Vercel Token, Supabase API Key)", text: $newKeyName)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .onChange(of: newKeyName) { _ in
                                serviceKeyError = nil
                            }

                        if isNewServiceKeyNameValid {
                            Text("Internal key: \(derivedInternalName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        TextField("Description (optional)", text: $newKeyDescription)
                            .textFieldStyle(.roundedBorder)

                        SecureField("Secret value", text: $newKeyValue)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Cancel") {
                                newKeyName = ""
                                newKeyValue = ""
                                newKeyDescription = ""
                                serviceKeyError = nil
                                showingAddKey = false
                            }
                            Spacer()
                            Button("Save") {
                                saveNewServiceKey()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isNewServiceKeyNameValid || newKeyValue.isEmpty || newServiceKeyNameExists)
                        }

                        if newServiceKeyNameExists {
                            Text("A key with this name already exists.")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        if let serviceKeyError {
                            Text(serviceKeyError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        serviceKeyError = nil
                        showingAddKey = true
                    } label: {
                        Label("Add Key", systemImage: "plus.circle")
                    }
                }

                Text("Keys are stored in the macOS Keychain. The agent injects them per-command via `service_key_env` — only the requested key is exposed to each subprocess.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Service Keys", systemImage: "key.fill")
            }

        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onAppear { serviceKeys = KeychainHelper.loadServiceKeys() }
        .onChange(of: serperApiKey) { _ in autoSave { saveWebSearchSection() } }
        .onChange(of: jinaApiKey) { _ in autoSave { saveWebSearchSection() } }
        .onChange(of: geminiApiKey) { _ in autoSave { saveImageGenSection() } }
        .onChange(of: geminiImageModel) { _ in autoSave { saveImageGenSection() } }
        .onChange(of: geminiImageInputCostPerMillionTokensUSD) { _ in autoSave { saveImageGenSection() } }
        .onChange(of: geminiImageOutputTextCostPerMillionTokensUSD) { _ in autoSave { saveImageGenSection() } }
        .onChange(of: geminiImageOutputImageCostPerMillionTokensUSD) { _ in autoSave { saveImageGenSection() } }
        .alert("Delete Service Key?", isPresented: $showingDeleteKeyConfirmation) {
            Button("Cancel", role: .cancel) { keyToDelete = nil }
            Button("Delete", role: .destructive) {
                if let key = keyToDelete {
                    deleteServiceKey(key)
                }
                keyToDelete = nil
            }
        } message: {
            if let key = keyToDelete {
                Text("Remove \(key.name)? The secret will be deleted from the Keychain.")
            }
        }
    }

    // MARK: - Data Tab

    private var dataTab: some View {
        Form {
            Section {
                Button {
                    showingContextViewer = true
                } label: {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundColor(.purple)
                        Text("View Gemini Context")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(conversationManager.isPrivacyModeEnabled)
                
                Text(
                    conversationManager.isPrivacyModeEnabled
                        ? "Context viewer is disabled while privacy mode is active. Send `/show` in Telegram to re-enable it."
                        : "See all context currently being sent to Gemini: conversation, chunks, user context, calendar, and email."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                HStack {
                    Text("Archive Chunk Size")
                    Spacer()
                    TextField("\(activeArchiveChunkSize)", text: $archiveChunkSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            saveArchiveChunkSize()
                        }
                    Text("tokens")
                        .foregroundColor(.secondary)
                    if showingChunkSizeSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }
                
                Text("Size of each memory chunk. Archival triggers at 2× this value. Consolidation merges 4 chunks. Min: 5,000. If left empty, the default value is used. Changes apply to new chunks only.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Max Context Tokens")
                    Spacer()
                    TextField("\(defaultMaxContextTokens)", text: $maxContextTokens)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    Text("tokens")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Prune Target Tokens")
                    Spacer()
                    TextField("\(defaultTargetContextTokens)", text: $targetContextTokens)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    if showingContextBudgetSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }

                Button("Save Context Budget") {
                    saveContextBudget()
                }
                .buttonStyle(.bordered)

                Text("When the full context (system prompt + history + stored tool interactions) exceeds Max, tool interactions are pruned from oldest turns down to Target. This preserves prompt caching by keeping recent tool context intact. Min Max: 10,000. Min Target: 5,000.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            } header: {
                Label("Developer Tools", systemImage: "wrench.and.screwdriver")
            }
            
            // MARK: - Data Section
            Section {
                // MARK: Data Portability
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Portability")
                        .font(.body)
                    Text("Export or restore your entire assistant memory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 12) {
                    Button {
                        exportMind()
                    } label: {
                        HStack {
                            if isExportingMind {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.doc")
                            }
                            Text("Download Mind")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isExportingMind ||
                        isImportingMind ||
                        conversationManager.isPrivacyModeEnabled
                    )
                    
                    Button {
                        print("[SettingsView] Restore Mind button tapped, opening NSOpenPanel")
                        Task {
                            let openPanel = NSOpenPanel()
                            openPanel.allowedContentTypes = [.item]
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = false
                            openPanel.title = "Select Mind Backup"
                            openPanel.message = "Choose a .mind file to restore"
                            
                            let response = await openPanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
                            
                            guard response == .OK, let url = openPanel.url else {
                                return
                            }
                            
                            // Copy to temp location
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.removeItem(at: tempURL)
                            do {
                                try FileManager.default.copyItem(at: url, to: tempURL)
                                await MainActor.run {
                                    pendingImportURL = tempURL
                                    showingRestoreConfirmation = true
                                }
                            } catch {
                                await MainActor.run {
                                    mindExportError = "Failed to read file: \(error.localizedDescription)"
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if isImportingMind {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up.doc")
                            }
                            Text("Restore Mind")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingMind || isImportingMind)
                }
                
                if let success = mindExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let error = mindExportError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Text(
                    conversationManager.isPrivacyModeEnabled
                        ? "Mind export is disabled while privacy mode is active. Send `/show` in Telegram to re-enable it."
                        : "Download Mind exports your conversation history, memory chunks, files, contacts, reminders, calendar, and persona settings. API keys are NOT included for security."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()

                // Calendar Export/Import
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar")
                        .font(.body)
                    Text("\(calendarEventCount) event\(calendarEventCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 12) {
                    Button(action: { exportCalendar() }) {
                        HStack {
                            if isExportingCalendar {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.doc")
                            }
                            Text("Download")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isExportingCalendar ||
                        isImportingCalendar ||
                        calendarEventCount == 0 ||
                        conversationManager.isPrivacyModeEnabled
                    )
                    
                    Button(action: { showingCalendarFilePicker = true }) {
                        HStack {
                            if isImportingCalendar {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up.doc")
                            }
                            Text("Upload")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingCalendar || isImportingCalendar)
                }
                
                if let success = calendarExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let error = calendarExportError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Text(
                    conversationManager.isPrivacyModeEnabled
                        ? "Calendar export is disabled while privacy mode is active. Send `/show` in Telegram to re-enable it."
                        : "Export or import your calendar events separately. The calendar is also included in Mind exports."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                Button {
                    showingDeleteMemoryConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Delete Memory")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                
                Text("Permanently deletes all conversation history, chunks, summaries, user context, and reminders. Calendar and contacts are preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Button {
                    UserDefaults.standard.set(true, forKey: "restart_onboarding_requested")
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.accentColor)
                        Text("Restart Onboarding")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Text("Reopens the guided setup wizard on next app launch. Your existing settings are preserved — fields will be pre-filled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Data", systemImage: "externaldrive.fill")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onChange(of: conversationManager.isPrivacyModeEnabled) { _, isEnabled in
            if isEnabled {
                showingContextViewer = false
            }
        }
        .sheet(isPresented: $showingContextViewer) {
            ContextViewerView()
                .environmentObject(conversationManager)
        }
        .fileImporter(
            isPresented: $showingMindFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    mindExportError = "Unable to access file"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    pendingImportURL = tempURL
                    showingRestoreConfirmation = true
                } catch {
                    mindExportError = "Failed to read file: \(error.localizedDescription)"
                }

            case .failure(let error):
                mindExportError = "Failed to select file: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showingCalendarFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    calendarExportError = "Unable to access file"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                importCalendar(from: url)

            case .failure(let error):
                calendarExportError = "Failed to select file: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Voice Transcription Content
    
    @ViewBuilder
    private var voiceTranscriptionContent: some View {
        let whisper = WhisperKitService.shared

        Picker("Method", selection: $voiceTranscriptionProvider) {
            ForEach(VoiceTranscriptionProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.menu)

        if voiceTranscriptionProvider == .openAI {
            SecureField("OpenAI API Key", text: $openAITranscriptionApiKey)
                .textFieldStyle(.roundedBorder)

            Text("Used for `gpt-4o-transcribe`. Your key is stored in macOS Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            HStack {
                Group {
                    if whisper.isModelReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if whisper.isDownloading || whisper.isCompiling || whisper.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper Model")
                        .font(.body)
                    Text(whisper.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !whisper.hasModelOnDisk && !whisper.isDownloading {
                    Button("Download") {
                        Task {
                            await whisper.startDownload()
                        }
                    }
                    .buttonStyle(.bordered)
                } else if whisper.hasModelOnDisk && !whisper.isModelReady && !whisper.isCompiling && !whisper.isLoading {
                    Button("Compile") {
                        Task {
                            await whisper.loadModel()
                        }
                    }
                    .buttonStyle(.bordered)
                } else if whisper.isModelReady {
                    Button("Delete") {
                        try? whisper.deleteModelFromDisk()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }

            if whisper.isDownloading {
                ProgressView(value: Double(whisper.downloadProgress))
                    .progressViewStyle(.linear)
            }
        }

        Text(voiceTranscriptionProvider == .local
             ? "Local Whisper runs on-device and remains the default."
             : "OpenAI transcribes voice messages using `gpt-4o-transcribe` and requires your OpenAI API key.")
            .font(.caption)
            .foregroundColor(.secondary)

    }
    
    // MARK: - Persona Settings Content
    
    @ViewBuilder
    private var personaSettingsContent: some View {
        TextField("Assistant Name", text: $assistantName)
            .textFieldStyle(.roundedBorder)
        
        Text("What should the AI call itself? (e.g., Jarvis, Friday)")
            .font(.caption)
            .foregroundColor(.secondary)
        
        TextField("Your Name", text: $userName)
            .textFieldStyle(.roundedBorder)
        
        Text("Your name for personalized responses")
            .font(.caption)
            .foregroundColor(.secondary)
        
        
        VStack(alignment: .leading, spacing: 4) {
            Text(structuredUserContext.isEmpty ? "About You" : "Update About You")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $userContext)
                .frame(height: 80)
                .font(.body)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        
        Text(structuredUserContext.isEmpty
             ? "Tell the AI about yourself: job, preferences, location, communication style, etc."
             : "Add new details or corrections here — they'll be merged into your existing structured context, not replace it.")
            .font(.caption)
            .foregroundColor(.secondary)
        
        HStack {
            Button("Process & Save") {
                structureUserContext()
            }
            .buttonStyle(.bordered)
            .disabled(userContext.isEmpty || openRouterApiKey.isEmpty || isStructuring)
            
            if !structuredUserContext.isEmpty {
                Button(isEditingStructuredContext ? "Editing..." : "Edit Context") {
                    beginStructuredContextEdit()
                }
                .buttonStyle(.bordered)
                .disabled(isEditingStructuredContext)

                Button("Delete Context") {
                    showingDeleteContextConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
            
            if isStructuring {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .alert("Delete Context About You?", isPresented: $showingDeleteContextConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                structuredUserContext = ""
                structuredContextDraft = ""
                userContext = ""
                isEditingStructuredContext = false
                try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "")
                try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "")
            }
        } message: {
            Text("This will delete your structured context so you can start fresh. This cannot be undone.")
        }
        
        if let error = structuringError {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        
        if !structuredUserContext.isEmpty {
            DisclosureGroup(isExpanded: $isStructuredContextExpanded) {
                if isEditingStructuredContext {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $structuredContextDraft)
                            .frame(minHeight: 140)
                            .font(.body)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        HStack {
                            Button("Save Changes") {
                                saveStructuredContextEdits()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(structuredContextDraft == structuredUserContext)

                            Button("Cancel") {
                                cancelStructuredContextEdit()
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                    }
                } else {
                    Text(structuredUserContext)
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(5)
                }
            } label: {
                Text("User Context (used in prompts):")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var isFormValid: Bool {
        !telegramToken.isEmpty && !chatId.isEmpty && !openRouterApiKey.isEmpty
    }

    private func normalizedToolSpendLimitValue(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let parsed = Double(normalized),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return formatUSD(defaultToolSpendLimitPerTurnUSD)
        }
        return formatUSD(parsed)
    }

    private func normalizedOptionalSpendLimitValue(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard let parsed = Double(normalized),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return formatUSD(parsed)
    }

    // MARK: - Local Server Presets

    private func localServerPreset(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed.contains(":1234") { return "lmstudio" }
        if trimmed.contains(":11434") { return "ollama" }
        if trimmed.contains(":8000") { return "vllm" }
        return "custom"
    }

    private func localServerPresetURL(_ preset: String) -> String? {
        switch preset {
        case "lmstudio": return "http://localhost:1234/v1"
        case "ollama": return "http://localhost:11434/v1"
        case "vllm": return "http://localhost:8000/v1"
        default: return nil // custom — don't overwrite
        }
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

    private func normalizedOptionalRateValue(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard let parsed = Double(normalized),
              parsed.isFinite,
              parsed >= 0 else {
            return nil
        }
        return formatUSD(parsed)
    }

    private func configuredGeminiImageModelValue() -> String {
        let normalizedModel = geminiImageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedModel.isEmpty ? GeminiImagePricing.defaultModel : normalizedModel
    }

    private func configuredGeminiImagePricingValue() -> GeminiImagePricing {
        func parsedRate(_ rawValue: String, defaultValue: Double) -> Double {
            guard let normalized = normalizedOptionalRateValue(rawValue),
                  let parsed = Double(normalized) else {
                return defaultValue
            }
            return parsed
        }

        return GeminiImagePricing(
            inputCostPerMillionTokensUSD: parsedRate(
                geminiImageInputCostPerMillionTokensUSD,
                defaultValue: GeminiImagePricing.default.inputCostPerMillionTokensUSD
            ),
            outputTextCostPerMillionTokensUSD: parsedRate(
                geminiImageOutputTextCostPerMillionTokensUSD,
                defaultValue: GeminiImagePricing.default.outputTextCostPerMillionTokensUSD
            ),
            outputImageCostPerMillionTokensUSD: parsedRate(
                geminiImageOutputImageCostPerMillionTokensUSD,
                defaultValue: GeminiImagePricing.default.outputImageCostPerMillionTokensUSD
            )
        )
    }

    private func refreshGeminiImageServiceConfiguration() {
        let normalizedAPIKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else { return }

        let model = configuredGeminiImageModelValue()
        let pricing = configuredGeminiImagePricingValue()
        Task {
            await GeminiImageService.shared.configure(
                apiKey: normalizedAPIKey,
                model: model,
                pricing: pricing
            )
        }
    }

    private func refreshOpenRouterSpendCounters() {
        let snapshot = KeychainHelper.openRouterSpendSnapshot(referenceDate: Date())
        openRouterTodaySpendUSD = snapshot.today
        openRouterMonthSpendUSD = snapshot.month
    }
    
    private func loadSettings() {
        telegramToken = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? ""
        chatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        llmProvider = KeychainHelper.load(key: KeychainHelper.llmProviderKey) ?? "lmstudio"
        lmStudioBaseURL = KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey) ?? ""
        lmStudioModel = KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? ""
        lmStudioDescriptionModel = KeychainHelper.load(key: KeychainHelper.lmStudioDescriptionModelKey) ?? ""
        lmStudioDescriptionBaseURL = KeychainHelper.load(key: KeychainHelper.lmStudioDescriptionBaseURLKey) ?? ""
        openRouterApiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        openRouterModel = KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? ""
        openRouterProviders = KeychainHelper.load(key: KeychainHelper.openRouterProvidersKey) ?? ""
        openRouterReasoningEffort = KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey) ?? "high"
        if let savedSpendLimit = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey),
           let parsed = Double(savedSpendLimit),
           parsed >= minimumToolSpendLimitPerTurnUSD,
           abs(parsed - defaultToolSpendLimitPerTurnUSD) > 0.000_000_1 {
            openRouterToolSpendLimit = formatUSD(parsed)
        } else {
            openRouterToolSpendLimit = ""
        }
        if let dailyLimit = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey),
           let parsed = Double(dailyLimit),
           parsed >= minimumToolSpendLimitPerTurnUSD {
            openRouterDailySpendLimit = formatUSD(parsed)
        } else {
            openRouterDailySpendLimit = ""
        }
        if let monthlyLimit = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey),
           let parsed = Double(monthlyLimit),
           parsed >= minimumToolSpendLimitPerTurnUSD {
            openRouterMonthlySpendLimit = formatUSD(parsed)
        } else {
            openRouterMonthlySpendLimit = ""
        }
        refreshOpenRouterSpendCounters()
        serperApiKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        jinaApiKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        
        // Gmail / Contacts settings removed — Google Workspace is now reached
        // through the gws CLI, configured outside the app.


        // Load image generation settings
        geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey) ?? ""
        geminiImageModel = KeychainHelper.load(key: KeychainHelper.geminiImageModelKey) ?? KeychainHelper.defaultGeminiImageModel
        geminiImageInputCostPerMillionTokensUSD = KeychainHelper.load(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey) ?? ""
        geminiImageOutputTextCostPerMillionTokensUSD = KeychainHelper.load(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey) ?? ""
        geminiImageOutputImageCostPerMillionTokensUSD = KeychainHelper.load(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey) ?? ""

        // Load voice transcription settings
        voiceTranscriptionProvider = VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )
        openAITranscriptionApiKey = KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? ""
        
        // Load persona settings
        assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        userContext = KeychainHelper.load(key: KeychainHelper.userContextKey) ?? ""
        structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        structuredContextDraft = structuredUserContext
        
        // Load archive settings (show custom value only; default stays as placeholder)
        if let savedChunkSize = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let chunkValue = Int(savedChunkSize),
           chunkValue >= minimumArchiveChunkSize,
           chunkValue != defaultArchiveChunkSize {
            archiveChunkSize = savedChunkSize
        } else {
            archiveChunkSize = ""
        }

        // Load context budget settings
        if let saved = KeychainHelper.load(key: KeychainHelper.maxContextTokensKey),
           let val = Int(saved), val >= 10000, val != defaultMaxContextTokens {
            maxContextTokens = saved
        } else {
            maxContextTokens = ""
        }
        if let saved = KeychainHelper.load(key: KeychainHelper.targetContextTokensKey),
           let val = Int(saved), val >= 5000, val != defaultTargetContextTokens {
            targetContextTokens = saved
        } else {
            targetContextTokens = ""
        }
    }
    
    private func testConnection() {
        isTesting = true
        botInfo = nil
        testError = nil
        
        Task {
            do {
                let info = try await telegramService.getMe(token: telegramToken)
                await MainActor.run {
                    botInfo = "Connected to @\(info.username ?? info.firstName)"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testError = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
    
    private func saveSettings() {
        do {
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: telegramToken)
            try KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: chatId)
            try KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: openRouterApiKey)
            if !serperApiKey.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperApiKey)
            }
            if !jinaApiKey.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: jinaApiKey)
            }
            if !openRouterModel.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: openRouterModel)
            } else {
                // Clear the saved model if user empties the field to revert to default
                try? KeychainHelper.delete(key: KeychainHelper.openRouterModelKey)
            }
            if !openRouterProviders.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterProvidersKey, value: openRouterProviders)
            } else {
                try? KeychainHelper.delete(key: KeychainHelper.openRouterProvidersKey)
            }
            if !openRouterReasoningEffort.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterReasoningEffortKey, value: openRouterReasoningEffort)
            } else {
                try? KeychainHelper.delete(key: KeychainHelper.openRouterReasoningEffortKey)
            }
            let spendLimitToSave = normalizedToolSpendLimitValue(openRouterToolSpendLimit)
            try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: spendLimitToSave)
            openRouterToolSpendLimit = (Double(spendLimitToSave) == defaultToolSpendLimitPerTurnUSD) ? "" : spendLimitToSave
            if let dailyLimit = normalizedOptionalSpendLimitValue(openRouterDailySpendLimit) {
                try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: dailyLimit)
                openRouterDailySpendLimit = dailyLimit
            } else {
                openRouterDailySpendLimit = ""
                try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)
            }
            if let monthlyLimit = normalizedOptionalSpendLimitValue(openRouterMonthlySpendLimit) {
                try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey, value: monthlyLimit)
                openRouterMonthlySpendLimit = monthlyLimit
            } else {
                openRouterMonthlySpendLimit = ""
                try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey)
            }
            refreshOpenRouterSpendCounters()
            
            // Save image generation settings
            let normalizedGeminiAPIKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedGeminiAPIKey.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.geminiApiKeyKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: normalizedGeminiAPIKey)
            }
            geminiApiKey = normalizedGeminiAPIKey

            let normalizedGeminiImageModel = geminiImageModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedGeminiImageModel.isEmpty {
                geminiImageModel = ""
                try? KeychainHelper.delete(key: KeychainHelper.geminiImageModelKey)
            } else {
                geminiImageModel = normalizedGeminiImageModel
                try KeychainHelper.save(key: KeychainHelper.geminiImageModelKey, value: normalizedGeminiImageModel)
            }

            if let inputRate = normalizedOptionalRateValue(geminiImageInputCostPerMillionTokensUSD) {
                geminiImageInputCostPerMillionTokensUSD = inputRate
                try KeychainHelper.save(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey, value: inputRate)
            } else {
                geminiImageInputCostPerMillionTokensUSD = ""
                try? KeychainHelper.delete(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey)
            }

            if let outputTextRate = normalizedOptionalRateValue(geminiImageOutputTextCostPerMillionTokensUSD) {
                geminiImageOutputTextCostPerMillionTokensUSD = outputTextRate
                try KeychainHelper.save(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey, value: outputTextRate)
            } else {
                geminiImageOutputTextCostPerMillionTokensUSD = ""
                try? KeychainHelper.delete(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey)
            }

            if let outputImageRate = normalizedOptionalRateValue(geminiImageOutputImageCostPerMillionTokensUSD) {
                geminiImageOutputImageCostPerMillionTokensUSD = outputImageRate
                try KeychainHelper.save(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey, value: outputImageRate)
            } else {
                geminiImageOutputImageCostPerMillionTokensUSD = ""
                try? KeychainHelper.delete(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey)
            }

            refreshGeminiImageServiceConfiguration()

            // Save voice transcription settings
            let normalizedVoiceProvider = VoiceTranscriptionProvider.fromStoredValue(voiceTranscriptionProvider.rawValue)
            try KeychainHelper.save(
                key: KeychainHelper.voiceTranscriptionProviderKey,
                value: normalizedVoiceProvider.rawValue
            )
            voiceTranscriptionProvider = normalizedVoiceProvider

            let normalizedOpenAIKey = openAITranscriptionApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedOpenAIKey.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.openAITranscriptionApiKeyKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.openAITranscriptionApiKeyKey, value: normalizedOpenAIKey)
            }
            openAITranscriptionApiKey = normalizedOpenAIKey
            
            // Save persona settings
            try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
            try KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
            try KeychainHelper.save(key: KeychainHelper.userContextKey, value: userContext)
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: structuredUserContext)
            
            // Save archive settings (empty = default)
            let normalizedChunkSize = archiveChunkSize.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedChunkSize.isEmpty {
                archiveChunkSize = ""
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "\(defaultArchiveChunkSize)")
            } else if let chunkValue = Int(normalizedChunkSize), chunkValue >= minimumArchiveChunkSize {
                archiveChunkSize = normalizedChunkSize
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: normalizedChunkSize)
            } else {
                // Invalid value, reset to default
                archiveChunkSize = ""
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "\(defaultArchiveChunkSize)")
            }
            
            showingSaveConfirmation = true
            
            // Hide confirmation after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showingSaveConfirmation = false
            }
            
            // Configure and auto-start the bot
            Task {
                await conversationManager.configure()
                await conversationManager.startPolling()
            }
        } catch {
            conversationManager.error = "Failed to save settings: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Per-Section Save Functions
    
    @ViewBuilder
    private func sectionSaveButton(_ sectionId: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if savedSection == sectionId {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .transition(.opacity)
            } else {
                Button("Save") {
                    action()
                    withAnimation {
                        savedSection = sectionId
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            if savedSection == sectionId {
                                savedSection = nil
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
    
    /// Debounced auto-save: waits 0.5s after the last change before saving
    private func autoSave(_ save: @escaping () -> Void) {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func savePersonaSection() {
        try? KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
    }

    private func beginStructuredContextEdit() {
        structuredContextDraft = structuredUserContext
        isStructuredContextExpanded = true
        isEditingStructuredContext = true
        structuringError = nil
    }

    private func cancelStructuredContextEdit() {
        structuredContextDraft = structuredUserContext
        isEditingStructuredContext = false
    }

    private func saveStructuredContextEdits() {
        let maxContextCharacters = 20000
        var updatedContext = structuredContextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var wasTruncated = false

        if updatedContext.count > maxContextCharacters {
            updatedContext = String(updatedContext.prefix(maxContextCharacters))
            wasTruncated = true
        }

        do {
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: updatedContext)
            structuredUserContext = updatedContext
            structuredContextDraft = updatedContext
            isEditingStructuredContext = false
            structuringError = wasTruncated ? "Context exceeded 20,000 characters and was truncated." : nil
        } catch {
            structuringError = "Failed to save edited context: \(error.localizedDescription)"
        }
    }
    
    private func saveTelegramSection() {
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: telegramToken)
        try? KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: chatId)
    }
    
    private func saveOpenRouterSection() {
        // Save LLM provider selection
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: llmProvider)

        // Save LMStudio settings
        let trimmedBaseURL = lmStudioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBaseURL.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.lmStudioBaseURLKey, value: trimmedBaseURL)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioBaseURLKey)
        }
        let trimmedLMModel = lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLMModel.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.lmStudioModelKey, value: trimmedLMModel)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioModelKey)
        }
        let trimmedDescModel = lmStudioDescriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescModel.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionModelKey, value: trimmedDescModel)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionModelKey)
        }
        let trimmedDescURL = lmStudioDescriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescURL.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionBaseURLKey, value: trimmedDescURL)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.lmStudioDescriptionBaseURLKey)
        }
        // Save OpenRouter settings (always needed for web search)
        try? KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: openRouterApiKey)
        if !openRouterModel.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: openRouterModel)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterModelKey)
        }
        if !openRouterProviders.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterProvidersKey, value: openRouterProviders)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterProvidersKey)
        }
        if !openRouterReasoningEffort.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterReasoningEffortKey, value: openRouterReasoningEffort)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterReasoningEffortKey)
        }
        let spendLimitToSave = normalizedToolSpendLimitValue(openRouterToolSpendLimit)
        try? KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, value: spendLimitToSave)
        openRouterToolSpendLimit = (Double(spendLimitToSave) == defaultToolSpendLimitPerTurnUSD) ? "" : spendLimitToSave
        if let dailyLimit = normalizedOptionalSpendLimitValue(openRouterDailySpendLimit) {
            try? KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: dailyLimit)
            openRouterDailySpendLimit = dailyLimit
        } else {
            openRouterDailySpendLimit = ""
            try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)
        }
        if let monthlyLimit = normalizedOptionalSpendLimitValue(openRouterMonthlySpendLimit) {
            try? KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey, value: monthlyLimit)
            openRouterMonthlySpendLimit = monthlyLimit
        } else {
            openRouterMonthlySpendLimit = ""
            try? KeychainHelper.delete(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey)
        }
        refreshOpenRouterSpendCounters()
    }
    
    private func saveWebSearchSection() {
        if !serperApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperApiKey)
        }
        if !jinaApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: jinaApiKey)
        }
    }
    
    private func saveImageGenSection() {
        let normalizedGeminiAPIKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedGeminiAPIKey.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.geminiApiKeyKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: normalizedGeminiAPIKey)
        }
        geminiApiKey = normalizedGeminiAPIKey

        let normalizedGeminiImageModel = geminiImageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedGeminiImageModel.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.geminiImageModelKey)
            geminiImageModel = ""
        } else {
            try? KeychainHelper.save(key: KeychainHelper.geminiImageModelKey, value: normalizedGeminiImageModel)
            geminiImageModel = normalizedGeminiImageModel
        }

        if let inputRate = normalizedOptionalRateValue(geminiImageInputCostPerMillionTokensUSD) {
            try? KeychainHelper.save(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey, value: inputRate)
            geminiImageInputCostPerMillionTokensUSD = inputRate
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey)
            geminiImageInputCostPerMillionTokensUSD = ""
        }

        if let outputTextRate = normalizedOptionalRateValue(geminiImageOutputTextCostPerMillionTokensUSD) {
            try? KeychainHelper.save(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey, value: outputTextRate)
            geminiImageOutputTextCostPerMillionTokensUSD = outputTextRate
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey)
            geminiImageOutputTextCostPerMillionTokensUSD = ""
        }

        if let outputImageRate = normalizedOptionalRateValue(geminiImageOutputImageCostPerMillionTokensUSD) {
            try? KeychainHelper.save(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey, value: outputImageRate)
            geminiImageOutputImageCostPerMillionTokensUSD = outputImageRate
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey)
            geminiImageOutputImageCostPerMillionTokensUSD = ""
        }

        refreshGeminiImageServiceConfiguration()
    }

    private func saveVoiceTranscriptionSection() {
        let normalizedProvider = VoiceTranscriptionProvider.fromStoredValue(voiceTranscriptionProvider.rawValue)
        try? KeychainHelper.save(
            key: KeychainHelper.voiceTranscriptionProviderKey,
            value: normalizedProvider.rawValue
        )
        voiceTranscriptionProvider = normalizedProvider

        let normalizedOpenAIKey = openAITranscriptionApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedOpenAIKey.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.openAITranscriptionApiKeyKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.openAITranscriptionApiKeyKey, value: normalizedOpenAIKey)
        }
        openAITranscriptionApiKey = normalizedOpenAIKey

        if voiceTranscriptionProvider == .local {
            Task {
                await WhisperKitService.shared.checkModelStatus()
            }
        }
    }
    
    private func saveNewServiceKey() {
        let label = trimmedNewKeyLabel
        let internalName = derivedInternalName
        let value = newKeyValue
        let desc = newKeyDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNewServiceKeyNameValid, !value.isEmpty, !newServiceKeyNameExists else { return }

        do {
            try KeychainHelper.saveServiceKeyValue(name: internalName, value: value)

            let entry = ServiceKey(name: internalName, label: label, description: desc)
            serviceKeys.append(entry)
            KeychainHelper.saveServiceKeys(serviceKeys)

            newKeyName = ""
            newKeyValue = ""
            newKeyDescription = ""
            serviceKeyError = nil
            showingAddKey = false
        } catch {
            serviceKeyError = "Could not save key to Keychain: \(error.localizedDescription)"
        }
    }

    private func deleteServiceKey(_ key: ServiceKey) {
        KeychainHelper.deleteServiceKeyValue(name: key.name)
        serviceKeys.removeAll { $0.name == key.name }
        KeychainHelper.saveServiceKeys(serviceKeys)
    }

    private func saveArchiveChunkSize() {
        // Validate and save archive chunk size (empty = default)
        let normalizedChunkSize = archiveChunkSize.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let valueToSave: String
        if normalizedChunkSize.isEmpty {
            archiveChunkSize = ""
            valueToSave = "\(defaultArchiveChunkSize)"
        } else if let chunkValue = Int(normalizedChunkSize), chunkValue >= minimumArchiveChunkSize {
            archiveChunkSize = normalizedChunkSize
            valueToSave = normalizedChunkSize
        } else {
            // Invalid value, reset to default
            archiveChunkSize = ""
            valueToSave = "\(defaultArchiveChunkSize)"
        }
        
        do {
            try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: valueToSave)
            withAnimation {
                showingChunkSizeSaved = true
            }
            // Hide checkmark after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showingChunkSizeSaved = false
                }
            }
        } catch {
            conversationManager.error = "Failed to save chunk size: \(error.localizedDescription)"
        }
    }

    private func saveContextBudget() {
        let rawMax = maxContextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTarget = targetContextTokens.trimmingCharacters(in: .whitespacesAndNewlines)

        let maxVal: String
        if rawMax.isEmpty {
            maxContextTokens = ""
            maxVal = "\(defaultMaxContextTokens)"
        } else if let v = Int(rawMax), v >= 10000 {
            maxContextTokens = rawMax
            maxVal = rawMax
        } else {
            maxContextTokens = ""
            maxVal = "\(defaultMaxContextTokens)"
        }

        let targetVal: String
        if rawTarget.isEmpty {
            targetContextTokens = ""
            targetVal = "\(defaultTargetContextTokens)"
        } else if let v = Int(rawTarget), v >= 5000 {
            targetContextTokens = rawTarget
            targetVal = rawTarget
        } else {
            targetContextTokens = ""
            targetVal = "\(defaultTargetContextTokens)"
        }

        do {
            try KeychainHelper.save(key: KeychainHelper.maxContextTokensKey, value: maxVal)
            try KeychainHelper.save(key: KeychainHelper.targetContextTokensKey, value: targetVal)
            withAnimation {
                showingContextBudgetSaved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showingContextBudgetSaved = false
                }
            }
        } catch {
            conversationManager.error = "Failed to save context budget: \(error.localizedDescription)"
        }
    }

    // MARK: - Mind Export/Import
    
    private func exportMind() {
        isExportingMind = true
        mindExportSuccess = nil
        mindExportError = nil
        
        Task {
            do {
                // Create save panel
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.data]
                savePanel.nameFieldStringValue = "LocalAgent_Mind.\(MindExportService.fileExtension)"
                savePanel.title = "Export Mind"
                savePanel.message = "Choose where to save your mind backup"
                
                let response = await savePanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
                
                guard response == .OK, let url = savePanel.url else {
                    await MainActor.run {
                        isExportingMind = false
                    }
                    return
                }
                
                try await MindExportService.shared.exportMind(to: url)
                
                await MainActor.run {
                    mindExportSuccess = "Mind exported successfully!"
                    isExportingMind = false
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        mindExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    mindExportError = "Export failed: \(error.localizedDescription)"
                    isExportingMind = false
                }
            }
        }
    }
    
    private func importMind(from url: URL) {
        isImportingMind = true
        mindExportSuccess = nil
        mindExportError = nil
        pendingImportURL = nil
        
        Task {
            do {
                try await MindExportService.shared.importMind(from: url)
                
                // Reload conversation and archives to pick up restored data
                await conversationManager.reloadAfterMindRestore()
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: url)
                
                await MainActor.run {
                    mindExportSuccess = "Mind restored successfully!"
                    isImportingMind = false
                    
                    // Refresh persona settings after import
                    assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
                    userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
                    userContext = KeychainHelper.load(key: KeychainHelper.userContextKey) ?? ""
                    structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
                    structuredContextDraft = structuredUserContext
                    isEditingStructuredContext = false
                }
            } catch {
                // Clean up temp file
                try? FileManager.default.removeItem(at: url)
                
                await MainActor.run {
                    mindExportError = "Import failed: \(error.localizedDescription)"
                    isImportingMind = false
                }
            }
        }
    }
    
    // MARK: - Calendar Export/Import
    
    private func exportCalendar() {
        isExportingCalendar = true
        calendarExportSuccess = nil
        calendarExportError = nil
        
        Task {
            // Get calendar data
            guard let calendarData = await CalendarService.shared.getEventsData() else {
                await MainActor.run {
                    calendarExportError = "Failed to export calendar data"
                    isExportingCalendar = false
                }
                return
            }
            
            // Create save panel
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "LocalAgent_Calendar.json"
            savePanel.title = "Export Calendar"
            savePanel.message = "Choose where to save your calendar backup"
            
            let response = await savePanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
            
            guard response == .OK, let url = savePanel.url else {
                await MainActor.run {
                    isExportingCalendar = false
                }
                return
            }
            
            do {
                try calendarData.write(to: url)
                
                await MainActor.run {
                    calendarExportSuccess = "Calendar exported successfully!"
                    isExportingCalendar = false
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        calendarExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    calendarExportError = "Export failed: \(error.localizedDescription)"
                    isExportingCalendar = false
                }
            }
        }
    }
    
    private func importCalendar(from url: URL) {
        isImportingCalendar = true
        calendarExportSuccess = nil
        calendarExportError = nil
        
        Task {
            do {
                let data = try Data(contentsOf: url)
                try await CalendarService.shared.importEvents(from: data)
                
                await MainActor.run {
                    calendarExportSuccess = "Calendar imported successfully!"
                    isImportingCalendar = false
                    
                    // Refresh count
                    Task {
                        calendarEventCount = await CalendarService.shared.totalEventCount()
                    }
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        calendarExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    calendarExportError = "Import failed: \(error.localizedDescription)"
                    isImportingCalendar = false
                }
            }
        }
    }
    
    private func structureUserContext() {
        isStructuring = true
        structuringError = nil
        
        Task {
            do {
                let structured = try await structureWithAI(
                    assistantName: assistantName,
                    userName: userName,
                    rawContext: userContext
                )
                await MainActor.run {
                    structuredUserContext = structured
                    structuredContextDraft = structured
                    userContext = ""
                    isEditingStructuredContext = false
                    try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "")
                    try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: structured)
                    isStructuring = false
                }
            } catch {
                await MainActor.run {
                    structuringError = error.localizedDescription
                    isStructuring = false
                }
            }
        }
    }
    
    private func structureWithAI(assistantName: String, userName: String, rawContext: String) async throws -> String {
        let provider = LLMProvider.fromStoredValue(llmProvider)
        let trimmedOpenRouterAPIKey = openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        func configuredURL() -> URL {
            if provider == .lmStudio {
                var base = lmStudioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if base.isEmpty { base = KeychainHelper.defaultLMStudioBaseURL }
                while base.hasSuffix("/") { base.removeLast() }
                if base.hasSuffix("/chat/completions"), let url = URL(string: base) {
                    return url
                }
                if !base.hasSuffix("/v1") {
                    base += "/v1"
                }
                return URL(string: base + "/chat/completions")!
            }
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        }

        let configuredModel: String = {
            switch provider {
            case .lmStudio:
                return lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
            case .openRouter:
                let configured = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
                return configured.isEmpty ? "google/gemini-3-flash-preview" : configured
            }
        }()

        if provider == .lmStudio && configuredModel.isEmpty {
            throw NSError(
                domain: "StructureAI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "LMStudio model name is not configured"]
            )
        }

        if provider == .openRouter && trimmedOpenRouterAPIKey.isEmpty {
            throw NSError(
                domain: "StructureAI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key is not configured"]
            )
        }

        let configuredReasoningEffort: String? = {
            guard provider == .openRouter else { return nil }
            let stored = (KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? "high" : stored
        }()

        // Load existing structured context
        let existingContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        
        let prompt: String
        let maxChars = 20000
        let existingCharCount = existingContext.count
        let currentTokens = existingCharCount / 4
        let remainingTokens = (maxChars - existingCharCount) / 4
        
        if existingContext.isEmpty {
            // No existing context - structure from user input
            prompt = """
            You are helping configure an AI assistant. Based on the user's input, create a structured context.
            
            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using 0 tokens. You have ~5000 tokens available.
            
            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)
            Raw User Input: \(rawContext)
            
            Write ONLY the structured context, no explanations. It should:
            1. Establish the assistant's identity and name (if provided)
            2. Establish who the user is and their name (if provided)
            3. Prioritize durable profile information: relationship network (family, friends, frequent colleagues, nicknames, pets, homes), stable preferences, and communication style
            4. Be written in second person ("You are...")
            5. Organize by categories if there's enough information (Personal, Work, Preferences, etc.)
            6. Exclude contingent one-off details tied to a specific moment/situation
            7. Stay within the token limit - be concise but comprehensive
            """
        } else {
            // Existing context exists - Gemini decides how to handle the update
            prompt = """
            You are helping update an AI assistant's persistent memory about the user.
            
            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using ~\(currentTokens) tokens. You have ~\(remainingTokens) tokens remaining.
            
            EXISTING CONTEXT (current memory):
            ---
            \(existingContext)
            ---
            
            NEW USER INPUT:
            ---
            \(rawContext.isEmpty ? "(empty - user cleared the field)" : rawContext)
            ---
            
            Your task: Decide how to update the context intelligently.
            
            IMPORTANT RULES:
            - If the new input is EMPTY or just a few words, DO NOT delete the existing context. Keep it as-is or make minimal changes.
            - If the new input contains corrections (e.g., "birthday is actually April"), UPDATE the relevant parts.
            - If the new input adds new information, APPEND it to the appropriate section.
            - If the new input is a complete rewrite with substantial content, you may restructure entirely.
            - NEVER lose important information from the existing context unless explicitly told to remove it.
            - Keep only durable profile memory: relationship network (family, friends, frequent colleagues, nicknames, pets, homes), stable preferences, and communication style.
            - Remove or avoid contingent one-off details (situational comparisons, temporary opinions, single-instance choices).
            - Stay within the 5000 token limit. If space is tight, remove less important details.
            
            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)
            
            Output ONLY the final structured context (no explanations). Keep it organized and concise.
            """
        }
        
        let body: [String: Any] = [
            "model": configuredModel,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        var requestPayload = body
        if let configuredReasoningEffort {
            requestPayload["reasoning"] = ["effort": configuredReasoningEffort]
        }
        
        var request = URLRequest(url: configuredURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .lmStudio {
            request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 1200
        } else {
            request.setValue("Bearer \(trimmedOpenRouterAPIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("LocalAgent/1.0", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Telegram Concierge Bot", forHTTPHeaderField: "X-Title")
            request.timeoutInterval = 360
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "StructureAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "API request failed"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "StructureAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    SettingsView(section: .llmProvider)
        .environmentObject(ConversationManager())
}
