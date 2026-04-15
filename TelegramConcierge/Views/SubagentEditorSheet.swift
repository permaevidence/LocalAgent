import SwiftUI

/// Sheet for creating or editing a user-defined subagent.
///
/// Driven by a `SubagentEditorDraft`. On save, serialises to
/// `~/LocalAgent/agents/<name>.md` via `SubagentSerializer.save(...)`.
/// Built-in subagents are not editable via this flow — their definitions
/// live in Swift.
struct SubagentEditorSheet: View {

    enum Mode: Equatable {
        case create
        case edit(originalName: String)
    }

    let mode: Mode
    let availableNativeTools: [String]
    let availableMcpServers: [String]
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: SubagentEditorDraft = .blank()
    @State private var selectedTemplate: String = "custom"
    @State private var nativeToolsSelection: Set<String> = []
    @State private var mcpPatternsDraft: String = ""       // one pattern per line
    @State private var errorMessage: String?
    @State private var warning: String?

    init(
        mode: Mode,
        availableNativeTools: [String],
        availableMcpServers: [String],
        initialDraft: SubagentEditorDraft? = nil,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.availableNativeTools = availableNativeTools.sorted()
        self.availableMcpServers = availableMcpServers.sorted()
        self.onSave = onSave
        self.onCancel = onCancel
        if let d = initialDraft {
            _draft = State(initialValue: d)
            _nativeToolsSelection = State(initialValue: Set(d.nativeTools ?? []))
            _mcpPatternsDraft = State(initialValue: (d.mcpToolPatterns ?? []).joined(separator: "\n"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .create = mode { templatePicker }
                    identitySection
                    systemPromptSection
                    nativeToolsSection
                    mcpToolsSection
                    modelAndTurnsSection
                    if let warning = warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    if let err = errorMessage {
                        Label(err, systemImage: "exclamationmark.octagon.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(16)
            }
            Divider()
            footerBar
        }
        .frame(width: 620, height: 680)
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var title: String {
        switch mode {
        case .create: return "New subagent"
        case .edit(let name): return "Edit subagent: \(name)"
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start from template")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Template", selection: $selectedTemplate) {
                ForEach(SubagentTemplates.all) { t in
                    Text(t.displayName).tag(t.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: selectedTemplate) { newValue in
                if let t = SubagentTemplates.all.first(where: { $0.id == newValue }) {
                    draft = t.draft
                    nativeToolsSelection = Set(t.draft.nativeTools ?? [])
                    mcpPatternsDraft = (t.draft.mcpToolPatterns ?? []).joined(separator: "\n")
                }
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name (kebab-case, unique)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("e.g. browser-use", text: Binding(
                get: { draft.name },
                set: { draft.name = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(isEditingExisting)

            Text("Description (one line — the main agent sees this when deciding to delegate)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
            TextField("What does this agent do?", text: Binding(
                get: { draft.description },
                set: { draft.description = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var isEditingExisting: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System prompt (sent as the subagent's role instructions)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: Binding(
                get: { draft.systemPrompt },
                set: { draft.systemPrompt = $0 }
            ))
            .frame(minHeight: 140)
            .font(.system(.body, design: .default))
            .border(Color.secondary.opacity(0.3))
        }
    }

    private var nativeToolsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Native tools (leave all unchecked to inherit everything the main agent has)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("All") {
                    nativeToolsSelection = Set(availableNativeTools)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("None") {
                    nativeToolsSelection = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 4) {
                ForEach(availableNativeTools, id: \.self) { tool in
                    Toggle(isOn: Binding(
                        get: { nativeToolsSelection.contains(tool) },
                        set: { v in
                            if v { nativeToolsSelection.insert(tool) } else { nativeToolsSelection.remove(tool) }
                        }
                    )) {
                        Text(tool)
                            .font(.caption)
                            .monospaced()
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(4)
        }
    }

    private var mcpToolsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MCP tool patterns (one per line — mcp__<server>__* or exact names)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !availableMcpServers.isEmpty {
                    Menu("Add server glob") {
                        ForEach(availableMcpServers, id: \.self) { server in
                            Button("mcp__\(server)__*") {
                                appendPattern("mcp__\(server)__*")
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            TextEditor(text: $mcpPatternsDraft)
                .frame(minHeight: 70)
                .font(.system(.caption, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            Text("These become default MCP access for this subagent. They can still be overridden per-agent via the Agents tab or ~/LocalAgent/mcp-routing.json.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelAndTurnsSection: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Model", selection: Binding(
                    get: { draft.model },
                    set: { draft.model = $0 }
                )) {
                    Text("inherit (parent's model)").tag("inherit")
                    Text("cheapFast (Gemini Flash)").tag("cheapFast")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Max turns")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("20", value: Binding(
                    get: { draft.maxTurns },
                    set: { draft.maxTurns = max(1, min($0, 200)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }

            Spacer()
        }
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Save") {
                commitSave()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!validate())
        }
        .padding(16)
    }

    // MARK: - Validation + save

    private func validate() -> Bool {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { return false }
        if draft.description.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if draft.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func commitSave() {
        let nameTrim = draft.name.trimmingCharacters(in: .whitespaces)
        let filenameSafe = SubagentSerializer.sanitizeFilename(nameTrim)
        guard !filenameSafe.isEmpty else {
            errorMessage = "Name must include at least one letter or digit."
            return
        }

        // Collision check for create mode
        if case .create = mode {
            let existing = SubagentSerializer.listUserDefinedFiles()
            if existing.contains(where: { $0.lastPathComponent.lowercased() == "\(filenameSafe.lowercased()).md" }) {
                errorMessage = "An agent named '\(filenameSafe)' already exists."
                return
            }
            let builtInNames = SubagentTypes.builtIns.map { $0.name.lowercased() } + ["main"]
            if builtInNames.contains(filenameSafe.lowercased()) {
                errorMessage = "'\(filenameSafe)' is a built-in name. Pick a different name."
                return
            }
        }

        let patterns = mcpPatternsDraft
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let nativeTools: [String]? = nativeToolsSelection.isEmpty ? nil : Array(nativeToolsSelection)

        // Soft warnings — don't block save, but flag odd combinations.
        if draft.systemPrompt.contains("bash") && !(nativeTools?.contains("bash") ?? true) && nativeToolsSelection != [] {
            warning = "Prompt mentions bash but it's not in the native tool whitelist. Continuing anyway."
        }

        do {
            try SubagentSerializer.save(
                name: filenameSafe,
                description: draft.description.trimmingCharacters(in: .whitespaces),
                systemPrompt: draft.systemPrompt,
                nativeTools: nativeTools,
                mcpToolPatterns: patterns.isEmpty ? nil : patterns,
                model: draft.model,
                maxTurns: draft.maxTurns
            )
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            return
        }

        // If editing and the name changed, delete the old file.
        if case .edit(let originalName) = mode, originalName != filenameSafe {
            SubagentSerializer.delete(name: originalName)
        }

        onSave(filenameSafe)
    }

    private func appendPattern(_ pattern: String) {
        if mcpPatternsDraft.isEmpty {
            mcpPatternsDraft = pattern
        } else if !mcpPatternsDraft.contains(pattern) {
            mcpPatternsDraft = mcpPatternsDraft + "\n" + pattern
        }
    }
}
