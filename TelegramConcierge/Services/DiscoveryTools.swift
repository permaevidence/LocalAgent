import Foundation

/// Discovery tools: grep, glob, list_dir, list_recent_files.
/// These never modify disk — they only inspect.
///
/// Implementation notes:
/// - grep uses ripgrep (`rg`) if present on PATH, otherwise falls back to a native Swift
///   regex sweep. Ripgrep is dramatically faster on large trees; the native path keeps
///   the tool working on a fresh machine without `brew install ripgrep`.
/// - glob uses native FileManager enumeration.
/// - list_dir uses FileManager, respects a baked-in ignore list.
/// - list_recent_files simply reads FilesLedger.
enum DiscoveryTools {

    static let maxResults = 100
    static let maxLineLength = 2000

    static let bakedInIgnores: Set<String> = [
        ".git", "node_modules", "__pycache__", ".venv", "venv",
        "dist", "build", ".build", ".swiftpm", "DerivedData",
        ".next", ".nuxt", ".turbo", ".cache", ".DS_Store",
        "target", "out", "coverage", ".pytest_cache", ".mypy_cache",
        ".idea", ".vscode"
    ]

    struct OpResult {
        let content: String
    }

    // MARK: - grep

    enum GrepOutputMode: String {
        case content
        case filesWithMatches = "files_with_matches"
        case count
    }

    /// Search file contents for a pattern.
    /// - Parameters:
    ///   - pattern: regex pattern
    ///   - searchPath: directory root (absolute path)
    ///   - include: optional glob filter (e.g. "*.swift")
    ///   - type: optional ripgrep type filter (e.g. "swift", "ts"); requires ripgrep
    ///   - outputMode: .content (default, match lines), .filesWithMatches (paths only), .count (matches-per-file)
    ///   - caseInsensitive: case-insensitive matching (-i)
    ///   - multiline: allow patterns to span newlines (`-U --multiline-dotall`); requires ripgrep
    ///   - contextBefore/contextAfter: number of lines of surrounding context (content mode only)
    ///   - maxResults: cap on returned lines/files (default 100)
    static func grep(
        pattern: String,
        searchPath: String,
        include: String? = nil,
        type: String? = nil,
        outputMode: GrepOutputMode = .content,
        caseInsensitive: Bool = false,
        multiline: Bool = false,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = DiscoveryTools.maxResults
    ) async -> OpResult {
        let path = FilesystemTools.normalizePath(searchPath)
        guard FilesystemTools.isAbsolute(path) else {
            return OpResult(content: jsonError("search path must be absolute: \(searchPath)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return OpResult(content: jsonError("search path does not exist or is not a directory: \(path)"))
        }

        if let rgResult = await grepViaRipgrep(
            pattern: pattern,
            searchPath: path,
            include: include,
            type: type,
            outputMode: outputMode,
            caseInsensitive: caseInsensitive,
            multiline: multiline,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults
        ) {
            return rgResult
        }
        return grepNative(
            pattern: pattern,
            searchPath: path,
            include: include,
            outputMode: outputMode,
            caseInsensitive: caseInsensitive,
            multiline: multiline,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults
        )
    }

    private static func grepViaRipgrep(
        pattern: String,
        searchPath: String,
        include: String?,
        type: String?,
        outputMode: GrepOutputMode,
        caseInsensitive: Bool,
        multiline: Bool,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int
    ) async -> OpResult? {
        let rg = locateExecutable("rg")
        guard let rg else { return nil }

        var args: [String] = [
            "--color=never",
            "--max-columns=\(maxLineLength)",
            "--sort=modified"
        ]
        if caseInsensitive { args.append("-i") }
        if multiline { args.append("-U"); args.append("--multiline-dotall") }

        switch outputMode {
        case .content:
            args.append("--no-heading")
            args.append("--line-number")
            args.append("--max-count=\(maxResults)")
            if contextBefore > 0 { args.append("-B"); args.append(String(contextBefore)) }
            if contextAfter > 0 { args.append("-A"); args.append(String(contextAfter)) }
        case .filesWithMatches:
            args.append("-l")
        case .count:
            args.append("-c")
        }

        for ignore in bakedInIgnores {
            args.append("--glob")
            args.append("!\(ignore)/")
        }
        if let include {
            args.append("--glob")
            args.append(include)
        }
        if let type, !type.isEmpty {
            args.append("-t")
            args.append(type)
        }
        args.append("--")
        args.append(pattern)
        args.append(searchPath)

        let (out, err, status) = runProcess(executable: rg, args: args, timeoutSeconds: 30)
        // rg exits 1 when no matches — treat that as success with empty results.
        guard status == 0 || status == 1 else {
            // ripgrep ran but errored — could be an unknown type filter. Surface it.
            let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedErr.isEmpty {
                return OpResult(content: jsonError("ripgrep error: \(trimmedErr)"))
            }
            return nil
        }

        switch outputMode {
        case .filesWithMatches:
            var files: [String] = []
            var truncated = false
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if files.count >= maxResults { truncated = true; break }
                files.append(String(line))
            }
            return OpResult(content: jsonString([
                "success": true,
                "backend": "ripgrep",
                "mode": "files_with_matches",
                "pattern": pattern,
                "path": searchPath,
                "files": files,
                "count": files.count,
                "truncated": truncated
            ]))

        case .count:
            var counts: [[String: Any]] = []
            var truncated = false
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if counts.count >= maxResults { truncated = true; break }
                // rg -c format: "path:N"
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let n = Int(parts[1]) else { continue }
                counts.append(["file": String(parts[0]), "count": n])
            }
            return OpResult(content: jsonString([
                "success": true,
                "backend": "ripgrep",
                "mode": "count",
                "pattern": pattern,
                "path": searchPath,
                "files": counts,
                "file_count": counts.count,
                "truncated": truncated
            ]))

        case .content:
            var matches: [[String: Any]] = []
            var truncated = false
            let wantContext = contextBefore > 0 || contextAfter > 0
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if matches.count >= maxResults { truncated = true; break }
                let raw = String(line)
                if raw == "--" { continue } // ripgrep context-group separator
                // Matches use `file:N:text`; context lines use `file-N-text`.
                // We only need to detect which is which; record `kind` for context.
                guard let (filePath, lineNo, text, kind) = parseRgLine(raw, wantContext: wantContext) else { continue }
                var clipped = text
                if clipped.count > maxLineLength {
                    clipped = String(clipped.prefix(maxLineLength)) + "… [truncated]"
                }
                var entry: [String: Any] = [
                    "file": filePath,
                    "line": lineNo,
                    "text": clipped
                ]
                if wantContext { entry["kind"] = kind }
                matches.append(entry)
            }
            return OpResult(content: jsonString([
                "success": true,
                "backend": "ripgrep",
                "mode": "content",
                "pattern": pattern,
                "path": searchPath,
                "matches": matches,
                "match_count": matches.count,
                "truncated": truncated
            ]))
        }
    }

    /// Parse a ripgrep output line where match lines use "path:N:text" and context
    /// lines use "path-N-text". Returns (path, lineNumber, text, kind) where kind is
    /// "match" or "context". Returns nil if the line can't be parsed.
    private static func parseRgLine(_ line: String, wantContext: Bool) -> (String, Int, String, String)? {
        // Search for the first separator sequence: path ends before `:N:` (match) or `-N-` (context).
        // We walk from the end-ish to find a numeric segment bracketed by one of the separators.
        // Simpler approach: try `:` first, then if that gives a non-numeric line segment, try `-`.
        if let tuple = splitRgLine(line, separator: ":") {
            return (tuple.0, tuple.1, tuple.2, "match")
        }
        if wantContext, let tuple = splitRgLine(line, separator: "-") {
            return (tuple.0, tuple.1, tuple.2, "context")
        }
        return nil
    }

    private static func splitRgLine(_ line: String, separator: Character) -> (String, Int, String)? {
        // Find the LAST valid "path<sep>N<sep>text" where N is an integer.
        // We do this by scanning for a substring "<sep><digits><sep>" from the left,
        // taking the FIRST occurrence so paths with colons (unusual) still parse.
        let chars = Array(line)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == separator {
                // Look for digits followed by same separator.
                var j = idx + 1
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                if j > idx + 1, j < chars.count, chars[j] == separator {
                    let path = String(chars[0..<idx])
                    guard let lineNo = Int(String(chars[(idx + 1)..<j])) else { idx = j; continue }
                    let text = j + 1 <= chars.count ? String(chars[(j + 1)..<chars.count]) : ""
                    return (path, lineNo, text)
                }
                idx = j
            } else {
                idx += 1
            }
        }
        return nil
    }

    private static func grepNative(
        pattern: String,
        searchPath: String,
        include: String?,
        outputMode: GrepOutputMode,
        caseInsensitive: Bool,
        multiline: Bool,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int
    ) -> OpResult {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return OpResult(content: jsonError("invalid regex pattern: \(pattern)"))
        }
        let includePattern: NSRegularExpression? = {
            guard let include else { return nil }
            return try? NSRegularExpression(pattern: globToRegex(include))
        }()

        let root = URL(fileURLWithPath: searchPath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        struct Candidate { let url: URL; let mtime: Date }
        var candidates: [Candidate] = []

        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            if bakedInIgnores.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            let resource = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resource?.isRegularFile == true else { continue }
            if let includePattern {
                let nameRange = NSRange(name.startIndex..<name.endIndex, in: name)
                if includePattern.firstMatch(in: name, range: nameRange) == nil { continue }
            }
            candidates.append(Candidate(url: item, mtime: resource?.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.mtime > $1.mtime }

        // files_with_matches / count: iterate files, short-circuit on first match per file.
        if outputMode == .filesWithMatches || outputMode == .count {
            var files: [String] = []
            var counts: [[String: Any]] = []
            var truncated = false
            for candidate in candidates {
                if (outputMode == .filesWithMatches ? files.count : counts.count) >= maxResults { truncated = true; break }
                guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
                if data.prefix(4096).contains(0) { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                if multiline {
                    let n = regex.numberOfMatches(in: text, range: nsRange)
                    if n > 0 {
                        if outputMode == .filesWithMatches { files.append(candidate.url.path) }
                        else { counts.append(["file": candidate.url.path, "count": n]) }
                    }
                } else {
                    var fileMatchCount = 0
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        let s = String(line)
                        let r = NSRange(s.startIndex..<s.endIndex, in: s)
                        fileMatchCount += regex.numberOfMatches(in: s, range: r)
                        if outputMode == .filesWithMatches, fileMatchCount > 0 { break }
                    }
                    if fileMatchCount > 0 {
                        if outputMode == .filesWithMatches { files.append(candidate.url.path) }
                        else { counts.append(["file": candidate.url.path, "count": fileMatchCount]) }
                    }
                }
            }
            if outputMode == .filesWithMatches {
                return OpResult(content: jsonString([
                    "success": true,
                    "backend": "native",
                    "mode": "files_with_matches",
                    "pattern": pattern,
                    "path": searchPath,
                    "files": files,
                    "count": files.count,
                    "truncated": truncated
                ]))
            }
            return OpResult(content: jsonString([
                "success": true,
                "backend": "native",
                "mode": "count",
                "pattern": pattern,
                "path": searchPath,
                "files": counts,
                "file_count": counts.count,
                "truncated": truncated
            ]))
        }

        // content mode
        var matches: [[String: Any]] = []
        var truncated = false
        let wantContext = contextBefore > 0 || contextAfter > 0

        for candidate in candidates {
            if matches.count >= maxResults { truncated = true; break }
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
            if data.prefix(4096).contains(0) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var matchedLines: Set<Int> = []
            for (idx, line) in lines.enumerated() {
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: nsRange) != nil {
                    matchedLines.insert(idx)
                }
            }
            if matchedLines.isEmpty { continue }

            // Compute the set of line indices to emit: matches plus surrounding context.
            var emitSet: Set<Int> = matchedLines
            if wantContext {
                for m in matchedLines {
                    let lo = max(0, m - contextBefore)
                    let hi = min(lines.count - 1, m + contextAfter)
                    for k in lo...hi { emitSet.insert(k) }
                }
            }
            let emit = emitSet.sorted()

            for i in emit {
                if matches.count >= maxResults { truncated = true; break }
                var t = lines[i]
                if t.count > maxLineLength {
                    t = String(t.prefix(maxLineLength)) + "… [truncated]"
                }
                var entry: [String: Any] = [
                    "file": candidate.url.path,
                    "line": i + 1,
                    "text": t
                ]
                if wantContext { entry["kind"] = matchedLines.contains(i) ? "match" : "context" }
                matches.append(entry)
            }
        }

        return OpResult(content: jsonString([
            "success": true,
            "backend": "native",
            "mode": "content",
            "pattern": pattern,
            "path": searchPath,
            "matches": matches,
            "match_count": matches.count,
            "truncated": truncated
        ]))
    }

    // MARK: - glob

    /// Find files by name pattern (simple glob: *, ?, **/ for recursive).
    static func glob(pattern: String, searchPath: String? = nil, maxResults: Int = DiscoveryTools.maxResults) async -> OpResult {
        let root: String
        if let searchPath {
            root = FilesystemTools.normalizePath(searchPath)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.path
        }
        guard FilesystemTools.isAbsolute(root) else {
            return OpResult(content: jsonError("search path must be absolute: \(searchPath ?? root)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return OpResult(content: jsonError("search path does not exist or is not a directory: \(root)"))
        }

        let recursive = pattern.contains("**")
        let fileGlob = pattern.replacingOccurrences(of: "**/", with: "")
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: globToRegex(fileGlob))
        } catch {
            return OpResult(content: jsonError("invalid glob pattern: \(pattern)"))
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        struct Hit { let path: String; let mtime: Date }
        var hits: [Hit] = []
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            if bakedInIgnores.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            if !recursive {
                // Skip anything deeper than the root.
                if item.deletingLastPathComponent().path != root {
                    continue
                }
            }
            let resource = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resource?.isRegularFile == true else { continue }
            let nameRange = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, range: nameRange) != nil {
                hits.append(Hit(path: item.path, mtime: resource?.contentModificationDate ?? .distantPast))
            }
        }
        hits.sort { $0.mtime > $1.mtime }
        let truncated = hits.count > maxResults
        let capped = Array(hits.prefix(maxResults))

        return OpResult(content: jsonString([
            "success": true,
            "pattern": pattern,
            "path": root,
            "files": capped.map { $0.path },
            "count": capped.count,
            "truncated": truncated
        ]))
    }

    // MARK: - list_dir

    /// Tree view of a directory.
    static func listDir(path rawPath: String, ignore extraIgnores: [String]? = nil, maxEntries: Int = DiscoveryTools.maxResults) async -> OpResult {
        let path = FilesystemTools.normalizePath(rawPath)
        guard FilesystemTools.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return OpResult(content: jsonError("path does not exist or is not a directory: \(path)"))
        }

        var ignores = bakedInIgnores
        if let extraIgnores { ignores.formUnion(extraIgnores) }

        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        var entries: [[String: Any]] = []
        var truncated = false

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let sorted = contents.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            for url in sorted {
                if entries.count >= maxEntries { truncated = true; break }
                let name = url.lastPathComponent
                if ignores.contains(name) { continue }
                let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isFile = rv?.isRegularFile ?? false
                let isDirectory = rv?.isDirectory ?? false
                var entry: [String: Any] = [
                    "name": name,
                    "path": url.path,
                    "type": isDirectory ? "dir" : (isFile ? "file" : "other")
                ]
                if isFile, let size = rv?.fileSize {
                    entry["size_bytes"] = size
                }
                if let mtime = rv?.contentModificationDate {
                    entry["mtime"] = ISO8601DateFormatter().string(from: mtime)
                }
                entries.append(entry)
            }
        } catch {
            return OpResult(content: jsonError("failed to list \(path): \(error.localizedDescription)"))
        }

        return OpResult(content: jsonString([
            "success": true,
            "path": path,
            "entries": entries,
            "count": entries.count,
            "truncated": truncated
        ]))
    }

    // MARK: - list_recent_files

    static func listRecentFiles(limit: Int = 20, offset: Int = 0, filterOrigin: String? = nil) async -> OpResult {
        let origin: FilesLedger.Origin? = filterOrigin.flatMap { FilesLedger.Origin(rawValue: $0) }
        if let filterOrigin, origin == nil {
            return OpResult(content: jsonError("invalid filter_origin '\(filterOrigin)'. Valid values: edited, generated, telegram, email, download"))
        }
        let entries = await FilesLedger.shared.recentFiles(limit: limit, offset: offset, filterOrigin: origin)
        let total = await FilesLedger.shared.totalCount(filterOrigin: origin)
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = entries.map { e in
            var d: [String: Any] = [
                "path": e.path,
                "last_touched": iso.string(from: e.last_touched),
                "origin": e.origin.rawValue,
                "touch_count": e.touch_count
            ]
            if let desc = e.description { d["description"] = desc }
            return d
        }
        return OpResult(content: jsonString([
            "success": true,
            "files": payload,
            "returned": entries.count,
            "offset": offset,
            "total": total
        ]))
    }

    // MARK: - Helpers

    private static func locateExecutable(_ name: String) -> String? {
        let candidatePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in candidatePaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fallback: ask the shell.
        let which = runProcess(executable: "/usr/bin/which", args: [name], timeoutSeconds: 5)
        if which.status == 0 {
            let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run a subprocess synchronously with a timeout. Returns (stdout, stderr, exit code).
    private static func runProcess(executable: String, args: [String], timeoutSeconds: Double) -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ("", "failed to spawn \(executable): \(error.localizedDescription)", -1)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return ("", "process timed out after \(timeoutSeconds)s", -2)
        }
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    /// Convert a shell-style glob (supporting *, ?, and character classes) into a regex anchored to the full name.
    private static func globToRegex(_ glob: String) -> String {
        var out = "^"
        for ch in glob {
            switch ch {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case ".", "(", ")", "{", "}", "^", "$", "+", "|", "\\":
                out += "\\\(ch)"
            case "[":
                out += "["   // passthrough — user wrote their own class
            case "]":
                out += "]"
            default:
                out += String(ch)
            }
        }
        out += "$"
        return out
    }

    private static func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}
