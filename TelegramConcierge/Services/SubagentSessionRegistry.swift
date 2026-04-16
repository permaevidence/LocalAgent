import Foundation

/// Persistent (in-memory, per-app-run) registry of subagent sessions.
///
/// Each session captures the full conversation state of a subagent so the
/// main agent can resume it at any time by passing `session_id` to the
/// Agent tool. Sessions are append-only — they never expire or close. The
/// underlying subprocess resources (e.g. Playwright browser) stay alive
/// for the lifetime of the app.
///
/// Session IDs are 5-char base36 strings (~60M possible values) — short
/// enough for an LLM to track in conversation context.
actor SubagentSessionRegistry {

    static let shared = SubagentSessionRegistry()

    struct Session {
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

    private init() {}

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
        return (id, session)
    }

    /// Prepare a session for resumption by appending a new user message.
    /// Returns the updated session (with the new message + prior assistant
    /// text converted to a message), or nil if the session_id is unknown.
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
        sessions[sessionId] = session
        return session
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
        sessions.removeAll()
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
