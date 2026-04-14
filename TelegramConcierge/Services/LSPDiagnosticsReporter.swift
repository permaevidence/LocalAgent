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

    /// Cap applied to `diagnostics` arrays from a single-file write (write_file,
    /// edit_file) as well as each per-file entry inside `diagnostics_by_file`
    /// for apply_patch. Keeps pathological broken-patch cases from blowing the
    /// context window.
    static let perFileDiagnosticsCap = 50

    /// Total cap across all per-file entries for apply_patch.
    static let totalDiagnosticsCap = 200

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
            let total = diags.count
            let capped = Array(diags.prefix(perFileDiagnosticsCap))
            result["diagnostics"] = capped.map { diag -> [String: Any] in
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
            if total > perFileDiagnosticsCap {
                result["diagnostics_truncated"] = true
                result["diagnostics_total"] = total
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
    /// so callers can see which file each issue belongs to. Applies both a
    /// per-file cap (50, via `attach`) and a total cap across all files (200).
    /// When the total cap is exceeded, remaining files still report their
    /// summary counts but their `diagnostics` array is dropped and flagged
    /// truncated so the agent still knows something is there.
    static func attachBatch(
        to result: inout [String: Any],
        files: [(path: String, text: String)],
        waitFor timeout: TimeInterval = 1.0
    ) async {
        var byPath: [String: Any] = [:]
        var totalEmitted = 0
        var totalExceeded = false
        for file in files {
            var entry: [String: Any] = [:]
            await attach(to: &entry, path: file.path, updatedText: file.text, waitFor: timeout)
            if let arr = entry["diagnostics"] as? [[String: Any]] {
                let remaining = max(0, totalDiagnosticsCap - totalEmitted)
                if arr.count > remaining {
                    entry["diagnostics"] = Array(arr.prefix(remaining))
                    entry["diagnostics_truncated"] = true
                    totalExceeded = true
                    totalEmitted = totalDiagnosticsCap
                } else {
                    totalEmitted += arr.count
                }
            }
            byPath[file.path] = entry
        }
        result["diagnostics_by_file"] = byPath
        if totalExceeded {
            result["diagnostics_truncated"] = true
        }
    }
}
