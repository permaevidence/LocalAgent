import Foundation

/// Skills registry — discovers and loads curated procedural "skills" from disk.
///
/// A skill is a single markdown file at `~/LocalAgent/skills/<name>.md` with
/// YAML frontmatter (name + description) and a markdown body that teaches
/// Claude how to perform a specialized task (e.g., generating a PDF, writing
/// a DOCX, editing a video).
///
/// Skills are NOT loaded into the system prompt — only an index (name +
/// description, one line each) is exposed at the tail of the system prefix.
/// When the agent decides a skill applies, it calls the `skill` tool with
/// the skill's name; the registry loads the body and returns it as a
/// tool_result. This keeps the frozen system prefix tiny while still giving
/// the agent access to detailed procedural memory on demand.
///
/// Why tool_result instead of injection into the system prompt:
///   - System-prompt mutation mid-session invalidates the Anthropic prompt
///     cache. Tool results are append-only and preserve the cache breakpoint.
///   - Skills persist in the message chain once loaded, so the procedure
///     stays available across multi-turn tasks (e.g., the render-verify-fix
///     loop of document generation).
///
/// File format:
/// ```
/// ---
/// name: pdf
/// description: Create polished PDF documents via HTML+CSS + weasyprint or chromium headless.
/// ---
///
/// # Body with workflow steps, templates, and examples.
/// ```
///
/// Per Matteo's hard constraint: the AGENT cannot create new skills on its
/// own — skills are hand-authored by the user and dropped into the directory.
/// The `skill` tool only READS, never writes.
enum SkillsRegistry {

    // MARK: - Types

    /// A parsed skill with its metadata and body content.
    struct Skill: Equatable, Identifiable {
        var id: String { name }

        /// Canonical short name — matches the filename stem and is how the
        /// agent invokes the skill via the `skill` tool.
        let name: String

        /// One-line description. Surfaced in the system-prompt index so the
        /// agent can decide whether to invoke this skill. Keep it focused on
        /// WHEN to use the skill, not what it does internally.
        let description: String

        /// Markdown body of the skill (everything after the frontmatter).
        /// Returned as the `skill` tool's result when invoked.
        let body: String

        /// Absolute path on disk — useful for the Settings UI (reveal, edit,
        /// delete).
        let fileURL: URL

        /// Size of the body in bytes — surfaced in the UI so the user sees
        /// which skills are bloated and should be trimmed.
        var bodyByteCount: Int { body.utf8.count }
    }

    // MARK: - Public API

    /// All skills currently on disk, sorted by name.
    ///
    /// Scans disk on every call. For small skill counts (typical: <10 files,
    /// each <10 KB) this is sub-millisecond, and avoids a whole class of
    /// "stale cache" bugs where a skill added during a running session never
    /// becomes visible to the agent until relaunch.
    static func allSkills() -> [Skill] {
        ensureDirectoryExists()
        return scanDisk()
    }

    /// Look up a skill by its canonical name. Case-insensitive.
    static func skill(named name: String) -> Skill? {
        let lower = name.lowercased()
        return allSkills().first { $0.name.lowercased() == lower }
    }

    /// No-op retained for API compatibility with call sites that used to
    /// invalidate a cache. The registry now scans on every call.
    static func reload() {}

    /// Delete a skill from disk. Called by the Settings UI.
    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard let skill = skill(named: name) else { return false }
        do {
            try FileManager.default.removeItem(at: skill.fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Compact index surfaced in the system prompt. One line per skill:
    /// `- <name>: <description>`. Bodies are NOT included — the agent must
    /// call the `skill` tool to pull the body into its context.
    ///
    /// Returns an empty string when no skills are installed, so the caller
    /// can skip the whole section without a conditional.
    static func systemPromptIndex() -> String {
        let skills = allSkills()
        guard !skills.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("**Skills available** (curated procedural memory). When the user's request matches a skill's description, invoke the `skill` tool with that name to load the full procedure into context before starting. Skills are reference material, not replacements for your own judgment.")
        lines.append("")
        for skill in skills {
            lines.append("- `\(skill.name)`: \(skill.description)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Disk scanning

    private static func scanDisk() -> [Skill] {
        let dir = skillsDirectoryURL()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Skill] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let parsed = parse(raw, fileURL: url) else { continue }
            out.append(parsed)
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Parse a skill markdown file with YAML frontmatter.
    ///
    /// Only two frontmatter fields are recognized — `name` and `description`.
    /// Everything else is ignored (kept in the body as-is) so users can add
    /// custom fields without breaking the parser.
    private static func parse(_ raw: String, fileURL: URL) -> Skill? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var frontmatterEnd = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = i
                break
            }
        }
        guard frontmatterEnd > 0 else { return nil }

        var name = ""
        var description = ""
        for i in 1..<frontmatterEnd {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "name": name = value
            case "description": description = value
            default: continue
            }
        }

        // Fall back to filename stem if the frontmatter omits `name`.
        if name.isEmpty {
            name = fileURL.deletingPathExtension().lastPathComponent
        }
        guard !name.isEmpty, !description.isEmpty else { return nil }

        let bodyStart = frontmatterEnd + 1
        let body = lines[bodyStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Skill(name: name, description: description, body: body, fileURL: fileURL)
    }

    /// Canonical skills directory: `~/LocalAgent/skills/`.
    static func skillsDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("LocalAgent/skills", isDirectory: true)
    }

    /// Ensure the skills directory exists. Called lazily from places that
    /// want to show the path to the user (e.g., the Settings UI "Reveal in
    /// Finder" action).
    @discardableResult
    static func ensureDirectoryExists() -> Bool {
        let dir = skillsDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) { return true }
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return true
        } catch {
            return false
        }
    }
}
