import Foundation

/// Bridge between LSPRegistry and the JSON tool-result shape surfaced to the
/// agent. Every write tool (write_file, edit_file, apply_patch) calls
/// `attach(to:path:updatedText:)` after the disk write succeeds so errors and
/// warnings from sourcekit-lsp / tsserver / pylsp land in the tool result on
/// the same turn.
///
/// Failure modes are surfaced as `diagnostics_skipped` rather than failing the
/// write — a missing language server must not prevent legitimate edits.
enum LSPDiagnosticsReporter {

    /// Merge diagnostics fields into `result` in place. Never throws; never
    /// fails the surrounding write.
    static func attach(
        to result: inout [String: Any],
        path: String,
        updatedText: String,
        waitFor timeout: TimeInterval = 1.0
    ) async {
        let outcome = await LSPRegistry.shared.diagnostics(
            forPath: path,
            updatedText: updatedText,
            waitFor: timeout
        )
        switch outcome {
        case .skipped(let reason):
            result["diagnostics_skipped"] = reason
        case .diagnostics(let diags, let serverID):
            result["diagnostics_source"] = serverID
            result["diagnostics"] = diags.map { diag -> [String: Any] in
                var d: [String: Any] = [
                    "line": diag.line,
                    "column": diag.column,
                    "severity": diag.severity,
                    "message": diag.message
                ]
                if let endLine = diag.endLine { d["end_line"] = endLine }
                if let endCol = diag.endColumn { d["end_column"] = endCol }
                if let source = diag.source { d["source"] = source }
                if let code = diag.code { d["code"] = code }
                return d
            }
            let errorCount = diags.filter { $0.severity == "error" }.count
            let warnCount = diags.filter { $0.severity == "warning" }.count
            if errorCount > 0 {
                result["diagnostics_summary"] =
                    "\(errorCount) error(s)\(warnCount > 0 ? ", \(warnCount) warning(s)" : "") — re-read and fix before continuing"
            } else if warnCount > 0 {
                result["diagnostics_summary"] = "\(warnCount) warning(s)"
            } else {
                result["diagnostics_summary"] = "clean"
            }
        }
    }

    /// Variant for apply_patch: attach diagnostics as a per-path dictionary
    /// so callers can see which file each issue belongs to.
    static func attachBatch(
        to result: inout [String: Any],
        files: [(path: String, text: String)],
        waitFor timeout: TimeInterval = 1.0
    ) async {
        var byPath: [String: Any] = [:]
        for file in files {
            var entry: [String: Any] = [:]
            await attach(to: &entry, path: file.path, updatedText: file.text, waitFor: timeout)
            byPath[file.path] = entry
        }
        result["diagnostics_by_file"] = byPath
    }
}
