import SwiftUI

/// Agent-centric MCP tool routing panel.
///
/// Phase 3 of the MCP rollout. Lets the user pick an agent (main, built-in
/// subagent, user-defined subagent) and toggle which MCP tools it's allowed
/// to see. Native tools are listed read-only — editing them happens in
/// `~/LocalAgent/agents/*.md` (user-defined) or the subagent definition
/// (built-in). Routing changes persist to `~/LocalAgent/mcp-routing.json`.
///
/// Two granularities:
///   - Whole-MCP toggle (every tool from a server at once)
///   - Per-tool checkbox (fine-grained)
///
/// Routing patterns stored on save:
///   - If a server is fully enabled → `mcp__<server>__*` (one-line glob)
///   - If a partial subset → exact `mcp__<server>__<tool>` entries
///   - If nothing enabled → entry omitted
struct AgentsSettingsView: View {

    // MARK: - State

    @State private var agents: [AgentRow] = []
    @State private var selectedAgent: String = "main"

    /// Per-server tool catalogue discovered from MCPRegistry.
    /// [serverName: [prefixedToolName]]
    @State private var serverTools: [String: [String]] = [:]

    /// Current routing config on disk, keyed by agent name.
    @State private var routingConfig: [String: [String]] = [:]

    /// Per-server enabled-tool sets for the selected agent (working copy).
    /// [serverName: Set<prefixedToolName>]
    @State private var workingSet: [String: Set<String>] = [:]

    /// Dirty flag — did the user change anything since last save / load?
    @State private var isDirty: Bool = false

    @State private var statusNote: String?
    @State private var errorNote: String?
    @State private var isLoading: Bool = true

    // Subagent editor sheet
    @State private var showingEditorSheet: Bool = false
    @State private var editorMode: SubagentEditorSheet.Mode = .create
    @State private var editorInitialDraft: SubagentEditorDraft? = nil
    @State private var showingDeleteConfirmation: Bool = false
    @State private var pendingDeleteName: String? = nil
    @State private var sessionTokenBudget: String = ""

    // Per-agent model override draft state — updated when the user types.
    // Keyed by agent name so switching agents preserves unsaved drafts per-agent.
    @State private var modelDrafts: [String: String] = [:]
    @State private var reasoningDrafts: [String: String] = [:]
    @State private var modelSaveNote: String?

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                agentPicker
                agentDescription
                agentActionsRow
            } header: {
                HStack {
                    Label("Agent", systemImage: "person.2.wave.2")
                    Spacer()
                    Button {
                        editorMode = .create
                        editorInitialDraft = nil
                        showingEditorSheet = true
                    } label: {
                        Label("New Agent", systemImage: "plus.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                nativeToolsView
            } header: {
                Label("Native tools (read-only)", systemImage: "hammer")
            }

            Section {
                modelOverrideView
            } header: {
                Label("Model & reasoning", systemImage: "cpu")
            }

            Section {
                if isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading MCP servers…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if serverTools.isEmpty {
                    Text("No MCP servers configured. Edit ~/LocalAgent/mcp.json to install one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(serverTools.keys.sorted(), id: \.self) { server in
                        mcpServerPanel(server: server)
                    }
                }
            } header: {
                Label("MCP tool access", systemImage: "gear.badge")
            }

            Section {
                HStack(spacing: 8) {
                    Text("Session token budget")
                        .font(.caption)
                    TextField("100000", text: $sessionTokenBudget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: sessionTokenBudget) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            if let val = Int(trimmed), val > 0 {
                                try? KeychainHelper.save(key: KeychainHelper.subagentSessionTokenBudgetKey, value: trimmed)
                            }
                        }
                    Text("tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Text("Max context size for a subagent session before older messages are trimmed on resume. Default 100k.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Session context", systemImage: "text.badge.minus")
            }

            Section {
                HStack {
                    Button("Save routing") {
                        saveRouting()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)

                    Button("Revert") {
                        loadWorkingSet(for: selectedAgent)
                        isDirty = false
                    }
                    .disabled(!isDirty)

                    Button("Reload MCPs") {
                        Task { await reload() }
                    }

                    Spacer()

                    if let note = statusNote {
                        Label(note, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else if let err = errorNote {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Text(editingConfigPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .task {
            sessionTokenBudget = KeychainHelper.load(key: KeychainHelper.subagentSessionTokenBudgetKey)
                ?? String(KeychainHelper.defaultSubagentSessionTokenBudget)
            await reload()
        }
        .sheet(isPresented: $showingEditorSheet) {
            SubagentEditorSheet(
                mode: editorMode,
                availableNativeTools: AvailableTools.all(includeWebSearch: true)
                    .map { $0.function.name }
                    .filter { $0 != "Agent" },
                availableMcpServers: Array(serverTools.keys),
                initialDraft: editorInitialDraft,
                onSave: { savedName in
                    showingEditorSheet = false
                    statusNote = "Saved agent '\(savedName)'"
                    errorNote = nil
                    Task {
                        await reload()
                        selectedAgent = savedName
                        loadWorkingSet(for: savedName)
                    }
                },
                onCancel: {
                    showingEditorSheet = false
                }
            )
        }
        .alert("Delete subagent?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { pendingDeleteName = nil }
            Button("Delete", role: .destructive) {
                if let name = pendingDeleteName {
                    SubagentSerializer.delete(name: name)
                    // Also purge its routing entry.
                    var cfg = MCPAgentRouting.currentConfig()
                    cfg.removeValue(forKey: name)
                    try? MCPAgentRouting.save(config: cfg)
                    pendingDeleteName = nil
                    Task {
                        await reload()
                        selectedAgent = "main"
                        loadWorkingSet(for: "main")
                        statusNote = "Deleted subagent"
                    }
                }
            }
        } message: {
            Text("Removes ~/LocalAgent/agents/\(pendingDeleteName ?? "?").md and its entry from mcp-routing.json. Cannot be undone.")
        }
    }

    // MARK: - Agent picker + metadata

    private var agentPicker: some View {
        Picker("Agent", selection: $selectedAgent) {
            ForEach(agents, id: \.name) { agent in
                Text(agent.displayLabel)
                    .tag(agent.name)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedAgent) { newValue in
            if isDirty {
                // Discard unsaved changes — the revert button exists for undo.
                isDirty = false
            }
            loadWorkingSet(for: newValue)
        }
    }

    @ViewBuilder
    private var agentActionsRow: some View {
        if let agent = agents.first(where: { $0.name == selectedAgent }), agent.isUserDefined {
            HStack(spacing: 10) {
                Button {
                    if let draft = SubagentSerializer.loadForEditing(name: agent.name) {
                        editorMode = .edit(originalName: agent.name)
                        editorInitialDraft = draft
                        showingEditorSheet = true
                    } else {
                        errorNote = "Couldn't load \(agent.name) for editing."
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    pendingDeleteName = agent.name
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var agentDescription: some View {
        if let agent = agents.first(where: { $0.name == selectedAgent }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let origin = agent.originLabel {
                    Text(origin)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Model / reasoning override

    @ViewBuilder
    private var modelOverrideView: some View {
        if selectedAgent == "main" {
            Text("Main agent's model is configured in Settings → Connection. This section controls subagent overrides only.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            let agent = selectedAgent
            let typeDefault = defaultLabel(for: agent)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model (OpenRouter slug; 'inherit' = parent's model; empty = use default)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(typeDefault.model, text: Binding(
                        get: { modelDrafts[agent] ?? "" },
                        set: { newValue in
                            modelDrafts[agent] = newValue
                            saveModelOverride(for: agent)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Reasoning effort")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Reasoning effort", selection: Binding(
                        get: { reasoningDrafts[agent] ?? "" },
                        set: { newValue in
                            reasoningDrafts[agent] = newValue
                            saveModelOverride(for: agent)
                        }
                    )) {
                        Text("Default (\(typeDefault.reasoning))").tag("")
                        Text("none").tag("none")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if let note = modelSaveNote {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                Text("Default for \(agent): model '\(typeDefault.model)', reasoning '\(typeDefault.reasoning)'. Leave both fields empty to inherit these defaults.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Display the currently-effective default for an agent so the user sees
    /// what they'd get with no override in place.
    private func defaultLabel(for agent: String) -> (model: String, reasoning: String) {
        guard let subagent = SubagentTypes.find(name: agent) else {
            return ("inherit", "inherit")
        }
        switch subagent.preferredModel {
        case .cheapFast:
            return (SubagentModelProfile.cheapFastModel, SubagentModelProfile.cheapFastReasoningEffort)
        case .inherit:
            return ("inherit (parent's model)", "inherit (parent's reasoning)")
        }
    }

    private func saveModelOverride(for agent: String) {
        var current = AgentModelOverrides.currentOverrides()
        let modelDraft = (modelDrafts[agent] ?? "").trimmingCharacters(in: .whitespaces)
        let reasoningDraft = (reasoningDrafts[agent] ?? "").trimmingCharacters(in: .whitespaces)

        if modelDraft.isEmpty && reasoningDraft.isEmpty {
            current.removeValue(forKey: agent)
        } else {
            current[agent] = AgentModelOverrides.Override(
                model: modelDraft.isEmpty ? nil : modelDraft,
                reasoningEffort: reasoningDraft.isEmpty ? nil : reasoningDraft
            )
        }

        do {
            try AgentModelOverrides.save(current)
            modelSaveNote = "Saved override for \(agent)"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if modelSaveNote?.contains("Saved") == true {
                    modelSaveNote = nil
                }
            }
        } catch {
            modelSaveNote = nil
            errorNote = "Save failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var nativeToolsView: some View {
        if let agent = agents.first(where: { $0.name == selectedAgent }) {
            if agent.name == "main" {
                Text("Main agent always has access to every native tool (filesystem, bash, web, LSP, Agent delegation, reminders, etc.).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let native = agent.allowedNativeTools {
                let sorted = native.sorted()
                Text(sorted.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Inherits every native tool the main agent has (minus Agent recursion).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - MCP server panel

    @ViewBuilder
    private func mcpServerPanel(server: String) -> some View {
        let tools = serverTools[server] ?? []
        let enabled = workingSet[server] ?? []
        let allOn = !tools.isEmpty && enabled.count == tools.count
        let partial = !enabled.isEmpty && !allOn

        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tools, id: \.self) { tool in
                    Toggle(isOn: Binding(
                        get: { enabled.contains(tool) },
                        set: { newValue in
                            var next = workingSet[server] ?? []
                            if newValue { next.insert(tool) } else { next.remove(tool) }
                            workingSet[server] = next
                            isDirty = true
                        }
                    )) {
                        Text(toolShortName(tool))
                            .font(.caption)
                            .monospaced()
                    }
                    .toggleStyle(.checkbox)
                }
                if tools.isEmpty {
                    Text("This server has no tools advertised (yet).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, 20)
        } label: {
            HStack {
                Toggle(isOn: Binding(
                    get: { allOn },
                    set: { newValue in
                        if newValue {
                            workingSet[server] = Set(tools)
                        } else {
                            workingSet[server] = []
                        }
                        isDirty = true
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(server)
                            .font(.body.weight(.medium))
                        Text("\(enabled.count) / \(tools.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if partial {
                            Image(systemName: "minus.square.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
        }
    }

    private var editingConfigPath: String {
        let home = NSHomeDirectory()
        return "Routing file: \(home)/LocalAgent/mcp-routing.json"
    }

    // MARK: - Data loading

    private func reload() async {
        isLoading = true
        statusNote = nil
        errorNote = nil

        // 1) Refresh MCPAgentRouting cache so dynamic subagents (Browse/DB)
        //    reflect the current registry state.
        await MCPAgentRouting.refreshFromRegistry()

        // 2) Fetch the full MCP tool surface grouped by server.
        let allTools = await MCPRegistry.shared.allToolDefinitions()
        var byServer: [String: [String]] = [:]
        for tool in allTools {
            guard let (server, _) = MCPRegistry.splitPrefixedName(tool.function.name) else { continue }
            byServer[server, default: []].append(tool.function.name)
        }
        for key in byServer.keys {
            byServer[key]?.sort()
        }

        // 3) Build agent list.
        var rows: [AgentRow] = []
        rows.append(AgentRow(
            name: "main",
            displayLabel: "Main agent",
            description: "The primary assistant that talks to you. By default has no MCP tools — opt them in below only for capabilities you want always-on.",
            originLabel: "built-in",
            allowedNativeTools: nil,
            isUserDefined: false
        ))
        for subagent in SubagentTypes.all() {
            let isStatic = SubagentTypes.staticBuiltIns.contains { $0.name == subagent.name }
            let isDynamic = SubagentTypes.activeDynamicBuiltIns().contains { $0.name == subagent.name }
            let userDefined = !isStatic && !isDynamic
            rows.append(AgentRow(
                name: subagent.name,
                displayLabel: "Subagent: \(subagent.name)",
                description: subagent.description,
                originLabel: isStatic
                    ? "built-in"
                    : (isDynamic
                        ? "dynamic built-in (active because backing MCP is installed)"
                        : "user-defined (~/LocalAgent/agents/\(subagent.name).md)"),
                allowedNativeTools: subagent.allowedToolNames,
                isUserDefined: userDefined
            ))
        }

        // 4) Load routing config from disk.
        let cfg = MCPAgentRouting.currentConfig()

        agents = rows
        serverTools = byServer
        routingConfig = cfg
        loadWorkingSet(for: selectedAgent)
        isLoading = false
    }

    /// Build the per-server working set from the routing config for `agent`.
    /// Pattern expansion rules:
    ///   - `mcp__<server>__*`  → every tool the server currently advertises
    ///   - `mcp__*`            → every tool on every server
    ///   - exact               → that one tool
    private func loadWorkingSet(for agent: String) {
        var set: [String: Set<String>] = [:]
        let patterns = routingConfig[agent]
            ?? routingConfig[caseInsensitiveKey(agent, in: routingConfig) ?? ""]
            ?? []
        for (server, tools) in serverTools {
            var enabled: Set<String> = []
            for tool in tools {
                if patterns.contains(where: { MCPAgentRouting.matches(pattern: $0, name: tool) }) {
                    enabled.insert(tool)
                }
            }
            set[server] = enabled
        }
        workingSet = set
        isDirty = false

        // Load the agent's model override (if any) into the edit drafts so the
        // Model/Reasoning fields show what's currently saved.
        if let override = AgentModelOverrides.override(forAgent: agent) {
            modelDrafts[agent] = override.model ?? ""
            reasoningDrafts[agent] = override.reasoningEffort ?? ""
        } else {
            modelDrafts[agent] = ""
            reasoningDrafts[agent] = ""
        }
    }

    private func caseInsensitiveKey(_ k: String, in d: [String: [String]]) -> String? {
        let lower = k.lowercased()
        return d.keys.first { $0.lowercased() == lower }
    }

    // MARK: - Save

    /// Compact the working set into a routing entry:
    ///   - whole server enabled → single `mcp__<server>__*` glob
    ///   - partial → exact names
    ///   - none → omit
    private func saveRouting() {
        var patterns: [String] = []
        for server in serverTools.keys.sorted() {
            let enabled = workingSet[server] ?? []
            let total = serverTools[server]?.count ?? 0
            guard !enabled.isEmpty else { continue }
            if enabled.count == total, total > 0 {
                patterns.append("mcp__\(server)__*")
            } else {
                patterns.append(contentsOf: enabled.sorted())
            }
        }

        var next = routingConfig
        if patterns.isEmpty {
            next.removeValue(forKey: selectedAgent)
        } else {
            next[selectedAgent] = patterns
        }

        do {
            try MCPAgentRouting.save(config: next)
            routingConfig = next
            isDirty = false
            statusNote = "Saved routing for \(selectedAgent)"
            errorNote = nil
            // Auto-clear success note after 3 seconds.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if statusNote?.contains("Saved") == true {
                    statusNote = nil
                }
            }
        } catch {
            errorNote = "Save failed: \(error.localizedDescription)"
            statusNote = nil
        }
    }

    // MARK: - Helpers

    private func toolShortName(_ prefixed: String) -> String {
        guard let (_, tool) = MCPRegistry.splitPrefixedName(prefixed) else { return prefixed }
        return tool
    }
}

/// One row in the agent picker.
private struct AgentRow {
    let name: String                 // Key used in mcp-routing.json
    let displayLabel: String
    let description: String
    let originLabel: String?
    let allowedNativeTools: Set<String>?
    let isUserDefined: Bool
}
