import SwiftUI
import AppKit

/// Skills management panel.
///
/// Skills are hand-curated procedural guides in `~/LocalAgent/skills/*.md`.
/// The agent cannot create or edit them — users author them directly in a
/// text editor. This panel is a read-only browser plus a delete button and
/// a "Reveal in Finder" shortcut.
///
/// Per Matteo's design brief:
///   - Few and high-quality skills, not a bloated catalogue
///   - Agent may auto-load a skill when it detects a match, but may never
///     create one
///   - Visible in the same settings window as Agents and MCPs
struct SkillsSettingsView: View {

    // MARK: - State

    @State private var skills: [SkillsRegistry.Skill] = []
    @State private var selectedName: String? = nil
    @State private var showingDeleteConfirmation = false
    @State private var pendingDeleteName: String? = nil
    @State private var errorNote: String?
    @State private var statusNote: String?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                notesSection
                skillTilesSection
                selectedSkillCard
                footerActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task { await reload() }
        .alert("Delete skill?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { pendingDeleteName = nil }
            Button("Delete", role: .destructive) {
                if let name = pendingDeleteName, SkillsRegistry.delete(name) {
                    pendingDeleteName = nil
                    Task {
                        await reload()
                        statusNote = "Deleted skill"
                    }
                } else {
                    errorNote = "Delete failed"
                }
            }
        } message: {
            Text("Removes ~/LocalAgent/skills/\(pendingDeleteName ?? "?").md. The agent loses access to this procedural guide on the next session.")
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills")
                    .font(.title.weight(.semibold))
                Text("Curated procedural guides the agent can load on demand for specialized tasks.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                revealSkillsFolder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Notes section

    private var notesSection: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Label("How skills work", systemImage: "lightbulb")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Two kinds: **Built-in** (ships with the app, travels with the binary — no setup needed) and **User** (markdown files you drop in `~/LocalAgent/skills/`).")
                    Text("• Both use YAML frontmatter (`name`, `description`) plus a markdown body with the procedure.")
                    Text("• The agent sees a compact index (name + description) in its system prompt. When a task matches, it calls the `skill` tool to pull the full body into context.")
                    Text("• You curate them manually — the agent cannot create or modify skills. Keep them short (1-3 KB ideal) and high-quality: every loaded skill stays in the conversation for the rest of the session.")
                    Text("• A user skill with the same name as a built-in overrides it. Add / edit / remove user skills by managing files in the skills folder or via the Delete button.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Skill tile picker

    private var skillTilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed skills (\(skills.count))")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if skills.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(skills) { skill in
                            skillTile(skill)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyState: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 6) {
                Label("No skills installed yet", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundColor(.orange)
                Text("Drop a markdown file with YAML frontmatter into `~/LocalAgent/skills/`, then click Refresh. Example skills: pdf, docx, xlsx, video-edit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func skillTile(_ skill: SkillsRegistry.Skill) -> some View {
        let isSelected = selectedName == skill.name
        Button {
            selectedName = skill.name
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: skill.origin == .bundled ? "cube.fill" : "wand.and.stars")
                        .foregroundColor(isSelected ? .white : .accentColor)
                    Text(skill.name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                }
                Text("\(skill.origin == .bundled ? "built-in" : "user") · \(skill.bodyByteCount) B")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 12)
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

    // MARK: - Selected skill detail

    @ViewBuilder
    private var selectedSkillCard: some View {
        if let selected = skills.first(where: { $0.name == selectedName }) {
            cardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                    .foregroundColor(.accentColor)
                                Text(selected.name)
                                    .font(.title3.weight(.semibold))
                            }
                            Text(selected.fileURL.path)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button {
                                NSWorkspace.shared.open(selected.fileURL)
                            } label: {
                                Label(selected.origin == .bundled ? "View" : "Open", systemImage: selected.origin == .bundled ? "eye" : "pencil")
                            }
                            .buttonStyle(.bordered)
                            if selected.origin == .user {
                                Button(role: .destructive) {
                                    pendingDeleteName = selected.name
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    if selected.origin == .bundled {
                        Label("Built-in skill — shipped with the app. To customize it, drop a same-named file in ~/LocalAgent/skills/ and it will override this one.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(selected.description)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text("Body preview")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(selected.body)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 240)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Spacer()
            if let note = statusNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if let note = errorNote {
                Label(note, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func reload() async {
        SkillsRegistry.ensureDirectoryExists()
        SkillsRegistry.reload()
        skills = SkillsRegistry.allSkills()
        if selectedName == nil, let first = skills.first {
            selectedName = first.name
        }
        if let name = selectedName, !skills.contains(where: { $0.name == name }) {
            selectedName = skills.first?.name
        }
    }

    private func revealSkillsFolder() {
        SkillsRegistry.ensureDirectoryExists()
        NSWorkspace.shared.selectFile(
            nil,
            inFileViewerRootedAtPath: SkillsRegistry.skillsDirectoryURL().path
        )
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.05))
            )
    }
}
