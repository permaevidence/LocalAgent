import Foundation

/// gws-backed data source for email/calendar ambient context and the unread-email poller.
///
/// Wraps the `gws` (Google Workspace CLI) subprocess. Exposes the same two system-prompt
/// context builders that EmailService / CalendarService used to expose, formatted
/// byte-identically so the frozen-context cache in ConversationManager continues to
/// hit. Also owns the 5-minute background poller for unread mail — it queries
/// `is:unread` so mail the user has already dismissed on another device does not
/// re-trigger ambient notifications.
///
/// All gws calls run with retry + graceful fallback: if the binary is missing or
/// every attempt fails, the context builders return "" and the poller silently
/// no-ops. The turn never breaks on a missing CLI.
actor GoogleWorkspaceService {
    static let shared = GoogleWorkspaceService()

    // MARK: - Public types

    struct UnreadEmail: Codable, Sendable, Equatable {
        let id: String
        let threadId: String?
        let from: String
        let subject: String
        let date: String
        let snippet: String
    }

    // MARK: - State

    private var cachedUnread: [UnreadEmail] = []
    private var lastSuccessfulFetch: Date?

    /// Watermark for the arrival-notification poll. Gmail's `after:<epoch>` only
    /// returns messages delivered strictly after that timestamp, so we use this
    /// as a high-water mark and advance it after each successful poll. On a
    /// failed poll we leave it alone so the window widens to cover the gap.
    /// Nil before the first successful poll — initialized to startBackgroundPoll
    /// time so we don't notify on pre-existing unread mail at launch.
    private var lastArrivalPollTime: Date?

    /// Defense-in-depth dedupe across overlapping window edges (`after:` is
    /// inclusive of second-boundary matches in practice). Bounded to last 200.
    private var recentlyNotifiedIds: [String] = []

    private var pollerTask: Task<Void, Never>?
    private var newEmailHandler: (@Sendable ([UnreadEmail]) async -> Void)?

    /// Calendar context cache with day-rollover semantics, mirroring the old
    /// CalendarService behavior. The cached string stays valid until either the
    /// frozen-context helper forces a refresh or the local day changes.
    private var cachedCalendarContext: String?
    private var cachedCalendarDay: Date?

    private let pollIntervalSeconds: UInt64 = 300
    private let maxUnread = 10
    private let agendaDaysAhead = 30

    // MARK: - Public API — polling lifecycle

    func setNewEmailHandler(_ handler: @escaping @Sendable ([UnreadEmail]) async -> Void) {
        newEmailHandler = handler
    }

    func startBackgroundPoll() {
        pollerTask?.cancel()
        let intervalNs: UInt64 = pollIntervalSeconds * 1_000_000_000
        // Seed the arrival watermark to "now" so the first poll only surfaces
        // truly fresh mail — a mailbox with hundreds of pre-existing unread
        // would otherwise flood the session.
        lastArrivalPollTime = Date()
        pollerTask = Task.detached { [weak self] in
            // First poll after the seed interval: don't tick at T=0 or we'll
            // query a zero-width window and miss nothing intended anyway.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.pollOnce()
            }
        }
        print("[GoogleWorkspaceService] Arrival poll started (every \(pollIntervalSeconds)s, query: is:unread after:<lastPollTime>)")
    }

    func stopBackgroundPoll() {
        pollerTask?.cancel()
        pollerTask = nil
    }

    // MARK: - Public API — system-prompt context builders

    /// Email context block for the system prompt. Byte-stable between explicit
    /// refreshes so the provider prompt cache holds. Returns "" on any failure
    /// so the caller can simply skip the block.
    ///
    /// This fetches the snapshot of current unread mail (top N by date, no
    /// time-window filter) — distinct from the poll path which only reports
    /// NEW arrivals since the last watermark.
    func getEmailContextForSystemPrompt() async -> String {
        _ = await fetchUnreadSnapshotWithRetry()
        return formatUnreadEmails(cachedUnread)
    }

    /// Calendar context block for the system prompt. Cache hits are byte-stable;
    /// refreshes on force, local-day rollover, or first miss. Returns "" on any
    /// failure so the caller can simply skip the block.
    func getCalendarContextForSystemPrompt(forceRefresh: Bool = false) async -> String {
        let today = Calendar.current.startOfDay(for: Date())
        if !forceRefresh,
           let cached = cachedCalendarContext,
           cachedCalendarDay == today {
            return cached
        }
        if let events = await fetchAgendaWithRetry() {
            let formatted = formatAgenda(events: events)
            cachedCalendarContext = formatted
            cachedCalendarDay = today
            return formatted
        }
        // Retry exhausted — surface empty so the system prompt skips the block.
        return ""
    }

    func invalidateCalendarCache() {
        cachedCalendarContext = nil
        cachedCalendarDay = nil
    }

    // MARK: - Poll tick (arrival-only — does NOT surface pre-existing unread)

    private func pollOnce() async {
        // Watermark was seeded at startBackgroundPoll time. On a failed fetch we
        // leave it untouched so the next successful poll widens the window to
        // cover the gap — no missed arrivals.
        let since = lastArrivalPollTime ?? Date().addingTimeInterval(-TimeInterval(pollIntervalSeconds))
        let sinceEpoch = Int(since.timeIntervalSince1970)
        let pollStartedAt = Date()

        guard let arrived = await fetchEmailsArrivedSinceWithRetry(sinceEpoch: sinceEpoch) else {
            return
        }

        // Deduplicate against the last 200 notified IDs — belt-and-braces for
        // boundary conditions (same-second delivery, clock drift, etc.).
        let notifiedSet = Set(recentlyNotifiedIds)
        let fresh = arrived.filter { !notifiedSet.contains($0.id) }

        // Advance the watermark only on a successful fetch. Use pollStartedAt
        // (captured before the fetch) to avoid creating a gap while the request
        // was in flight.
        lastArrivalPollTime = pollStartedAt

        if !fresh.isEmpty {
            // Bound the dedupe buffer to the most recent 200 IDs.
            recentlyNotifiedIds.append(contentsOf: fresh.map { $0.id })
            if recentlyNotifiedIds.count > 200 {
                recentlyNotifiedIds = Array(recentlyNotifiedIds.suffix(200))
            }
            if let handler = newEmailHandler {
                await handler(fresh)
            }
        }
    }

    // MARK: - Fetch helpers (with retry)

    /// Snapshot fetch: "top N unread right now" for the system-prompt block.
    /// Not time-windowed — always returns the user's freshest unread mail.
    private func fetchUnreadSnapshotWithRetry() async -> [UnreadEmail]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            if let emails = await fetchUnreadSnapshotOnce() {
                cachedUnread = emails
                lastSuccessfulFetch = Date()
                return emails
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        print("[GoogleWorkspaceService] fetchUnreadSnapshot: all retries exhausted — continuing without email context")
        return nil
    }

    /// Arrival fetch: "unread mail delivered after <epoch>" for the poller.
    /// Returns ONLY new arrivals; a mailbox with 500 pre-existing unread will
    /// return 0 rows if nothing new landed in the poll window.
    private func fetchEmailsArrivedSinceWithRetry(sinceEpoch: Int) async -> [UnreadEmail]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            if let emails = await fetchEmailsArrivedSinceOnce(sinceEpoch: sinceEpoch) {
                return emails
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        print("[GoogleWorkspaceService] fetchEmailsArrivedSince(\(sinceEpoch)): all retries exhausted — skipping this tick")
        return nil
    }

    private func fetchAgendaWithRetry() async -> [AgendaEvent]? {
        var delayNs: UInt64 = 1_000_000_000
        for attempt in 1...3 {
            if let events = await fetchAgendaOnce() {
                return events
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            }
        }
        print("[GoogleWorkspaceService] fetchAgenda: all retries exhausted — continuing without calendar context")
        return nil
    }

    // MARK: - Fetch helpers (single attempt)

    private struct TriageResponse: Decodable {
        let messages: [TriageMessage]
    }
    private struct TriageMessage: Decodable {
        let id: String
        let from: String?
        let subject: String?
        let date: String?
    }

    private func fetchUnreadSnapshotOnce() async -> [UnreadEmail]? {
        return await triageAndEnrich(query: "is:unread", maxResults: maxUnread)
    }

    /// The arrival path uses a wider cap (50) because the realistic worst case
    /// — a dormant account suddenly receiving a burst — is still bounded, and
    /// triage + snippet fetches are cheap.
    private func fetchEmailsArrivedSinceOnce(sinceEpoch: Int) async -> [UnreadEmail]? {
        return await triageAndEnrich(query: "is:unread after:\(sinceEpoch)", maxResults: 50)
    }

    /// Runs `gws gmail +triage` for the given query, then enriches each result
    /// with `users.messages.get(format=metadata).snippet` so the preview lines
    /// match the legacy EmailService format.
    private func triageAndEnrich(query: String, maxResults: Int) async -> [UnreadEmail]? {
        let triageArgs = [
            "gmail", "+triage",
            "--query", query,
            "--max", "\(maxResults)",
            "--format", "json",
        ]
        guard let out = await runGws(args: triageArgs, timeoutSeconds: 20) else { return nil }
        let stripped = stripLogPreamble(out)
        guard let data = stripped.data(using: .utf8),
              let triage = try? JSONDecoder().decode(TriageResponse.self, from: data) else {
            print("[GoogleWorkspaceService] triage decode failed; raw head: \(stripped.prefix(200))")
            return nil
        }

        // Serial snippet fetch — latency is irrelevant for a 5-min poller, and
        // parallelizing would risk burning through OAuth rate limits on bursts.
        var results: [UnreadEmail] = []
        for msg in triage.messages {
            let snippet = await fetchSnippet(messageId: msg.id) ?? ""
            results.append(UnreadEmail(
                id: msg.id,
                threadId: nil,
                from: msg.from ?? "(unknown sender)",
                subject: msg.subject ?? "(no subject)",
                date: msg.date ?? "",
                snippet: snippet
            ))
        }
        return results
    }

    private struct MessageMetadata: Decodable {
        let snippet: String?
        let threadId: String?
    }

    private func fetchSnippet(messageId: String) async -> String? {
        let paramsJSON = "{\"userId\":\"me\",\"id\":\"\(messageId)\",\"format\":\"metadata\"}"
        let args = ["gmail", "users", "messages", "get", "--params", paramsJSON]
        guard let out = await runGws(args: args, timeoutSeconds: 15) else { return nil }
        let stripped = stripLogPreamble(out)
        guard let data = stripped.data(using: .utf8),
              let meta = try? JSONDecoder().decode(MessageMetadata.self, from: data) else {
            return nil
        }
        return meta.snippet
    }

    // MARK: - Agenda fetch + types

    struct AgendaEvent: Sendable {
        let id: String
        let summary: String
        let startDate: Date
        let isAllDay: Bool
        let notes: String?
    }

    private struct AgendaResponse: Decodable {
        let events: [RawEvent]
    }
    private struct RawEvent: Decodable {
        let id: String?
        let summary: String?
        let description: String?
        let start: TimeMark?
        let location: String?
    }
    private struct TimeMark: Decodable {
        let dateTime: String?
        let date: String?
        let timeZone: String?
    }

    private func fetchAgendaOnce() async -> [AgendaEvent]? {
        let args = [
            "calendar", "+agenda",
            "--days", "\(agendaDaysAhead)",
            "--format", "json",
        ]
        guard let out = await runGws(args: args, timeoutSeconds: 20) else { return nil }
        let stripped = stripLogPreamble(out)
        guard let data = stripped.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgendaResponse.self, from: data) else {
            print("[GoogleWorkspaceService] agenda decode failed; raw head: \(stripped.prefix(200))")
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone.current

        var events: [AgendaEvent] = []
        for raw in response.events {
            guard let start = raw.start else { continue }
            let date: Date?
            let allDay: Bool
            if let dt = start.dateTime {
                date = iso.date(from: dt) ?? isoNoFrac.date(from: dt)
                allDay = false
            } else if let d = start.date {
                date = dateOnly.date(from: d)
                allDay = true
            } else {
                continue
            }
            guard let resolved = date else { continue }
            let notes = [raw.description, raw.location]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            events.append(AgendaEvent(
                id: raw.id ?? UUID().uuidString,
                summary: raw.summary?.isEmpty == false ? raw.summary! : "(untitled)",
                startDate: resolved,
                isAllDay: allDay,
                notes: notes.isEmpty ? nil : notes
            ))
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Formatters (match legacy output byte-for-byte where it matters)

    private func formatUnreadEmails(_ emails: [UnreadEmail]) -> String {
        guard !emails.isEmpty else { return "" }

        var lines: [String] = ["📧 **Your Inbox** (last \(emails.count) unread emails):", ""]
        for email in emails {
            var line = "• **\(email.subject)** from \(email.from)"
            if !email.date.isEmpty {
                line += " (\(email.date))"
            }
            line += " [id: \(email.id)]"
            if !email.snippet.isEmpty {
                let preview = email.snippet
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(100)
                line += "\n  └ \(preview)..."
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Use `bash` with `gws gmail +read`, `gws gmail +reply`, `gws gmail +send` etc. to act on these emails.")
        return lines.joined(separator: "\n")
    }

    /// Matches CalendarService.generateCalendarContext progressive-detail layout:
    /// full detail for today+near (≤7 days), title+date for 8–30 days, no far bucket
    /// because gws +agenda is already capped at the requested horizon.
    private func formatAgenda(events: [AgendaEvent]) -> String {
        guard !events.isEmpty else { return "📅 **Your Calendar**: No upcoming events." }

        let now = Date()
        let calendar = Calendar.current
        let sevenDaysOut = calendar.date(byAdding: .day, value: 7, to: now)!

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let near = events.filter { $0.startDate < sevenDaysOut }
        let mid  = events.filter { $0.startDate >= sevenDaysOut }

        var lines: [String] = ["📅 **Your Calendar**:", ""]
        var currentDateString = ""

        for event in near {
            let eventDateString = dateFormatter.string(from: event.startDate)
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty { lines.append("") }
                if calendar.isDateInToday(event.startDate) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.startDate) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }

            var eventLine: String
            if event.isAllDay {
                eventLine = "• (all day): \(event.summary)"
            } else {
                let timeStr = timeFormatter.string(from: event.startDate)
                eventLine = "• \(timeStr): \(event.summary)"
            }
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            let shortId = String(event.id.prefix(8))
            eventLine += " [id: \(shortId)...]"
            lines.append(eventLine)
        }

        if !mid.isEmpty {
            lines.append("")
            lines.append("**Next 8-30 days:**")
            for event in mid {
                let dateStr = dateFormatter.string(from: event.startDate)
                let shortId = String(event.id.prefix(8))
                lines.append("• \(dateStr): \(event.summary) [id: \(shortId)...]")
            }
        }

        // Cap to roughly the same budget as CalendarService (4000 tokens ≈ 16000 chars).
        var result = lines.joined(separator: "\n")
        let maxChars = 16_000
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 80)) +
                "\n... [calendar truncated — run `bash gws calendar +agenda` for full agenda]"
        }
        return result
    }

    // MARK: - gws subprocess invocation

    /// Locates the `gws` binary across common install paths. Returns nil if missing —
    /// callers must treat that as a non-fatal "no context available".
    private func locateGwsBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gws",
            "/usr/local/bin/gws",
            "\(NSHomeDirectory())/.cargo/bin/gws",
            "\(NSHomeDirectory())/.local/bin/gws",
            "/usr/bin/gws",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last-ditch: ask `which`. We intentionally pass an augmented PATH so it can
        // see Homebrew etc., mirroring the pattern in LSPRegistry.
        if let out = Self.runBlockingProcess(
            executable: "/usr/bin/env",
            args: ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.cargo/bin",
                   "which", "gws"],
            timeoutSeconds: 3
        ), !out.isEmpty {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Returns stdout on success, nil on any failure (missing binary, non-zero exit,
    /// timeout, or I/O error).
    private func runGws(args: [String], timeoutSeconds: Int) async -> String? {
        guard let binary = locateGwsBinary() else {
            // Soft-fail: the user may not have gws installed on this machine. That's
            // fine — the system prompt simply skips the gws-backed blocks.
            return nil
        }
        return await Self.runProcessAsync(
            executable: binary,
            args: args,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// The `gws` CLI prints a "Using keyring backend: keyring" line to stdout before
    /// the JSON body. JSONDecoder chokes on it. Strip any preamble up to the first
    /// `{` or `[`.
    private func stripLogPreamble(_ text: String) -> String {
        if let brace = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            return String(text[brace...])
        }
        return text
    }

    // MARK: - Process helpers (static so they can be reused / tested)

    static func runProcessAsync(executable: String, args: [String], timeoutSeconds: Int) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = runBlockingProcess(executable: executable, args: args, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: out)
            }
        }
    }

    static func runBlockingProcess(executable: String, args: [String], timeoutSeconds: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Augment PATH so `gws` can find its own helpers (some versions invoke git/etc.).
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(existingPath)"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            print("[GoogleWorkspaceService] failed to launch \(executable): \(error)")
            return nil
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            print("[GoogleWorkspaceService] \(executable) timed out after \(timeoutSeconds)s")
            return nil
        }

        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            print("[GoogleWorkspaceService] \(executable) exit=\(process.terminationStatus); stderr head: \(stderr.prefix(200))")
            return nil
        }
        return stdout
    }
}
