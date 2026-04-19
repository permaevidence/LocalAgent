import Foundation

/// Persistent registry of subagent sessions, backed by disk.
///
/// Each session captures the full conversation state of a subagent so the
/// main agent can resume it at any time by passing `session_id` to the
/// Agent tool.
///
/// Conversation state (messages, tool interactions, totals) is serialized
/// to `~/LocalAgent/subagent_sessions/<id>.json` on every mutation and
/// reloaded at app start. Subprocess-backed resources (e.g. Playwright
/// browser) still have to relaunch after an app restart — only the message
/// history is restored, not live OS state.
///
/// LRU retention: up to `maxSessions` (default 300) are kept on disk. When
/// the cap is exceeded, sessions with the oldest `lastUsed` timestamp are
/// evicted first. A frequently-resumed session keeps its `lastUsed` current
/// and is never evicted before newer-but-idle sessions — age is measured by
/// "last touch," not by creation date.
///
/// Session IDs are 5-char base36 strings (~60M possible values) — short
/// enough for an LLM to track in conversation context.
actor SubagentSessionRegistry {

    static let shared = SubagentSessionRegistry()

    struct Session: Codable {
        let id: String
        let subagentType: String
        let description: String
        let created: Date
        var lastUsed: Date
        var totalTurns: Int
        var totalSpendUSD: Double
        var toolsCalled: [String]      // unique, ordered by first appearance

        // Conversation state — enough for SubagentRunner to resume.
        var messages: [Message]                 // user messages fed to the LLM
        var toolInteractions: [ToolInteraction] // accumulated tool call/result pairs
        var lastAssistantText: String?          // final text from last run (becomes assistant message on resume)
    }

    private var sessions: [String: Session] = [:]

    private init() {
        loadAllFromDisk()
    }

    // MARK: - Create / Resume

    /// Create a fresh session and return its ID.
    func create(subagentType: String, description: String, initialPrompt: String) -> (id: String, session: Session) {
        let id = generateId()
        let userMessage = Message(role: .user, content: initialPrompt, timestamp: Date())
        let session = Session(
            id: id,
            subagentType: subagentType,
            description: description,
            created: Date(),
            lastUsed: Date(),
            totalTurns: 0,
            totalSpendUSD: 0,
            toolsCalled: [],
            messages: [userMessage],
            toolInteractions: [],
            lastAssistantText: nil
        )
        sessions[id] = session
        persist(session)
        pruneLRU()
        return (id, session)
    }

    /// Prepare a session for resumption by appending a new user message.
    /// Returns the updated session (with the new message + prior assistant
    /// text converted to a message), or nil if the session_id is unknown.
    ///
    /// On resume, estimates total token count and trims oldest messages +
    /// tool interactions if the session exceeds the configurable budget
    /// (default 100k tokens). Trimming drops from the front, keeping the
    /// most recent context. A future version will replace this with
    /// summarization-based compaction.
    func prepareResume(sessionId: String, continuationPrompt: String) -> Session? {
        guard var session = sessions[sessionId] else { return nil }

        // If the prior run ended with a text response, inject it as an
        // assistant message so the subagent sees its own prior reply.
        if let priorText = session.lastAssistantText {
            let assistantMsg = Message(role: .assistant, content: priorText, timestamp: Date())
            session.messages.append(assistantMsg)
            session.lastAssistantText = nil
        }

        let userMsg = Message(role: .user, content: continuationPrompt, timestamp: Date())
        session.messages.append(userMsg)
        session.lastUsed = Date()

        // Trim if over budget.
        let budget = Self.tokenBudget()
        trimIfNeeded(&session, budget: budget)

        sessions[sessionId] = session
        persist(session)
        return session
    }

    // MARK: - Context trimming

    /// Rough token estimate: 1 token ≈ 4 characters. Good enough for
    /// budgeting — off by 10-20% is fine since the threshold is conservative.
    private func estimateTokens(_ session: Session) -> Int {
        var chars = 0
        for msg in session.messages {
            chars += msg.content.count
        }
        for interaction in session.toolInteractions {
            chars += interaction.assistantMessage.content?.count ?? 0
            for tc in interaction.assistantMessage.toolCalls {
                chars += tc.function.arguments.count
            }
            for result in interaction.results {
                chars += result.content.count
            }
        }
        return chars / 4
    }

    /// Drop oldest messages and tool interactions until we're under budget.
    /// Keeps at least the last message (the new user prompt) and the last
    /// 3 tool interactions so the subagent has recent context.
    private func trimIfNeeded(_ session: inout Session, budget: Int) {
        let estimated = estimateTokens(session)
        guard estimated > budget else { return }

        let minKeepInteractions = 3
        let minKeepMessages = 2  // at least last assistant + new user prompt

        // Trim tool interactions from the front first (they're the biggest).
        while estimateTokens(session) > budget,
              session.toolInteractions.count > minKeepInteractions {
            session.toolInteractions.removeFirst()
        }

        // If still over, trim older messages from the front.
        while estimateTokens(session) > budget,
              session.messages.count > minKeepMessages {
            session.messages.removeFirst()
        }
    }

    private static func tokenBudget() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.subagentSessionTokenBudgetKey),
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return KeychainHelper.defaultSubagentSessionTokenBudget
    }

    /// Update session after a run completes.
    func commitRun(
        sessionId: String,
        additionalTurns: Int,
        additionalSpend: Double,
        newToolsCalled: [String],
        newToolInteractions: [ToolInteraction],
        finalAssistantText: String?
    ) {
        guard var session = sessions[sessionId] else { return }
        session.totalTurns += additionalTurns
        session.totalSpendUSD += additionalSpend
        session.lastUsed = Date()
        session.lastAssistantText = finalAssistantText
        session.toolInteractions.append(contentsOf: newToolInteractions)

        // Merge new unique tool names preserving first-seen order.
        let existing = Set(session.toolsCalled)
        for name in newToolsCalled where !existing.contains(name) {
            session.toolsCalled.append(name)
        }

        sessions[sessionId] = session
        persist(session)
    }

    // MARK: - Query

    func get(_ sessionId: String) -> Session? {
        sessions[sessionId]
    }

    /// Paginated listing sorted by `lastUsed` descending (most recent first).
    func list(limit: Int = 20, offset: Int = 0) -> (sessions: [Session], total: Int) {
        let sorted = sessions.values.sorted { $0.lastUsed > $1.lastUsed }
        let total = sorted.count
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        return (page, total)
    }

    /// Total number of sessions.
    var count: Int { sessions.count }

    // MARK: - Cleanup (app shutdown only)

    func removeAll() {
        for id in sessions.keys {
            deletePersisted(id)
        }
        sessions.removeAll()
    }

    // MARK: - LRU retention

    /// Maximum number of sessions retained. When exceeded, least-recently-used
    /// sessions are evicted on disk and in memory. Measured by `lastUsed`, so
    /// frequently-resumed sessions survive even if they were created long ago.
    static let maxSessions = 300

    /// Evict sessions with the oldest `lastUsed` timestamps until the count
    /// is at or below `maxSessions`. Called after create() and after the
    /// initial disk hydration.
    private func pruneLRU() {
        guard sessions.count > Self.maxSessions else { return }
        let sortedByLastUsed = sessions.values.sorted { $0.lastUsed < $1.lastUsed }
        let excess = sessions.count - Self.maxSessions
        var evicted = 0
        for session in sortedByLastUsed.prefix(excess) {
            sessions.removeValue(forKey: session.id)
            deletePersisted(session.id)
            evicted += 1
        }
        if evicted > 0 {
            print("[SubagentSessionRegistry] Evicted \(evicted) LRU session(s); retained \(sessions.count).")
        }
    }

    // MARK: - Disk persistence

    private static let persistenceDirName = "subagent_sessions"
    private static let persistenceExtension = "json"

    /// Canonical on-disk location: `~/LocalAgent/subagent_sessions/`.
    /// Creates the directory if it does not yet exist.
    private static func persistenceDirectory() -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("LocalAgent", isDirectory: true)
            .appendingPathComponent(Self.persistenceDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func persistenceURL(for id: String) -> URL {
        persistenceDirectory().appendingPathComponent("\(id).\(Self.persistenceExtension)")
    }

    /// Atomic write. Any I/O error is logged but never raised — the in-memory
    /// session remains authoritative, and the next mutation will re-attempt.
    private func persist(_ session: Session) {
        let url = Self.persistenceURL(for: session.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[SubagentSessionRegistry] Failed to persist session \(session.id): \(error)")
        }
    }

    private func deletePersisted(_ id: String) {
        try? FileManager.default.removeItem(at: Self.persistenceURL(for: id))
    }

    /// Called once from the actor's init. Reads every `<id>.json` file in the
    /// persistence directory and hydrates the in-memory map. Corrupt entries
    /// are logged and skipped — they do not block other sessions from loading.
    private func loadAllFromDisk() {
        let dir = Self.persistenceDirectory()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded = 0
        for url in contents where url.pathExtension == Self.persistenceExtension {
            do {
                let data = try Data(contentsOf: url)
                let session = try decoder.decode(Session.self, from: data)
                sessions[session.id] = session
                loaded += 1
            } catch {
                print("[SubagentSessionRegistry] Skipped corrupt session file \(url.lastPathComponent): \(error)")
            }
        }
        if loaded > 0 {
            print("[SubagentSessionRegistry] Restored \(loaded) session(s) from disk.")
        }
        pruneLRU()
    }

    // MARK: - ID generation

    private let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private func generateId() -> String {
        var id: String
        repeat {
            id = String((0..<5).map { _ in base36.randomElement()! })
        } while sessions[id] != nil
        return id
    }
}
