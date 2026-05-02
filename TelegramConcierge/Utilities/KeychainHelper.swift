import Foundation
import Security

enum LLMProvider: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case lmStudio = "lmstudio" // Kept as "lmstudio" for backward compatibility; represents any local provider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "Local Inference"
        }
    }

    static var defaultProvider: LLMProvider { .openRouter }

    static func fromStoredValue(_ value: String?) -> LLMProvider {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = LLMProvider(rawValue: normalized) else {
            return .defaultProvider
        }
        return provider
    }
}

enum VoiceTranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local (Whisper)"
        case .openAI:
            return "OpenAI (gpt-4o-transcribe)"
        }
    }

    static var defaultProvider: VoiceTranscriptionProvider { .local }

    static func fromStoredValue(_ value: String?) -> VoiceTranscriptionProvider {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = VoiceTranscriptionProvider(rawValue: normalized) else {
            return .defaultProvider
        }
        return provider
    }
}

enum KeychainHelper {
    
    enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
    }
    
    private static let service = "com.localagent"
    
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Credential Keys
extension KeychainHelper {
    static let defaultGeminiImageModel = ""
    static let defaultGeminiImageInputCostPerMillionTokensUSD = "2"
    static let defaultGeminiImageOutputTextCostPerMillionTokensUSD = "12"
    static let defaultGeminiImageOutputImageCostPerMillionTokensUSD = "120"

    static let telegramBotTokenKey = "telegram_bot_token"
    static let telegramChatIdKey = "telegram_chat_id"
    static let openRouterApiKeyKey = "openrouter_api_key"
    
    // Web Search Tool Keys
    static let serperApiKeyKey = "serper_api_key"
    static let jinaApiKeyKey = "jina_api_key"
    
    // Google Workspace (Gmail / Calendar / Contacts / Drive) is reached through
    // the `gws` CLI — credentials live in the macOS keychain under gws's own
    // entry, not here. The former imap/smtp/gmail-OAuth keys were removed as
    // part of that migration.

    // Google Gemini API Key
    static let geminiApiKeyKey = "gemini_api_key"
    static let geminiImageModelKey = "gemini_image_model"
    static let geminiImageInputCostPerMillionTokensUSDKey = "gemini_image_input_cost_per_million_tokens_usd"
    static let geminiImageOutputTextCostPerMillionTokensUSDKey = "gemini_image_output_text_cost_per_million_tokens_usd"
    static let geminiImageOutputImageCostPerMillionTokensUSDKey = "gemini_image_output_image_cost_per_million_tokens_usd"
    
    // Persona Settings Keys
    static let assistantNameKey = "assistant_name"
    static let userNameKey = "user_name"
    static let userContextKey = "user_context"
    static let structuredUserContextKey = "structured_user_context"
    
    // Model Settings
    static let openRouterModelKey = "openrouter_model"
    static let openRouterProvidersKey = "openrouter_providers"
    static let openRouterReasoningEffortKey = "openrouter_reasoning_effort"
    static let openRouterToolSpendLimitPerTurnUSDKey = "openrouter_tool_spend_limit_per_turn_usd"
    static let openRouterToolSpendLimitDailyUSDKey = "openrouter_tool_spend_limit_daily_usd"
    static let openRouterToolSpendLimitMonthlyUSDKey = "openrouter_tool_spend_limit_monthly_usd"

    // Voice Transcription Settings
    static let voiceTranscriptionProviderKey = "voice_transcription_provider"
    static let openAITranscriptionApiKeyKey = "openai_transcription_api_key"
    
    // LLM Provider Selection
    static let llmProviderKey = "llm_provider"  // "openrouter" or "lmstudio"
    static let lmStudioBaseURLKey = "lmstudio_base_url"
    static let lmStudioModelKey = "lmstudio_model"
    static let defaultLMStudioBaseURL = "http://localhost:1234/v1"
    static let lmStudioDescriptionModelKey = "lmstudio_description_model"
    static let lmStudioDescriptionBaseURLKey = "lmstudio_description_base_url"

    // Archive Settings
    static let archiveChunkSizeKey = "archive_chunk_size"

    // Context Budget Settings (tool interaction pruning)
    static let maxContextTokensKey = "max_context_tokens"
    static let targetContextTokensKey = "target_context_tokens"

    // Subagent Session Settings
    static let subagentSessionTokenBudgetKey = "subagent_session_token_budget"
    static let defaultSubagentSessionTokenBudget = 100000

    // Subagent per-turn context budget (prompt_tokens ceiling during a single run)
    static let subagentTurnTokenBudgetKey = "subagent_turn_token_budget"
    static let defaultSubagentTurnTokenBudget = 200000
}

// MARK: - User-defined Service Keys

/// A user-defined API key for an external service (Vercel, Supabase, etc.).
/// The `name` is the user-facing suffix; bash receives it with
/// `serviceKeyEnvironmentPrefix` prepended (e.g. "VERCEL" -> "LOCALAGENT_KEY_VERCEL").
struct ServiceKey: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String        // env-var suffix, e.g. "VERCEL"
    var description: String // human label, e.g. "Vercel deploy token"
}

extension KeychainHelper {
    static let serviceKeyEnvironmentPrefix = "LOCALAGENT_KEY_"

    private static let serviceKeysMetadataDefaultsKey = "localagent.service_keys_metadata"
    private static let serviceKeyPrefix = "servicekey_"

    static func serviceKeyEnvironmentName(for name: String) -> String {
        serviceKeyEnvironmentPrefix + name
    }

    /// Load the list of registered service keys (metadata only, no secrets).
    static func loadServiceKeys() -> [ServiceKey] {
        guard let data = UserDefaults.standard.data(forKey: serviceKeysMetadataDefaultsKey),
              let keys = try? JSONDecoder().decode([ServiceKey].self, from: data) else {
            return []
        }
        return keys
    }

    /// Persist the metadata list (names + descriptions) to UserDefaults.
    static func saveServiceKeys(_ keys: [ServiceKey]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: serviceKeysMetadataDefaultsKey)
    }

    /// Read a service key's secret value from the Keychain.
    static func loadServiceKeyValue(name: String) -> String? {
        load(key: serviceKeyPrefix + name)
    }

    /// Store a service key's secret value in the Keychain.
    static func saveServiceKeyValue(name: String, value: String) throws {
        try save(key: serviceKeyPrefix + name, value: value)
    }

    /// Delete a service key's secret from the Keychain.
    static func deleteServiceKeyValue(name: String) {
        try? delete(key: serviceKeyPrefix + name)
    }

    /// Returns all service keys as a dictionary suitable for merging into
    /// a subprocess environment: `["LOCALAGENT_KEY_VERCEL": "sk-...", ...]`.
    static func serviceKeyEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for key in loadServiceKeys() {
            if let value = loadServiceKeyValue(name: key.name), !value.isEmpty {
                env[serviceKeyEnvironmentName(for: key.name)] = value
            }
        }
        return env
    }
}

// MARK: - OpenRouter Spend Ledger (UserDefaults-backed)
extension KeychainHelper {
    private static let openRouterSpendLedgerDefaultsKey = "openrouter_spend_ledger_v1"
    private static let openRouterSpendLedgerRetentionDays = 500
    private static let openRouterSpendLimitBoostDefaultsKey = "openrouter_spend_limit_boost_v1"
    private static let openRouterSpendLimitBoostRetentionMonths = 24

    private struct OpenRouterSpendLedger: Codable {
        var byDay: [String: Double]
    }

    private struct OpenRouterSpendLimitBoostLedger: Codable {
        var dailyByDay: [String: Double]
        var monthlyByMonth: [String: Double]
    }

    static func recordOpenRouterSpend(_ amountUSD: Double, at date: Date = Date()) {
        guard amountUSD.isFinite, amountUSD > 0 else { return }
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: date)
        let key = dayKey(for: date)
        ledger.byDay[key, default: 0] += amountUSD
        saveOpenRouterSpendLedger(ledger)
    }

    static func openRouterSpendSnapshot(referenceDate: Date = Date()) -> (today: Double, month: Double) {
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: referenceDate)
        saveOpenRouterSpendLedger(ledger)

        let todayKey = dayKey(for: referenceDate)
        let monthPrefix = monthPrefixKey(for: referenceDate)

        let today = ledger.byDay[todayKey] ?? 0
        let month = ledger.byDay
            .filter { $0.key.hasPrefix(monthPrefix) }
            .reduce(0) { $0 + $1.value }

        return (today: max(0, today), month: max(0, month))
    }

    static func addOpenRouterSpendLimitIncrease(
        _ amountUSD: Double,
        applyToDaily: Bool,
        applyToMonthly: Bool,
        at date: Date = Date()
    ) {
        guard amountUSD.isFinite,
              amountUSD > 0,
              applyToDaily || applyToMonthly else { return }

        var ledger = loadOpenRouterSpendLimitBoostLedger()
        pruneOldSpendLimitBoostEntries(&ledger, referenceDate: date)

        if applyToDaily {
            let key = dayKey(for: date)
            ledger.dailyByDay[key, default: 0] += amountUSD
        }

        if applyToMonthly {
            let key = monthKey(for: date)
            ledger.monthlyByMonth[key, default: 0] += amountUSD
        }

        saveOpenRouterSpendLimitBoostLedger(ledger)
    }

    static func openRouterSpendLimitIncreaseSnapshot(referenceDate: Date = Date()) -> (daily: Double, monthly: Double) {
        var ledger = loadOpenRouterSpendLimitBoostLedger()
        pruneOldSpendLimitBoostEntries(&ledger, referenceDate: referenceDate)
        saveOpenRouterSpendLimitBoostLedger(ledger)

        let daily = ledger.dailyByDay[dayKey(for: referenceDate)] ?? 0
        let monthly = ledger.monthlyByMonth[monthKey(for: referenceDate)] ?? 0

        return (daily: max(0, daily), monthly: max(0, monthly))
    }

    private static func loadOpenRouterSpendLedger() -> OpenRouterSpendLedger {
        guard let data = UserDefaults.standard.data(forKey: openRouterSpendLedgerDefaultsKey),
              let ledger = try? JSONDecoder().decode(OpenRouterSpendLedger.self, from: data) else {
            return OpenRouterSpendLedger(byDay: [:])
        }
        return ledger
    }

    private static func saveOpenRouterSpendLedger(_ ledger: OpenRouterSpendLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: openRouterSpendLedgerDefaultsKey)
    }

    private static func loadOpenRouterSpendLimitBoostLedger() -> OpenRouterSpendLimitBoostLedger {
        guard let data = UserDefaults.standard.data(forKey: openRouterSpendLimitBoostDefaultsKey),
              let ledger = try? JSONDecoder().decode(OpenRouterSpendLimitBoostLedger.self, from: data) else {
            return OpenRouterSpendLimitBoostLedger(dailyByDay: [:], monthlyByMonth: [:])
        }
        return ledger
    }

    private static func saveOpenRouterSpendLimitBoostLedger(_ ledger: OpenRouterSpendLimitBoostLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: openRouterSpendLimitBoostDefaultsKey)
    }

    private static func pruneOldSpendEntries(_ ledger: inout OpenRouterSpendLedger, referenceDate: Date) {
        guard !ledger.byDay.isEmpty else { return }

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -openRouterSpendLedgerRetentionDays, to: referenceDate) ?? referenceDate
        let cutoffKey = dayKey(for: cutoffDate)

        ledger.byDay = ledger.byDay.filter { day, value in
            day >= cutoffKey && value.isFinite && value > 0
        }
    }

    private static func pruneOldSpendLimitBoostEntries(_ ledger: inout OpenRouterSpendLimitBoostLedger, referenceDate: Date) {
        let calendar = Calendar.current

        if !ledger.dailyByDay.isEmpty {
            let dailyCutoffDate = calendar.date(byAdding: .day, value: -openRouterSpendLedgerRetentionDays, to: referenceDate) ?? referenceDate
            let dailyCutoffKey = dayKey(for: dailyCutoffDate)
            ledger.dailyByDay = ledger.dailyByDay.filter { day, value in
                day >= dailyCutoffKey && value.isFinite && value > 0
            }
        }

        if !ledger.monthlyByMonth.isEmpty {
            let monthlyCutoffDate = calendar.date(byAdding: .month, value: -openRouterSpendLimitBoostRetentionMonths, to: referenceDate) ?? referenceDate
            let monthlyCutoffKey = monthKey(for: monthlyCutoffDate)
            ledger.monthlyByMonth = ledger.monthlyByMonth.filter { month, value in
                month >= monthlyCutoffKey && value.isFinite && value > 0
            }
        }
    }

    private static func dayKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func monthPrefixKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d-", year, month)
    }

    private static func monthKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }
}
