import Foundation

/// Handlers for the new filesystem tool surface: read_file, write_file, edit_file,
/// apply_patch, grep, glob, list_dir, list_recent_files, bash, bash_output, bash_kill.
///
/// Parsing pattern: decode arguments from JSONValue (since the tool schema uses
/// string-typed parameters that may arrive as numbers/bools/objects), delegate to the
/// underlying implementation in FilesystemTools / ApplyPatch / DiscoveryTools / BashTools,
/// wrap the result as a ToolResultMessage.
extension ToolExecutor {

    // MARK: - read_file (returns multimodal attachments for images/PDFs)

    func executeReadFile(_ call: ToolCall) async -> ToolResultMessage {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"read_file requires 'path' (absolute)\"}")
        }
        let offset = args.int("offset")
        let limit = args.int("limit")
        let result = await FilesystemTools.shared.readFile(path: path, offset: offset, limit: limit)
        return ToolResultMessage(toolCallId: call.id, content: result.content, fileAttachments: result.attachments)
    }

    // MARK: - write_file

    func executeWriteFile(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return "{\"error\": \"write_file requires 'path'\"}"
        }
        guard let content = args.string("content") else {
            return "{\"error\": \"write_file requires 'content'\"}"
        }
        let description = args.string("description")
        let result = await FilesystemTools.shared.writeFile(path: path, content: content, description: description)
        return result.content
    }

    // MARK: - edit_file

    func executeEditFile(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path"),
              let oldString = args.string("old_string"),
              let newString = args.string("new_string") else {
            return "{\"error\": \"edit_file requires 'path', 'old_string', and 'new_string'\"}"
        }
        let replaceAll = args.bool("replace_all") ?? false
        let result = await FilesystemTools.shared.editFile(path: path, oldString: oldString, newString: newString, replaceAll: replaceAll)
        return result.content
    }

    // MARK: - apply_patch

    func executeApplyPatch(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let patchText = args.string("patch_text") else {
            return "{\"error\": \"apply_patch requires 'patch_text'\"}"
        }
        let result = await ApplyPatch.run(patchText: patchText)
        return result.content
    }

    // MARK: - grep

    func executeGrep(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let pattern = args.string("pattern"),
              let path = args.string("path") else {
            return "{\"error\": \"grep requires 'pattern' and 'path'\"}"
        }
        let include = args.string("include")
        let maxResults = args.int("max_results") ?? DiscoveryTools.maxResults
        let result = await DiscoveryTools.grep(pattern: pattern, searchPath: path, include: include, maxResults: maxResults)
        return result.content
    }

    // MARK: - glob

    func executeGlob(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let pattern = args.string("pattern") else {
            return "{\"error\": \"glob requires 'pattern'\"}"
        }
        let path = args.string("path")
        let maxResults = args.int("max_results") ?? DiscoveryTools.maxResults
        let result = await DiscoveryTools.glob(pattern: pattern, searchPath: path, maxResults: maxResults)
        return result.content
    }

    // MARK: - list_dir

    func executeListDir(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let path = args.string("path") else {
            return "{\"error\": \"list_dir requires 'path'\"}"
        }
        var extraIgnores: [String]? = nil
        if let ignoreStr = args.string("ignore"),
           let data = ignoreStr.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            extraIgnores = arr
        }
        let result = await DiscoveryTools.listDir(path: path, ignore: extraIgnores)
        return result.content
    }

    // MARK: - list_recent_files

    func executeListRecentFiles(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        let limit = args.int("limit") ?? 20
        let offset = args.int("offset") ?? 0
        let filter = args.string("filter_origin")
        let result = await DiscoveryTools.listRecentFiles(limit: limit, offset: offset, filterOrigin: filter)
        return result.content
    }

    // MARK: - bash (dispatches to foreground or background)

    func executeBash(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let command = args.string("command") else {
            return "{\"error\": \"bash requires 'command'\"}"
        }
        let workdir = args.string("workdir")
        let description = args.string("description")
        let runInBackground = args.bool("run_in_background") ?? false
        if runInBackground {
            let result = await BashTools.runBackground(command: command, workdir: workdir, description: description)
            return result.content
        } else {
            let timeoutMs = args.int("timeout_ms")
            let result = await BashTools.runForeground(command: command, timeoutMs: timeoutMs, workdir: workdir, description: description)
            return result.content
        }
    }

    // MARK: - bash_output

    func executeBashOutput(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let handle = args.string("handle") else {
            return "{\"error\": \"bash_output requires 'handle'\"}"
        }
        let since = args.int("since") ?? 0
        let result = await BashTools.output(handle: handle, since: since)
        return result.content
    }

    // MARK: - bash_kill

    func executeBashKill(_ call: ToolCall) async -> String {
        let args = parseArgs(call.function.arguments)
        guard let handle = args.string("handle") else {
            return "{\"error\": \"bash_kill requires 'handle'\"}"
        }
        let result = await BashTools.kill(handle: handle)
        return result.content
    }

    // MARK: - Argument parsing helper

    private func parseArgs(_ jsonString: String) -> ArgDict {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ArgDict(raw: [:])
        }
        return ArgDict(raw: obj)
    }

    fileprivate struct ArgDict {
        let raw: [String: Any]

        func string(_ key: String) -> String? {
            if let s = raw[key] as? String { return s.isEmpty ? nil : s }
            // Be permissive: models sometimes emit numbers/bools where strings are expected.
            if let n = raw[key] as? NSNumber { return n.stringValue }
            return nil
        }

        func int(_ key: String) -> Int? {
            if let i = raw[key] as? Int { return i }
            if let d = raw[key] as? Double { return Int(d) }
            if let s = raw[key] as? String { return Int(s) }
            return nil
        }

        func bool(_ key: String) -> Bool? {
            if let b = raw[key] as? Bool { return b }
            if let s = raw[key] as? String {
                switch s.lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: return nil
                }
            }
            return nil
        }
    }
}
