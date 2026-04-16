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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                agentTilesSection
                selectedAgentCard
                capabilitiesCard
                modelCard
                mcpCard
                if selectedAgent != "main" { sessionMemoryCard }
                footerActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
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

    // MARK: - Hero header

    private var heroHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.title.weight(.semibold))
                Text("Configure each AI agent: its model, its tools, and which MCPs it can access.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                editorMode = .create
                editorInitialDraft = nil
                showingEditorSheet = true
            } label: {
                Label("New Agent", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Agent tile picker

    private var agentTilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select an agent to configure")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(agents, id: \.name) { agent in
                        agentTile(agent)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func agentTile(_ agent: AgentRow) -> some View {
        let isSelected = agent.name == selectedAgent
        Button {
            if selectedAgent != agent.name {
                isDirty = false
                selectedAgent = agent.name
                loadWorkingSet(for: agent.name)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: iconFor(agent: agent))
                        .font(.title3)
                        .foregroundColor(isSelected ? .white : .accentColor)
                    Text(agent.displayShortName)
                        .font(.body.weight(.semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                }
                Text(agent.originTag)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 140, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconFor(agent: AgentRow) -> String {
        if agent.name == "main" { return "person.crop.circle.fill" }
        if !agent.isUserDefined { return "cube.fill" }
        return "wand.and.stars"
    }

    // MARK: - Selected agent card

    @ViewBuilder
    private var selectedAgentCard: some View {
        if let agent = agents.first(where: { $0.name == selectedAgent }) {
            cardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: iconFor(agent: agent))
                                    .foregroundColor(.accentColor)
                                Text(agent.displayShortName)
                                    .font(.title3.weight(.semibold))
                            }
                            if let origin = agent.originLabel {
                                Text(origin)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if agent.isUserDefined {
                            HStack(spacing: 6) {
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
                                }
                                .buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    pendingDeleteName = agent.name
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Text(agent.description)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Capabilities (built-in tools)

    private var capabilitiesCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("Built-in capabilities", systemImage: "hammer.fill",
                          subtitle: selectedAgent == "main"
                              ? "What this agent can do natively."
                              : "Native tools this subagent inherits. Edit via the Edit button to change.")
                nativeToolsView
            }
        }
    }

    // MARK: - Model card

    private var modelCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("AI model & reasoning", systemImage: "cpu",
                          subtitle: selectedAgent == "main"
                              ? "Main agent's model is configured in Settings → Connection."
                              : "Pick the model and reasoning effort for this subagent. Leave empty to use the default.")
                modelOverrideView
            }
        }
    }

    // MARK: - MCP card

    private var mcpCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("External tools (MCPs)", systemImage: "app.connected.to.app.below.fill",
                          subtitle: "Toggle which external tool servers \(selectedAgentShortName) can use. Changes are per-agent — the toggles below apply only to this agent.")

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading MCP servers…")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                } else if serverTools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No MCP servers installed yet", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundColor(.orange)
                        Text("To add external tools (Playwright for browsing, GitHub, Postgres, etc.), go to the MCPs tab and install a server first. Once installed, it'll appear here and you can enable its tools for this agent.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(serverTools.keys.sorted(), id: \.self) { server in
                            mcpServerPanel(server: server)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("Need more MCPs? Install them from the MCPs tab — they'll appear here afterward.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Session memory card

    private var sessionMemoryCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Session memory budget", systemImage: "brain.head.profile",
                          subtitle: "When a subagent's conversation grows past this size, oldest messages are trimmed so it stays usable. Applies globally to all subagents.")
                HStack(spacing: 10) {
                    TextField("100000", text: $sessionTokenBudget)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .font(.body.monospacedDigit())
                        .onChange(of: sessionTokenBudget) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            if let val = Int(trimmed), val > 0 {
                                try? KeychainHelper.save(key: KeychainHelper.subagentSessionTokenBudgetKey, value: trimmed)
                            }
                        }
                    Text("tokens")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("default 100,000")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Footer actions

    private var footerActions: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("MCP changes",
                          systemImage: "arrow.triangle.2.circlepath",
                          subtitle: "Model and memory settings above auto-save as you edit. MCP tool toggles require an explicit Apply below so you can batch multiple changes before committing them.")

                HStack(spacing: 10) {
                    Button {
                        saveRouting()
                    } label: {
                        Label("Apply MCP changes", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!isDirty)

                    Button {
                        loadWorkingSet(for: selectedAgent)
                        isDirty = false
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!isDirty)

                    Button {
                        Task { await reload() }
                    } label: {
                        Label("Refresh MCPs", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Re-query installed MCP servers and their tool catalogue.")
                }

                if let note = statusNote {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundColor(.green)
                } else if let err = errorNote {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.red)
                }

                Text(editingConfigPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var selectedAgentShortName: String {
        agents.first(where: { $0.name == selectedAgent })?.displayShortName ?? selectedAgent
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

    // MARK: - Agent picker + metadata (legacy helpers kept for compatibility)

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

    /// Compact label shown inside an agent tile — drops the "Subagent:" prefix
    /// the dropdown used.
    var displayShortName: String { name }

    /// One-word origin tag rendered under the tile name.
    var originTag: String {
        guard let origin = originLabel else { return "" }
        if origin.contains("user-defined") { return "custom" }
        if origin.contains("dynamic") { return "dynamic" }
        if origin.contains("built-in") { return "built-in" }
        return origin
    }
}
