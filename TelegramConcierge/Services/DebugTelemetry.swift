import Foundation

/// User-only diagnostic telemetry for the debug panel.
///
/// This telemetry is NEVER sent to the LLM — it is not added to messages, the
/// system prompt, tool results, or anything the model sees. It is purely an
/// in-memory, UI-side stream of events for diagnosing stuck-turn behavior and
/// other runtime anomalies (tool hangs, background completions, drop-on-busy
/// bugs, cancellations, etc.). The singleton is `@MainActor` so it can feed a
/// SwiftUI view directly; callers from actors/background tasks should use
/// the non-isolated `DebugTelemetry.log(...)` convenience which hops.
@MainActor
final class DebugTelemetry: ObservableObject {
    static let shared = DebugTelemetry()

    enum Kind: String, Codable {
        case toolStart
        case toolEnd
        case toolError
        case turnStart
        case turnEnd
        case turnCancelled
        case turnError
        case subagentSpawn
        case subagentComplete
        case bashSpawn
        case bashComplete
        case watchMatch
        case pollTick
        case busyReply
        case messageDrop
        case info
    }

    struct Event: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let kind: Kind
        let summary: String
        let detail: String?
        let durationMs: Int?
        let isError: Bool
    }

    @Published private(set) var events: [Event] = []
    @Published var verbose: Bool = false
    @Published var pinToBottom: Bool = true

    private let maxEvents = 500
    private let detailCap = 1000

    private init() {}

    /// Record a new event (main-actor only). Trims oldest if over capacity.
    func record(
        _ kind: Kind,
        summary: String,
        detail: String? = nil,
        durationMs: Int? = nil,
        isError: Bool = false
    ) {
        let clippedDetail: String? = {
            guard let d = detail else { return nil }
            if d.count <= detailCap { return d }
            return String(d.prefix(detailCap)) + "…"
        }()
        let event = Event(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            summary: summary,
            detail: clippedDetail,
            durationMs: durationMs,
            isError: isError
        )
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Convenience for paired start/end timing. The returned closure is called on
    /// completion with the terminating kind (e.g., `.toolEnd` / `.toolError`),
    /// optional detail, and `isError`.
    func begin(
        _ kind: Kind,
        summary: String,
        detail: String? = nil
    ) -> (Kind, String?, Bool) -> Void {
        let startedAt = Date()
        record(kind, summary: summary, detail: detail)
        return { [weak self] endKind, endDetail, isError in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            self.record(endKind, summary: summary, detail: endDetail, durationMs: ms, isError: isError)
        }
    }

    func clear() {
        events.removeAll()
    }

    // MARK: - Non-isolated convenience (auto-hops to main actor)

    /// Log an event from any isolation context. Hops to the main actor to
    /// mutate the published list.
    nonisolated static func log(
        _ kind: Kind,
        summary: String,
        detail: String? = nil,
        durationMs: Int? = nil,
        isError: Bool = false
    ) {
        Task { @MainActor in
            DebugTelemetry.shared.record(
                kind,
                summary: summary,
                detail: detail,
                durationMs: durationMs,
                isError: isError
            )
        }
    }
}
