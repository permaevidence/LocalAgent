import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @Binding var isComplete: Bool

    @State private var step = 0
    private let totalRequiredSteps = 4 // 0=welcome, 1=LLM, 2=persona, 3=telegram
    private let totalOptionalSteps = 4 // 4=voice, 5=websearch, 6=email, 7=imagegen

    // LLM Provider
    @State private var llmProvider: String = "openrouter"
    @State private var openRouterApiKey: String = ""
    @State private var openRouterModel: String = ""
    @State private var lmStudioBaseURL: String = ""
    @State private var lmStudioModel: String = ""
    @State private var lmStudioDescriptionModel: String = ""
    @State private var lmStudioDescriptionBaseURL: String = ""

    // Persona
    @State private var assistantName: String = ""
    @State private var userName: String = ""
    @State private var userContext: String = ""

    // Telegram
    @State private var telegramToken: String = ""
    @State private var chatId: String = ""
    @State private var isTesting: Bool = false
    @State private var botInfo: String?
    @State private var testError: String?
    private let telegramService = TelegramBotService()

    // Voice
    @State private var voiceTranscriptionProvider: VoiceTranscriptionProvider = .openAI
    @State private var openAITranscriptionApiKey: String = ""

    // Web Search
    @State private var serperApiKey: String = ""
    @State private var jinaApiKey: String = ""

    // Google Workspace is configured outside the app via the `gws` CLI —
    // no in-app state to carry for this step.

    // Image Gen
    @State private var geminiApiKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                let progress = Double(step) / Double(totalRequiredSteps + totalOptionalSteps)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            .frame(height: 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: welcomeStep
                    case 1: llmProviderStep
                    case 2: personaStep
                    case 3: telegramStep
                    case 4: optionalGateStep
                    case 5: voiceStep
                    case 6: webSearchStep
                    case 7: emailStep
                    case 8: imageGenStep
                    default: doneStep
                    }
                }
                .padding(30)
            }

            Divider()

            // Navigation buttons
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }

                Spacer()

                if step == 4 {
                    // Optional gate — two buttons
                    Button("Skip, start agent") { finishOnboarding() }
                        .buttonStyle(.bordered)
                    Button("Continue setup") { step = 5 }
                        .buttonStyle(.borderedProminent)
                } else if step >= 5 && step <= 8 {
                    Button("Skip") { step += 1 }
                        .buttonStyle(.bordered)
                    Button("Next") {
                        saveCurrentStep()
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else if step == 9 {
                    Button("Start Agent") { finishOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else if step == 0 {
                    Button("Get Started") { step = 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Next") {
                        saveCurrentStep()
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isCurrentStepValid)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
        }
        .frame(width: 580, height: 620)
        .onAppear { loadExistingSettings() }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .center, spacing: 16) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Welcome to Telegram Concierge")
                .font(.title.bold())

            Text("Your personal AI assistant that lives inside Telegram. Let's set it up in a few steps.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var llmProviderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("LLM Provider", systemImage: "brain.head.profile")
                .font(.title2.bold())

            Text("Choose which AI model powers your assistant. Without this, nothing works.")
                .font(.callout)
                .foregroundColor(.secondary)

            Picker("Provider", selection: $llmProvider) {
                Text("OpenRouter (Cloud)").tag("openrouter")
                Text("Local Inference").tag("lmstudio")
            }
            .pickerStyle(.segmented)

            if llmProvider == "lmstudio" {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Server")
                            .font(.headline)

                        Picker("Server", selection: Binding(
                            get: { onboardingLocalPreset(from: lmStudioBaseURL) },
                            set: { preset in
                                if let url = onboardingLocalPresetURL(preset) { lmStudioBaseURL = url }
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
                        Text("Any OpenAI-compatible server works. Select a preset or enter a custom URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        TextField("Model Name", text: $lmStudioModel)
                            .textFieldStyle(.roundedBorder)
                        Text("Recommended: Gemma 4 26B or Gemma 4 31B — excellent reasoning and tool use. Use a multimodal model so the assistant can see images and documents.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Provider-specific caching note
                        Group {
                            let preset = onboardingLocalPreset(from: lmStudioBaseURL)
                            if preset == "vllm" {
                                Text("⚠️ vLLM: start with --enable-prefix-caching for prompt cache reuse.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else if preset == "custom" {
                                Text("Prompt caching depends on your server. llama.cpp-based servers cache automatically. vLLM needs --enable-prefix-caching. MLX only caches for full-attention models.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        TextField("Description Model (recommended)", text: $lmStudioDescriptionModel)
                            .textFieldStyle(.roundedBorder)
                        Text("A separate multimodal model for file descriptions (it needs to see images/PDFs), so the main model's KV cache isn't evicted. Highly recommended.")
                            .font(.caption)
                            .foregroundColor(.orange)

                        TextField("Description Base URL (optional)", text: $lmStudioDescriptionBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("If the description model runs on a different port.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("OpenRouter API Key", text: $openRouterApiKey)
                        .textFieldStyle(.roundedBorder)

                    if llmProvider == "lmstudio" {
                        Text("Still needed for web search and deep research. Your conversation data and chat history are NOT sent to OpenRouter when LM Studio is selected — only search queries.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("Get your key from openrouter.ai/keys")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if llmProvider == "openrouter" {
                        TextField("Model (optional)", text: $openRouterModel)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty for Gemini Flash. Or use google/gemini-3-flash-preview, anthropic/claude-sonnet-4, etc.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var personaStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Persona", systemImage: "person.text.rectangle")
                .font(.title2.bold())

            Text("Tell your assistant who it is and who you are.")
                .font(.callout)
                .foregroundColor(.secondary)

            TextField("Assistant Name", text: $assistantName)
                .textFieldStyle(.roundedBorder)
            Text("What you want to call your assistant.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Your Name", text: $userName)
                .textFieldStyle(.roundedBorder)

            Text("About You")
                .font(.headline)
            TextEditor(text: $userContext)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            Text("Describe yourself, your interests, and how you'd like the assistant to behave. This helps personalize responses. You can refine this later in Settings > Identity.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var telegramStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Telegram Bot", systemImage: "paperplane.fill")
                .font(.title2.bold())

            Text("Create a Telegram bot to be your assistant's interface.")
                .font(.callout)
                .foregroundColor(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to create your bot:")
                        .font(.headline)
                    Text("1. Open Telegram and search for @BotFather")
                    Text("2. Send /newbot and follow the prompts")
                    Text("3. Choose a name (e.g., \"My Concierge\") and a username (e.g., \"my_concierge_bot\")")
                    Text("4. BotFather will give you a token — paste it below")
                }
                .font(.callout)
            }

            SecureField("Bot Token", text: $telegramToken)
                .textFieldStyle(.roundedBorder)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get your Chat ID:")
                        .font(.headline)
                    Text("1. Search for @userinfobot on Telegram")
                    Text("2. Send /start — it replies with your user ID")
                    Text("3. Paste that number below")
                }
                .font(.callout)
            }

            TextField("Your Chat ID", text: $chatId)
                .textFieldStyle(.roundedBorder)

            if !telegramToken.isEmpty {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)

                    if isTesting {
                        ProgressView().scaleEffect(0.7)
                    }
                    if let info = botInfo {
                        Label(info, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    if let error = testError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    private var optionalGateStep: some View {
        VStack(alignment: .center, spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)

            Text("Core Setup Complete!")
                .font(.title2.bold())

            Text("Your assistant can now connect to Telegram and respond to messages. However, without the following services it won't be able to do much beyond basic conversation.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 6) {
                Label("Voice Transcription — understand your voice messages", systemImage: "waveform")
                Label("Web Search — search the internet and read web pages", systemImage: "magnifyingglass")
                Label("Google Workspace — Gmail, Calendar, Contacts, Drive via the gws CLI", systemImage: "envelope")
                Label("Image Generation — create and edit images", systemImage: "photo.badge.plus")
            }
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.horizontal, 20)

            Text("We strongly recommend continuing to set up at least a few of these.")
                .font(.callout.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Voice Transcription", systemImage: "waveform")
                .font(.title2.bold())

            Text("Transcribe voice messages you send via Telegram.")
                .font(.callout)
                .foregroundColor(.secondary)

            Picker("Method", selection: $voiceTranscriptionProvider) {
                ForEach(VoiceTranscriptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            if voiceTranscriptionProvider == .openAI {
                SecureField("OpenAI API Key", text: $openAITranscriptionApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used for gpt-4o-transcribe. Fast and accurate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Uses WhisperKit on-device. The model will be downloaded and compiled on first use (~1.5 GB). No API key needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var webSearchStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Web Search", systemImage: "magnifyingglass")
                .font(.title2.bold())

            Text("Your assistant has two powerful search tools: **Web Search** for quick lookups and **Deep Research** for comprehensive, multi-source analysis.")
                .font(.callout)
                .foregroundColor(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How it works:")
                        .font(.headline)
                    Text("The search tools autonomously query Google, read dozens of web pages, and synthesize the results. They use fast gpt-oss models running on Groq/Vertex for speed.")
                        .font(.callout)
                    Text("These tools are cloud-based (local search at this level isn't feasible), but they are completely segregated from your conversation — they only see the search query, never your chat history.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            SecureField("Serper API Key", text: $serperApiKey)
                .textFieldStyle(.roundedBorder)
            Text("Powers Google search queries. Free tier available at serper.dev")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("Jina API Key", text: $jinaApiKey)
                .textFieldStyle(.roundedBorder)
            Text("Reads and extracts text from web pages. Free tier available at jina.ai")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var emailStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Google Workspace (gws CLI)", systemImage: "envelope.fill")
                    .font(.title2.bold())

                Text("Your assistant talks to Gmail, Calendar, Contacts, and Drive through the official Google Workspace CLI (gws). One install gets you all of Google Workspace — the app itself just reads the CLI's output.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox(label: Text("1. Install gws").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Via Homebrew (recommended on macOS):")
                            .font(.callout)
                        Text("brew install gws")
                            .font(.system(.callout, design: .monospaced))
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        Text("Or see github.com/workspace-cli/gws for other install options.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("2. Create OAuth credentials").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Go to console.cloud.google.com")
                        Text("• Create a project (or reuse one) and enable these APIs: Gmail, Calendar, People (Contacts), Drive — plus any others you want (Docs, Sheets, Tasks, Keep).")
                        Text("• Create OAuth 2.0 credentials, type \"Desktop app\".")
                        Text("• Download the credentials JSON.")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("3. Authenticate").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In a terminal, run:")
                            .font(.callout)
                        Text("gws auth login --credentials /path/to/credentials.json")
                            .font(.system(.callout, design: .monospaced))
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        Text("The first run opens a browser for consent and grants the scopes for every service you want enabled. Tokens are kept in the macOS keychain under the gws entry.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("4. Verify").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick sanity checks — both should print JSON:")
                            .font(.callout)
                        Text("gws gmail +triage --query 'is:unread' --format json")
                            .font(.system(.callout, design: .monospaced))
                        Text("gws calendar +agenda --today --format json")
                            .font(.system(.callout, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Your assistant auto-discovers gws on next launch. If it's not installed or not authenticated, the system prompt silently skips the inbox/calendar blocks and the turn still works — you just won't have ambient awareness.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var imageGenStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Image Generation", systemImage: "photo.badge.plus")
                .font(.title2.bold())

            Text("Let your assistant generate and edit images using Gemini.")
                .font(.callout)
                .foregroundColor(.secondary)

            SecureField("Gemini API Key", text: $geminiApiKey)
                .textFieldStyle(.roundedBorder)

            Link("Get your key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                .font(.caption)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .center, spacing: 20) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("You're all set!")
                .font(.title.bold())

            Text("Your assistant is configured and ready. You can always adjust settings later via the Settings panel (Cmd+,) or restart this onboarding from Settings > Data.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Validation

    private var isCurrentStepValid: Bool {
        switch step {
        case 1: return !openRouterApiKey.isEmpty
        case 2: return true // persona is optional
        case 3: return !telegramToken.isEmpty && !chatId.isEmpty
        default: return true
        }
    }

    // MARK: - Save Logic

    private func saveCurrentStep() {
        switch step {
        case 1: saveLLMProvider()
        case 2: savePersona()
        case 3: saveTelegram()
        case 5: saveVoice()
        case 6: saveWebSearch()
        case 7: saveEmail()
        case 8: saveImageGen()
        default: break
        }
    }

    private func saveLLMProvider() {
        try? KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: llmProvider)
        try? KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: openRouterApiKey)
        if !openRouterModel.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: openRouterModel)
        }
        if llmProvider == "lmstudio" {
            let trimmedBase = lmStudioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBase.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.lmStudioBaseURLKey, value: trimmedBase)
            }
            let trimmedModel = lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.lmStudioModelKey, value: trimmedModel)
            }
            let trimmedDescModel = lmStudioDescriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDescModel.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionModelKey, value: trimmedDescModel)
            }
            let trimmedDescURL = lmStudioDescriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDescURL.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.lmStudioDescriptionBaseURLKey, value: trimmedDescURL)
            }
        }
    }

    private func savePersona() {
        try? KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
        if !userContext.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: userContext)
        }
    }

    private func saveTelegram() {
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: telegramToken)
        try? KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: chatId)
    }

    private func saveVoice() {
        try? KeychainHelper.save(key: KeychainHelper.voiceTranscriptionProviderKey, value: voiceTranscriptionProvider.rawValue)
        if voiceTranscriptionProvider == .openAI && !openAITranscriptionApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openAITranscriptionApiKeyKey, value: openAITranscriptionApiKey)
        }
    }

    private func saveWebSearch() {
        if !serperApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperApiKey)
        }
        if !jinaApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: jinaApiKey)
        }
    }

    private func saveEmail() {
        // Google Workspace is configured entirely outside the app — via the
        // `gws` CLI — so this step has nothing to persist. Kept as a no-op so
        // the step index mapping doesn't shift.
    }

    private func saveImageGen() {
        if !geminiApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: geminiApiKey)
        }
    }

    private func finishOnboarding() {
        saveCurrentStep()
        UserDefaults.standard.set(true, forKey: "onboarding_completed")
        UserDefaults.standard.set(false, forKey: "restart_onboarding_requested")
        isComplete = true
    }

    // MARK: - Load existing settings (for restart onboarding)

    private func loadExistingSettings() {
        llmProvider = KeychainHelper.load(key: KeychainHelper.llmProviderKey) ?? "openrouter"
        openRouterApiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        openRouterModel = KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? ""
        lmStudioBaseURL = KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey) ?? ""
        lmStudioModel = KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? ""
        lmStudioDescriptionModel = KeychainHelper.load(key: KeychainHelper.lmStudioDescriptionModelKey) ?? ""
        lmStudioDescriptionBaseURL = KeychainHelper.load(key: KeychainHelper.lmStudioDescriptionBaseURLKey) ?? ""
        assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        userContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        telegramToken = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? ""
        chatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        voiceTranscriptionProvider = VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )
        openAITranscriptionApiKey = KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? ""
        serperApiKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        jinaApiKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey) ?? ""
    }

    // MARK: - Local Server Presets

    private func onboardingLocalPreset(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed.contains(":1234") { return "lmstudio" }
        if trimmed.contains(":11434") { return "ollama" }
        if trimmed.contains(":8000") { return "vllm" }
        return "custom"
    }

    private func onboardingLocalPresetURL(_ preset: String) -> String? {
        switch preset {
        case "lmstudio": return "http://localhost:1234/v1"
        case "ollama": return "http://localhost:11434/v1"
        case "vllm": return "http://localhost:8000/v1"
        default: return nil
        }
    }

    // MARK: - Telegram Test

    private func testConnection() {
        isTesting = true
        botInfo = nil
        testError = nil
        Task {
            do {
                let info = try await telegramService.getMe(token: telegramToken)
                await MainActor.run {
                    let name = info.firstName + (info.username.map { " (@\($0))" } ?? "")
                    botInfo = "Connected: \(name)"
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

    // MARK: - Skip detection for existing users

    static var shouldShowOnboarding: Bool {
        // "restart_onboarding_requested" is set by the Restart Onboarding button
        if UserDefaults.standard.bool(forKey: "restart_onboarding_requested") { return true }
        // If onboarding was completed before, don't show
        if UserDefaults.standard.bool(forKey: "onboarding_completed") { return false }
        // First launch: skip if essential fields are already configured (existing user updating the app)
        let hasToken = !(KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "").isEmpty
        let hasApiKey = !(KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "").isEmpty
        if hasToken && hasApiKey { return false }
        return true
    }
}
