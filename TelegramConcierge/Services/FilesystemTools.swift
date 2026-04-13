import Foundation
import UniformTypeIdentifiers

/// Core filesystem tool implementations: read_file, write_file, edit_file.
/// Apply_patch lives in its own file (`ApplyPatch.swift`).
///
/// All methods take an absolute path (never relative, never ~-expanded by tilde alone —
/// the caller should pass the already-expanded path). These return plain result shapes;
/// the ToolExecutor wraps them into ToolResultMessage when dispatching.
actor FilesystemTools {
    static let shared = FilesystemTools()

    // Caps — mirror OpenCode's defaults.
    static let maxLines = 2000
    static let maxBytes = 50 * 1024          // 50 KB cap for text output
    static let maxLineLength = 2000          // truncate lines longer than this

    struct ReadResult {
        let content: String
        let attachments: [FileAttachment]
    }

    struct OpResult {
        let content: String
    }

    private init() {}

    // MARK: - read_file

    /// Read a text file (paginated) OR load an image/PDF as a FileAttachment for
    /// multimodal injection. Always snapshots FileTime on success.
    func readFile(path rawPath: String, offset: Int? = nil, limit: Int? = nil) async -> ReadResult {
        let path = Self.normalizePath(rawPath)

        guard Self.isAbsolute(path) else {
            return ReadResult(content: jsonError("path must be absolute (start with '/' or '~')"), attachments: [])
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return ReadResult(content: jsonError("file not found: \(path)"), attachments: [])
        }
        if isDir.boolValue {
            return ReadResult(content: jsonError("path is a directory, not a file. Use list_dir instead: \(path)"), attachments: [])
        }

        let mime = Self.mimeType(forPath: path)

        // Images and PDFs → multimodal attachment, return minimal text so the model gets the image on the next turn.
        if Self.isMultimodalMime(mime) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let filename = (path as NSString).lastPathComponent
                await FileTimeTracker.shared.recordRead(path: path)
                let attachment = FileAttachment(data: data, mimeType: mime, filename: filename)
                let summary: [String: Any] = [
                    "success": true,
                    "path": path,
                    "mime_type": mime,
                    "size_bytes": data.count,
                    "message": "Image/PDF attached. It will be visible to you on the next turn as a user-role multimodal message."
                ]
                return ReadResult(content: jsonString(summary), attachments: [attachment])
            } catch {
                return ReadResult(content: jsonError("failed to read \(path): \(error.localizedDescription)"), attachments: [])
            }
        }

        // Text path. Reject other binaries.
        if Self.looksBinary(mime: mime, path: path) {
            return ReadResult(content: jsonError("cannot read binary file \(path) (mime=\(mime)). Use bash tools if you need to inspect it."), attachments: [])
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return ReadResult(content: jsonError("file \(path) is not valid UTF-8 or Latin-1 text"), attachments: [])
            }
            await FileTimeTracker.shared.recordRead(path: path)

            let allLines = text.components(separatedBy: "\n")
            let startLine = max((offset ?? 1) - 1, 0)           // offset is 1-indexed
            if startLine >= allLines.count {
                return ReadResult(
                    content: jsonString([
                        "success": true,
                        "path": path,
                        "total_lines": allLines.count,
                        "returned_lines": 0,
                        "offset": offset ?? 1,
                        "truncated": false,
                        "content": "",
                        "message": "offset \(offset ?? 1) exceeds file length (\(allLines.count) lines)"
                    ]),
                    attachments: []
                )
            }
            let effectiveLimit = limit ?? Self.maxLines
            let endLine = min(startLine + effectiveLimit, allLines.count)
            var slice = Array(allLines[startLine..<endLine])
            var truncatedLongLines = 0
            for i in slice.indices {
                if slice[i].count > Self.maxLineLength {
                    slice[i] = String(slice[i].prefix(Self.maxLineLength)) + "… [line truncated at \(Self.maxLineLength) chars]"
                    truncatedLongLines += 1
                }
            }
            var joined = slice.joined(separator: "\n")
            var bytesTruncated = false
            if joined.utf8.count > Self.maxBytes {
                // Trim from the end to fit the byte cap.
                let utf8Bytes = Array(joined.utf8)
                let clipped = utf8Bytes.prefix(Self.maxBytes)
                joined = String(bytes: clipped, encoding: .utf8) ?? joined
                joined += "\n… [output capped at \(Self.maxBytes) bytes]"
                bytesTruncated = true
            }

            let truncated = endLine < allLines.count || bytesTruncated
            var result: [String: Any] = [
                "success": true,
                "path": path,
                "total_lines": allLines.count,
                "returned_lines": endLine - startLine,
                "offset": startLine + 1,
                "truncated": truncated,
                "content": joined
            ]
            if truncated {
                result["message"] = "File truncated. Returned lines \(startLine + 1)..\(endLine) of \(allLines.count). Call read_file again with offset=\(endLine + 1) for more."
            }
            if truncatedLongLines > 0 {
                result["long_lines_truncated"] = truncatedLongLines
            }
            return ReadResult(content: jsonString(result), attachments: [])
        } catch {
            return ReadResult(content: jsonError("failed to read \(path): \(error.localizedDescription)"), attachments: [])
        }
    }

    // MARK: - write_file

    /// Create or overwrite a file. If the file exists, the agent must have read it this session;
    /// FileTime is asserted before write.
    func writeFile(path rawPath: String, content: String, description: String? = nil) async -> OpResult {
        let path = Self.normalizePath(rawPath)
        guard Self.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }

        let fm = FileManager.default
        let fileExists = fm.fileExists(atPath: path)
        if fileExists {
            do {
                try await FileTimeTracker.shared.assertFresh(path: path)
            } catch {
                return OpResult(content: jsonError(error.localizedDescription))
            }
        }

        do {
            let url = URL(fileURLWithPath: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            // Refresh FileTime snapshot so subsequent edits still pass the staleness check.
            await FileTimeTracker.shared.recordRead(path: path)
            let origin: FilesLedger.Origin = fileExists ? .edited : .generated
            await FilesLedger.shared.record(path: path, origin: origin, description: description)
            return OpResult(content: jsonString([
                "success": true,
                "path": path,
                "bytes_written": content.utf8.count,
                "operation": fileExists ? "overwrote" : "created"
            ]))
        } catch {
            return OpResult(content: jsonError("failed to write \(path): \(error.localizedDescription)"))
        }
    }

    // MARK: - edit_file

    /// Surgical find/replace. `replaceAll` required when `oldString` occurs >1 times.
    /// Falls back through 3 match strategies: literal → line-trimmed → whitespace-normalized.
    func editFile(path rawPath: String, oldString: String, newString: String, replaceAll: Bool = false) async -> OpResult {
        let path = Self.normalizePath(rawPath)
        guard Self.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }
        if oldString == newString {
            return OpResult(content: jsonError("old_string and new_string are identical — nothing to do"))
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return OpResult(content: jsonError("file not found: \(path). Use write_file to create it."))
        }
        do {
            try await FileTimeTracker.shared.assertFresh(path: path)
        } catch {
            return OpResult(content: jsonError(error.localizedDescription))
        }

        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            return OpResult(content: jsonError("file \(path) is not valid UTF-8 text"))
        }

        let result = EditStrategies.apply(
            source: original,
            oldString: oldString,
            newString: newString,
            replaceAll: replaceAll
        )

        switch result {
        case .noMatch:
            return OpResult(content: jsonError("old_string not found in \(path). It must match exactly including whitespace and indentation."))
        case .multipleMatches(let count):
            return OpResult(content: jsonError("old_string occurs \(count) times in \(path). Provide more surrounding context to make it unique, or pass replace_all=true."))
        case .success(let updated, let replacements, let strategy):
            do {
                try updated.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: .atomic)
                await FileTimeTracker.shared.recordRead(path: path)
                await FilesLedger.shared.record(path: path, origin: .edited, description: nil)
                return OpResult(content: jsonString([
                    "success": true,
                    "path": path,
                    "replacements": replacements,
                    "strategy": strategy,
                    "bytes_written": updated.utf8.count
                ]))
            } catch {
                return OpResult(content: jsonError("failed to write \(path): \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Helpers

    static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return trimmed
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "application/octet-stream" }
        if let uti = UTType(filenameExtension: ext), let mime = uti.preferredMIMEType {
            return mime
        }
        // Fallback table for common types.
        switch ext {
        case "txt", "md", "log": return "text/plain"
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "js", "mjs", "cjs": return "text/javascript"
        case "ts", "tsx": return "text/typescript"
        case "json": return "application/json"
        case "yaml", "yml": return "application/yaml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }

    static func isMultimodalMime(_ mime: String) -> Bool {
        mime.hasPrefix("image/") && mime != "image/svg+xml"
            || mime == "application/pdf"
    }

    /// Heuristic: if mime is known text-ish, treat as text. Otherwise check for null bytes.
    static func looksBinary(mime: String, path: String) -> Bool {
        if mime.hasPrefix("text/") { return false }
        if mime == "application/json"
            || mime == "application/yaml"
            || mime == "application/xml"
            || mime == "application/javascript"
            || mime == "image/svg+xml" { return false }
        // Sample first 4KB for null bytes.
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return true }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 4096)) ?? Data()
        return sample.contains(0)
    }

    private func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}

// MARK: - Edit match strategies

enum EditStrategies {
    enum Outcome {
        case noMatch
        case multipleMatches(count: Int)
        case success(updated: String, replacements: Int, strategy: String)
    }

    /// Try three strategies in order: literal, line-trimmed, whitespace-normalized.
    /// Returns early on any successful unique match.
    static func apply(source: String, oldString: String, newString: String, replaceAll: Bool) -> Outcome {
        // 1. Literal match.
        if let outcome = tryLiteral(source: source, oldString: oldString, newString: newString, replaceAll: replaceAll, strategyName: "literal") {
            return outcome
        }
        // 2. Line-trimmed match: match ignoring trailing whitespace on each line.
        if let outcome = tryLineTrimmed(source: source, oldString: oldString, newString: newString, replaceAll: replaceAll) {
            return outcome
        }
        // 3. Whitespace-normalized match: collapse runs of whitespace.
        if let outcome = tryWhitespaceNormalized(source: source, oldString: oldString, newString: newString, replaceAll: replaceAll) {
            return outcome
        }
        return .noMatch
    }

    private static func tryLiteral(source: String, oldString: String, newString: String, replaceAll: Bool, strategyName: String) -> Outcome? {
        let matches = indicesOf(needle: oldString, inHaystack: source)
        if matches.isEmpty { return nil }
        if matches.count > 1 && !replaceAll {
            return .multipleMatches(count: matches.count)
        }
        let updated: String
        let count: Int
        if replaceAll {
            updated = source.replacingOccurrences(of: oldString, with: newString)
            count = matches.count
        } else {
            var s = source
            if let range = s.range(of: oldString) {
                s.replaceSubrange(range, with: newString)
            }
            updated = s
            count = 1
        }
        return .success(updated: updated, replacements: count, strategy: strategyName)
    }

    private static func tryLineTrimmed(source: String, oldString: String, newString: String, replaceAll: Bool) -> Outcome? {
        // Normalize both sides by stripping trailing whitespace on each line.
        let oldTrimmed = oldString
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .joined(separator: "\n")
        let srcLines = source.components(separatedBy: "\n")
        let oldLines = oldTrimmed.components(separatedBy: "\n")
        guard oldLines.count > 0, oldLines.count <= srcLines.count else { return nil }

        var matchPositions: [Int] = []  // starting source-line indices
        for start in 0...(srcLines.count - oldLines.count) {
            var hit = true
            for i in 0..<oldLines.count {
                let srcLine = srcLines[start + i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if srcLine != oldLines[i] { hit = false; break }
            }
            if hit { matchPositions.append(start) }
        }
        if matchPositions.isEmpty { return nil }
        if matchPositions.count > 1 && !replaceAll {
            return .multipleMatches(count: matchPositions.count)
        }

        var working = srcLines
        var replacements = 0
        let newLines = newString.components(separatedBy: "\n")
        // Replace from last to first so indices remain valid.
        for pos in matchPositions.reversed() {
            working.replaceSubrange(pos..<(pos + oldLines.count), with: newLines)
            replacements += 1
            if !replaceAll { break }
        }
        // If we iterated reversed with replaceAll=false, we still applied only the last match,
        // which is the unique match (matchPositions.count == 1). OK.
        return .success(updated: working.joined(separator: "\n"), replacements: replacements, strategy: "line-trimmed")
    }

    private static func tryWhitespaceNormalized(source: String, oldString: String, newString: String, replaceAll: Bool) -> Outcome? {
        func normalize(_ s: String) -> String {
            let collapsed = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            return collapsed.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
                .joined(separator: "\n")
        }
        let normalizedOld = normalize(oldString)
        // Slide a window of the same line count over source, normalizing the window.
        let srcLines = source.components(separatedBy: "\n")
        let oldLineCount = oldString.components(separatedBy: "\n").count
        guard oldLineCount > 0, oldLineCount <= srcLines.count else { return nil }

        var matchPositions: [Int] = []
        for start in 0...(srcLines.count - oldLineCount) {
            let window = srcLines[start..<(start + oldLineCount)].joined(separator: "\n")
            if normalize(window) == normalizedOld {
                matchPositions.append(start)
            }
        }
        if matchPositions.isEmpty { return nil }
        if matchPositions.count > 1 && !replaceAll {
            return .multipleMatches(count: matchPositions.count)
        }

        var working = srcLines
        var replacements = 0
        let newLines = newString.components(separatedBy: "\n")
        for pos in matchPositions.reversed() {
            working.replaceSubrange(pos..<(pos + oldLineCount), with: newLines)
            replacements += 1
            if !replaceAll { break }
        }
        return .success(updated: working.joined(separator: "\n"), replacements: replacements, strategy: "whitespace-normalized")
    }

    private static func indicesOf(needle: String, inHaystack haystack: String) -> [String.Index] {
        var results: [String.Index] = []
        guard !needle.isEmpty else { return results }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            results.append(range.lowerBound)
            searchStart = range.upperBound
        }
        return results
    }
}
