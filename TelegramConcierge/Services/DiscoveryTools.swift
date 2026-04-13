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

    /// Search file contents for a pattern.
    /// - Parameters:
    ///   - pattern: regex pattern
    ///   - searchPath: directory root (absolute path)
    ///   - include: optional glob filter (e.g. "*.swift")
    ///   - maxResults: cap on number of matching lines returned (default 100)
    static func grep(
        pattern: String,
        searchPath: String,
        include: String? = nil,
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

        if let rgResult = await grepViaRipgrep(pattern: pattern, searchPath: path, include: include, maxResults: maxResults) {
            return rgResult
        }
        return grepNative(pattern: pattern, searchPath: path, include: include, maxResults: maxResults)
    }

    private static func grepViaRipgrep(pattern: String, searchPath: String, include: String?, maxResults: Int) async -> OpResult? {
        let rg = locateExecutable("rg")
        guard let rg else { return nil }

        var args: [String] = [
            "--no-heading",
            "--line-number",
            "--color=never",
            "--max-count=\(maxResults)",
            "--max-columns=\(maxLineLength)",
            "--sort=modified"
        ]
        for ignore in bakedInIgnores {
            args.append("--glob")
            args.append("!\(ignore)/")
        }
        if let include {
            args.append("--glob")
            args.append(include)
        }
        args.append("--")
        args.append(pattern)
        args.append(searchPath)

        let (out, _, status) = runProcess(executable: rg, args: args, timeoutSeconds: 30)
        // rg exits 1 when no matches — treat that as success with empty results.
        if status == 0 || status == 1 {
            var matches: [[String: Any]] = []
            var truncated = false
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if matches.count >= maxResults { truncated = true; break }
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3,
                      let lineNo = Int(parts[1]) else { continue }
                var text = String(parts[2])
                if text.count > maxLineLength {
                    text = String(text.prefix(maxLineLength)) + "… [truncated]"
                }
                matches.append([
                    "file": String(parts[0]),
                    "line": lineNo,
                    "text": text
                ])
            }
            return OpResult(content: jsonString([
                "success": true,
                "backend": "ripgrep",
                "pattern": pattern,
                "path": searchPath,
                "matches": matches,
                "match_count": matches.count,
                "truncated": truncated
            ]))
        }
        return nil  // ripgrep ran but errored; fall through to native
    }

    private static func grepNative(pattern: String, searchPath: String, include: String?, maxResults: Int) -> OpResult {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return OpResult(content: jsonError("invalid regex pattern: \(pattern)"))
        }
        let includePattern: NSRegularExpression? = {
            guard let include else { return nil }
            // Turn a simple glob into a regex. Supports *, ?, and literal chars.
            return try? NSRegularExpression(pattern: globToRegex(include))
        }()

        var matches: [[String: Any]] = []
        var truncated = false
        let root = URL(fileURLWithPath: searchPath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        // Collect candidate files first so we can sort by mtime desc.
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

        for candidate in candidates {
            if matches.count >= maxResults { truncated = true; break }
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
            // Skip binary-ish files.
            if data.prefix(4096).contains(0) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, line) in lines.enumerated() {
                if matches.count >= maxResults { truncated = true; break }
                let lineStr = String(line)
                let nsRange = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
                if regex.firstMatch(in: lineStr, range: nsRange) != nil {
                    var t = lineStr
                    if t.count > maxLineLength {
                        t = String(t.prefix(maxLineLength)) + "… [truncated]"
                    }
                    matches.append([
                        "file": candidate.url.path,
                        "line": idx + 1,
                        "text": t
                    ])
                }
            }
        }

        return OpResult(content: jsonString([
            "success": true,
            "backend": "native",
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
