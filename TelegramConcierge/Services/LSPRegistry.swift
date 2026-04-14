import Foundation

/// Result of a diagnostics request. `skipped` carries a human-readable reason
/// the caller can include in its tool-result payload (missing server, unknown
/// extension, etc.) without treating the write as failed.
enum DiagnosticsResult {
    case diagnostics([LSPDiagnostic], serverID: String)
    case skipped(reason: String)
}

/// Singleton actor: owns all live `LSPClient` instances, keyed by
/// (serverID, workspaceRoot). Spawn-on-demand; idle clients are reaped
/// lazily on each access after `idleTTL`. Negative-caches missing
/// executables so we don't probe `which` on every write.
actor LSPRegistry {

    static let shared = LSPRegistry()

    private struct Entry {
        let client: LSPClient
        var lastUsed: Date
        let serverID: String
        let rootURI: URL
        var openedURIs: Set<String> = []
    }

    private var entries: [String: Entry] = [:]
    private var spawnTasks: [String: Task<LSPClient?, Never>] = [:]
    private var missingExecutables: Set<String> = []

    /// Reap clients idle for longer than this. 10 minutes matches OpenCode's
    /// default — typescript-language-server is slow (~2-5s) to spawn so we
    /// want to amortize over a realistic development session.
    private let idleTTL: TimeInterval = 600

    private init() {}

    // MARK: - Public API

    /// Main entry: open/update the file in its language server, then wait
    /// up to `timeout` seconds for publishDiagnostics. Transparently spawns
    /// the server on first use.
    func diagnostics(
        forPath path: String,
        updatedText: String,
        waitFor timeout: TimeInterval = 1.0
    ) async -> DiagnosticsResult {
        reapIdleLocked()

        let ext = (path as NSString).pathExtension.lowercased()
        guard let cfg = LSPLanguages.serverConfig(forExtension: ext) else {
            return .skipped(reason: "no language support for .\(ext)")
        }
        guard let languageId = LSPLanguages.languageId(forExtension: ext) else {
            return .skipped(reason: "no languageId mapping for .\(ext)")
        }
        if missingExecutables.contains(cfg.executable) {
            return .skipped(reason: "\(cfg.executable) not installed")
        }

        let root = LSPLanguages.workspaceRoot(forFilePath: path, markers: cfg.workspaceMarkers)
        let key = entryKey(serverID: cfg.serverID, root: root)

        guard let client = await ensureClient(key: key, config: cfg, root: root) else {
            missingExecutables.insert(cfg.executable)
            return .skipped(reason: "\(cfg.executable) not installed (install to enable diagnostics)")
        }

        let fileURL = URL(fileURLWithPath: path)
        let uriKey = fileURL.absoluteString

        // Ensure the document is known to the server. First touch → didOpen;
        // subsequent touches → didChange. Always followed by didSave to nudge
        // servers that only publish on save (rust-analyzer, some pylsp setups).
        var opened = entries[key]?.openedURIs.contains(uriKey) ?? false
        do {
            if opened {
                try await client.didChange(uri: fileURL, text: updatedText)
            } else {
                try await client.didOpen(uri: fileURL, text: updatedText, languageId: languageId)
                entries[key]?.openedURIs.insert(uriKey)
                opened = true
            }
            try await client.didSave(uri: fileURL)
        } catch {
            return .skipped(reason: "LSP sync failed: \(error)")
        }

        entries[key]?.lastUsed = Date()

        let diags = await client.diagnostics(for: fileURL, waitFor: timeout)
        return .diagnostics(diags, serverID: cfg.serverID)
    }

    /// Shut down every live client. Called at app termination.
    func shutdownAll() async {
        for (_, entry) in entries {
            await entry.client.shutdown()
        }
        entries.removeAll()
        spawnTasks.removeAll()
    }

    /// Introspection for debugging / status surfaces.
    func status() -> [(serverID: String, root: String, lastUsed: Date, openDocs: Int)] {
        entries.values.map {
            ($0.serverID, $0.rootURI.path, $0.lastUsed, $0.openedURIs.count)
        }
    }

    // MARK: - Private

    private func ensureClient(
        key: String,
        config: LSPServerConfig,
        root: URL
    ) async -> LSPClient? {
        if let entry = entries[key] {
            let alive = await entry.client.isAlive
            if alive { return entry.client }
            // Stale entry from a crashed server — drop and respawn below.
            entries.removeValue(forKey: key)
        }

        if let existing = spawnTasks[key] {
            return await existing.value
        }

        let executable = config.executable
        let arguments = config.arguments
        let task: Task<LSPClient?, Never> = Task {
            guard let exePath = LSPLanguages.locateExecutable(executable) else {
                return nil
            }
            let client = LSPClient(executable: exePath, arguments: arguments)
            do {
                try await client.start()
                try await client.initialize(rootURI: root)
                return client
            } catch {
                await client.shutdown()
                return nil
            }
        }
        spawnTasks[key] = task
        let client = await task.value
        spawnTasks.removeValue(forKey: key)

        guard let client = client else { return nil }
        entries[key] = Entry(
            client: client,
            lastUsed: Date(),
            serverID: config.serverID,
            rootURI: root
        )
        return client
    }

    private func reapIdleLocked() {
        let now = Date()
        let stale = entries.filter { now.timeIntervalSince($0.value.lastUsed) > idleTTL }
        guard !stale.isEmpty else { return }
        for (key, entry) in stale {
            entries.removeValue(forKey: key)
            // Fire-and-forget shutdown so we don't block the main path.
            Task { await entry.client.shutdown() }
        }
    }

    private func entryKey(serverID: String, root: URL) -> String {
        "\(serverID)|\(root.standardizedFileURL.path)"
    }
}
