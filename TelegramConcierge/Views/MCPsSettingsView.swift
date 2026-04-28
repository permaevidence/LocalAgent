import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MCP server management panel (Phase 4).
///
/// Lists every server configured in `~/LocalAgent/mcp.json`, shows live
/// connection status from the registry, lets the user edit command / args /
/// env / disabled flag / secret refs, add new servers, or remove existing
/// ones. Secrets are stored in the macOS Keychain under
/// `mcp_env_<server>_<VAR>` — never written to mcp.json.
///
/// Save flow: edits mutate an in-memory array; pressing "Save & Restart MCPs"
/// serialises the array back to mcp.json via MCPRegistry.saveConfigsToDisk()
/// and calls MCPRegistry.shared.reloadFromDisk() so running clients are
/// cleanly torn down and respawned.
struct MCPsSettingsView: View {

    @State private var servers: [MCPServerConfig] = []
    @State private var statusByServer: [String: ServerStatus] = [:]
    @State private var editingIndex: Int? = nil
    @State private var isLoading: Bool = true
    @State private var errorNote: String?
    @State private var showingAddSheet: Bool = false
    @State private var pendingRemoveIndex: Int? = nil

    // Secrets editing (per editing session)
    @State private var secretValues: [String: String] = [:]   // "<server>|<VAR>" → value
    @State private var revealedSecrets: Set<String> = []

    // Profile bundle
    @State private var showingImportResult: Bool = false
    @State private var importResultText: String = ""

    private struct ServerStatus {
        let connected: Bool
        let failed: Bool
        let reason: String?
        let toolCount: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                serversCard
                profileCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await reload()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddMCPSheet(
                existingNames: Set(servers.map { $0.name }),
                onAdd: { cfg in
                    servers.append(cfg)
                    Task { await saveAndReconnect() }
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false }
            )
        }
        .alert("Profile imported", isPresented: $showingImportResult) {
            Button("OK") {}
        } message: {
            Text(importResultText)
        }
        .alert("Remove MCP server?",
               isPresented: Binding(
                   get: { pendingRemoveIndex != nil },
                   set: { if !$0 { pendingRemoveIndex = nil } }
               )
        ) {
            Button("Cancel", role: .cancel) {
                pendingRemoveIndex = nil
            }
            Button("Remove", role: .destructive) {
                if let idx = pendingRemoveIndex {
                    servers.remove(at: idx)
                    if editingIndex == idx { editingIndex = nil }
                    pendingRemoveIndex = nil
                    Task { await saveAndReconnect() }
                }
            }
        } message: {
            if let idx = pendingRemoveIndex, idx < servers.count {
                Text("This will permanently remove \"\(servers[idx].name)\" and its configuration. API keys stored in Keychain will not be deleted.")
            }
        }
    }

    // MARK: - Profile bundle

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ProfileBundle.defaultExportFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "Save LocalAgent profile bundle. Keychain secrets are not included."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try ProfileBundle.exportData()
                try data.write(to: url, options: .atomic)
                errorNote = nil
            } catch {
                errorNote = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a LocalAgent profile bundle."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let result = try ProfileBundle.importData(data)
                MCPAgentRouting.reload()
                Task {
                    await MCPRegistry.shared.reloadFromDisk()
                    await MCPAgentRouting.refreshFromRegistry()
                    await reload()
                }
                importResultText = formatImportResult(result)
                showingImportResult = true
                errorNote = nil
            } catch {
                errorNote = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func formatImportResult(_ r: ProfileBundle.ImportResult) -> String {
        var lines: [String] = []
        if !r.mcpServersAdded.isEmpty {
            lines.append("Added MCPs: \(r.mcpServersAdded.joined(separator: ", "))")
        }
        if !r.mcpServersReplaced.isEmpty {
            lines.append("Replaced MCPs: \(r.mcpServersReplaced.joined(separator: ", "))")
        }
        if !r.routingEntriesReplaced.isEmpty {
            lines.append("Replaced routing: \(r.routingEntriesReplaced.joined(separator: ", "))")
        }
        if !r.agentsAdded.isEmpty {
            lines.append("Added agents: \(r.agentsAdded.joined(separator: ", "))")
        }
        if !r.agentsReplaced.isEmpty {
            lines.append("Replaced agents: \(r.agentsReplaced.joined(separator: ", "))")
        }
        if !r.secretsToPopulate.isEmpty {
            let pairs = r.secretsToPopulate.map { "\($0.server):\($0.variable)" }
            lines.append("Secrets to populate in Settings: \(pairs.joined(separator: ", "))")
        }
        if !r.warnings.isEmpty {
            lines.append("Warnings: \(r.warnings.joined(separator: "; "))")
        }
        if lines.isEmpty {
            lines.append("Bundle contained nothing to apply.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP servers")
                    .font(.title.weight(.semibold))
                Text("External tool providers your agents can use — browsers, databases, GitHub, and more. Install one here, then enable its tools per-agent on the Agents tab.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showingAddSheet = true
            } label: {
                Label("Add MCP server", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Servers card

    private var serversCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Installed servers",
                          systemImage: "server.rack",
                          subtitle: "Click a server to expand its settings. Editing any field turns the server OFF — click ON to apply changes and reconnect.")

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading MCP config…")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                } else if servers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No MCP servers installed yet", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundColor(.orange)
                        Text("Click “Add MCP server” above to install one (Playwright for browsing, Postgres for databases, GitHub for issues, etc.). Once installed, you can enable its tools per-agent on the Agents tab.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(servers.enumerated()), id: \.offset) { idx, cfg in
                            serverRow(idx: idx, cfg: cfg)
                        }
                    }
                }

                if let err = errorNote {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.red)
                }
            }
        }
    }


    // MARK: - Profile card

    private var profileCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Backup & share",
                          systemImage: "square.and.arrow.up.on.square",
                          subtitle: "Bundle your current setup — MCP servers, per-agent tool routing, and any custom subagents — into a single file. Share it between machines or with a friend. API key values stay local (only the variable names travel).")

                HStack(spacing: 10) {
                    Button {
                        exportProfile()
                    } label: {
                        Label("Export configuration", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        importProfile()
                    } label: {
                        Label("Import configuration", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Card shell

    @ViewBuilder
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }

    private func cardTitle(_ title: String, systemImage: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - One server row (status header + inline editor)

    @ViewBuilder
    private func serverRow(idx: Int, cfg: MCPServerConfig) -> some View {
        let status = statusByServer[cfg.name]
        VStack(alignment: .leading, spacing: 0) {
            // Always-visible header
            HStack(spacing: 8) {
                Button {
                    editingIndex = editingIndex == idx ? nil : idx
                } label: {
                    Image(systemName: editingIndex == idx ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                statusIndicator(for: status, disabled: cfg.disabled)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.name)
                        .font(.body.weight(.medium))
                    Text(commandPreview(cfg))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let status = status, !cfg.disabled {
                    if status.connected {
                        Text("\(status.toolCount) tools")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if status.failed {
                        Text("failed")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }

                // ON/OFF toggle — always visible
                Button {
                    if cfg.disabled {
                        updateServer(idx: idx, newDisabled: false)
                        Task { await saveAndReconnect() }
                    } else {
                        updateServer(idx: idx, newDisabled: true)
                        Task { await saveAndReconnect() }
                    }
                } label: {
                    Text(cfg.disabled ? "OFF" : "ON")
                        .font(.body.weight(.bold))
                        .foregroundColor(cfg.disabled ? .secondary : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(cfg.disabled ? Color.gray.opacity(0.25) : Color.green)
                        )
                }
                .buttonStyle(.plain)

                // Remove button — always visible
                Button {
                    pendingRemoveIndex = idx
                } label: {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundColor(.red.opacity(0.7))
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())

            // Expandable editor
            if editingIndex == idx {
                serverEditor(idx: idx)
                    .padding(.leading, 20)
                    .padding(.top, 8)
            }
        }
    }

    private func statusIndicator(for status: ServerStatus?, disabled: Bool) -> some View {
        let color: Color
        if disabled {
            color = .gray
        } else if let status = status {
            if status.failed { color = .red }
            else if status.connected { color = .green }
            else { color = .yellow }
        } else {
            color = .gray
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func commandPreview(_ cfg: MCPServerConfig) -> String {
        let args = cfg.arguments.joined(separator: " ")
        return args.isEmpty ? cfg.command : "\(cfg.command) \(args)"
    }

    // MARK: - Inline editor

    @ViewBuilder
    private func serverEditor(idx: Int) -> some View {
        let binding = $servers[idx]
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "Command (e.g. npx, uvx, /abs/path)",
                text: Binding(
                    get: { binding.wrappedValue.command },
                    set: { newValue in replaceConfigAndDisable(at: binding, idx: idx, command: newValue) }
                )
            )
            .textFieldStyle(.roundedBorder)

            argumentsEditor(binding: binding, idx: idx)
            envEditor(binding: binding, idx: idx)
            secretRefsEditor(binding: binding, idx: idx)

            // Description field — shown to the LLM when this server is set
            // to "deferred" for an agent (configured in the Agents tab).
            VStack(alignment: .leading, spacing: 4) {
                Text("Description — shown to the LLM when this server is deferred for an agent. Auto-generated from tool names if left blank.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(
                    "e.g. Browser automation and web scraping",
                    text: Binding(
                        get: { binding.wrappedValue.description ?? "" },
                        set: { newValue in
                            replaceConfigAndDisable(at: binding, idx: idx, serverDescription: newValue.isEmpty ? nil : newValue)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            if let status = statusByServer[binding.wrappedValue.name],
               let reason = status.reason, !reason.isEmpty {
                Text("Last spawn failure: \(reason)")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func argumentsEditor(binding: Binding<MCPServerConfig>, idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arguments")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(
                "Space-separated",
                text: Binding(
                    get: { binding.wrappedValue.arguments.joined(separator: " ") },
                    set: { newValue in
                        let parts = newValue.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                        replaceConfigAndDisable(at: binding, idx: idx, arguments: parts)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func envEditor(binding: Binding<MCPServerConfig>, idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environment variables — KEY=value, one per line. Non-sensitive values only (these ARE saved in plain text).")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: Binding(
                get: { formatEnv(binding.wrappedValue.environment) },
                set: { newValue in
                    let parsed = parseEnv(newValue)
                    replaceConfigAndDisable(at: binding, idx: idx, environment: parsed)
                }
            ))
            .frame(height: 60)
            .font(.system(.caption, design: .monospaced))
            .border(Color.secondary.opacity(0.3))
        }
    }

    private func secretRefsEditor(binding: Binding<MCPServerConfig>, idx: Int) -> some View {
        let serverName = binding.wrappedValue.name
        let refs = binding.wrappedValue.secretRefs
        return VStack(alignment: .leading, spacing: 4) {
            Text("API keys & tokens — stored securely in your macOS Keychain, never written to config files.")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(refs, id: \.self) { ref in
                secretRow(server: serverName, ref: ref) {
                    replaceConfigAndDisable(at: binding, idx: idx, secretRefs: refs.filter { $0 != ref })
                }
            }
            HStack {
                TextField("Name a new secret (e.g. GITHUB_TOKEN)", text: newSecretDraft(for: serverName))
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let key = "newSecretDraft|\(serverName)"
                    let draft = (secretValues[key] ?? "").trimmingCharacters(in: .whitespaces)
                    guard !draft.isEmpty, !refs.contains(draft) else { return }
                    replaceConfigAndDisable(at: binding, idx: idx, secretRefs: refs + [draft])
                    secretValues[key] = ""
                }
            }
        }
    }

    @ViewBuilder
    private func secretRow(server: String, ref: String, onRemove: @escaping () -> Void) -> some View {
        let storageKey = "mcp_env_\(server)_\(ref)"
        let revealKey = "\(server)|\(ref)"
        HStack(spacing: 6) {
            Text(ref)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 120, alignment: .leading)
            if revealedSecrets.contains(revealKey) {
                TextField("secret value", text: Binding(
                    get: { secretValues[revealKey] ?? KeychainHelper.load(key: storageKey) ?? "" },
                    set: { newValue in
                        secretValues[revealKey] = newValue
                        try? KeychainHelper.save(key: storageKey, value: newValue)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                SecureField("•••••••• (click eye to edit)", text: Binding(
                    get: { secretValues[revealKey] ?? KeychainHelper.load(key: storageKey) ?? "" },
                    set: { newValue in
                        secretValues[revealKey] = newValue
                        try? KeychainHelper.save(key: storageKey, value: newValue)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            Button {
                if revealedSecrets.contains(revealKey) {
                    revealedSecrets.remove(revealKey)
                } else {
                    revealedSecrets.insert(revealKey)
                }
            } label: {
                Image(systemName: revealedSecrets.contains(revealKey) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                try? KeychainHelper.delete(key: storageKey)
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func newSecretDraft(for server: String) -> Binding<String> {
        Binding(
            get: { secretValues["newSecretDraft|\(server)"] ?? "" },
            set: { secretValues["newSecretDraft|\(server)"] = $0 }
        )
    }

    // MARK: - Mutation helpers (preserve server name identity)

    private func updateServer(idx: Int, newDisabled: Bool) {
        let old = servers[idx]
        servers[idx] = MCPServerConfig(
            name: old.name,
            command: old.command,
            arguments: old.arguments,
            environment: old.environment,
            disabled: newDisabled,
            secretRefs: old.secretRefs,
            description: old.description
        )
    }

    /// Edit a config field AND auto-disable the server so the user sees it
    /// flip to OFF — they click ON when ready, which saves and reconnects.
    private func replaceConfigAndDisable(
        at binding: Binding<MCPServerConfig>,
        idx: Int,
        command: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String]? = nil,
        secretRefs: [String]? = nil,
        serverDescription: String?? = nil
    ) {
        let old = binding.wrappedValue
        let newDesc: String?
        if let outer = serverDescription {
            newDesc = outer
        } else {
            newDesc = old.description
        }
        binding.wrappedValue = MCPServerConfig(
            name: old.name,
            command: command ?? old.command,
            arguments: arguments ?? old.arguments,
            environment: environment ?? old.environment,
            disabled: true,
            secretRefs: secretRefs ?? old.secretRefs,
            description: newDesc
        )
    }

    /// Persist the current server list to disk and restart all MCPs.
    private func saveAndReconnect() async {
        do {
            try MCPRegistry.saveConfigsToDisk(servers)
            await MCPRegistry.shared.reloadFromDisk()
            await MCPAgentRouting.refreshFromRegistry()
            await reload()
        } catch {
            errorNote = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Env parsing

    private func formatEnv(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }

    private func parseEnv(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    // MARK: - Load / Apply

    private func reload() async {
        isLoading = true
        errorNote = nil
        servers = MCPRegistry.loadConfigsFromDisk()
        let status = await MCPRegistry.shared.status()
        var map: [String: ServerStatus] = [:]
        for entry in status {
            map[entry.name] = ServerStatus(
                connected: entry.connected,
                failed: entry.failed,
                reason: entry.reason,
                toolCount: entry.toolCount
            )
        }
        statusByServer = map
        isLoading = false
    }
}

// MARK: - Add MCP sheet

private struct AddMCPSheet: View {
    let existingNames: Set<String>
    let onAdd: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var args: String = ""
    @State private var selectedTemplate: Template = .custom

    enum Template: String, CaseIterable, Identifiable {
        case custom = "Custom"
        case playwright = "Playwright (browser)"
        case github = "GitHub"
        case postgres = "Postgres"
        case sqlite = "SQLite"

        var id: String { rawValue }

        var config: (name: String, command: String, args: String)? {
            switch self {
            case .custom: return nil
            case .playwright:
                return ("playwright", "npx", "@playwright/mcp@latest")
            case .github:
                return ("github", "npx", "@modelcontextprotocol/server-github")
            case .postgres:
                return ("postgres", "npx", "@modelcontextprotocol/server-postgres postgresql://user:pass@localhost/db")
            case .sqlite:
                return ("sqlite", "uvx", "mcp-server-sqlite --db-path /path/to/db.sqlite")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a new MCP server")
                    .font(.title3.weight(.semibold))
                Text("Pick a preset from the list to pre-fill the fields, or choose “Custom” to type your own.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Preset")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Preset", selection: $selectedTemplate) {
                    ForEach(Template.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedTemplate) { newValue in
                    if let cfg = newValue.config {
                        if name.isEmpty { name = cfg.name }
                        command = cfg.command
                        args = cfg.args
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Server name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. playwright", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command to run")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. npx, uvx", text: $command)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (space-separated)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. @playwright/mcp@latest", text: $args)
                    .textFieldStyle(.roundedBorder)
            }

            if existingNames.contains(name) {
                Label("A server named '\(name)' already exists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("The server will be added and connected immediately. You can set API keys and tokens in the server's details once it's listed.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.large)
                Button {
                    let cfg = MCPServerConfig(
                        name: name.trimmingCharacters(in: .whitespaces),
                        command: command.trimmingCharacters(in: .whitespaces),
                        arguments: args.split(separator: " ", omittingEmptySubsequences: true).map(String.init),
                        environment: [:],
                        disabled: false,
                        secretRefs: []
                    )
                    onAdd(cfg)
                } label: {
                    Label("Add server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(name.isEmpty || command.isEmpty || existingNames.contains(name))
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
