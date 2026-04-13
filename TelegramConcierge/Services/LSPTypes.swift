import Foundation

/// Diagnostic surfaced to the agent. Line and column are 1-indexed for
/// human/display friendliness; LSP's wire format is 0-indexed and converted
/// at the edge via `from(raw:)`.
public struct LSPDiagnostic: Codable, Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let endLine: Int?
    public let endColumn: Int?
    public let severity: String
    public let source: String?
    public let message: String
    public let code: String?

    public init(
        line: Int,
        column: Int,
        endLine: Int? = nil,
        endColumn: Int? = nil,
        severity: String,
        source: String? = nil,
        message: String,
        code: String? = nil
    ) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.severity = severity
        self.source = source
        self.message = message
        self.code = code
    }

    /// Parse from a raw LSP `Diagnostic` JSON object.
    public static func from(raw: [String: Any]) -> LSPDiagnostic? {
        guard let range = raw["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startChar = start["character"] as? Int,
              let message = raw["message"] as? String
        else { return nil }
        let end = range["end"] as? [String: Any]
        let endLine = (end?["line"] as? Int).map { $0 + 1 }
        let endChar = (end?["character"] as? Int).map { $0 + 1 }
        let severityInt = raw["severity"] as? Int ?? 1
        let severity: String
        switch severityInt {
        case 1: severity = "error"
        case 2: severity = "warning"
        case 3: severity = "info"
        case 4: severity = "hint"
        default: severity = "error"
        }
        let source = raw["source"] as? String
        let codeString: String?
        if let s = raw["code"] as? String { codeString = s }
        else if let n = raw["code"] as? Int { codeString = String(n) }
        else { codeString = nil }
        return LSPDiagnostic(
            line: startLine + 1,
            column: startChar + 1,
            endLine: endLine,
            endColumn: endChar,
            severity: severity,
            source: source,
            message: message,
            code: codeString
        )
    }
}

public enum LSPClientError: Error, CustomStringConvertible {
    case notStarted
    case spawnFailed(String)
    case responseError(String)
    case terminated
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notStarted: return "LSP client not started"
        case .spawnFailed(let msg): return "LSP spawn failed: \(msg)"
        case .responseError(let msg): return "LSP response error: \(msg)"
        case .terminated: return "LSP server terminated"
        case .writeFailed(let msg): return "LSP write failed: \(msg)"
        }
    }
}

public enum LSPFrameError: Error, CustomStringConvertible {
    case invalidHeader
    case missingContentLength
    case invalidBody

    public var description: String {
        switch self {
        case .invalidHeader: return "invalid LSP frame header"
        case .missingContentLength: return "LSP frame missing Content-Length"
        case .invalidBody: return "invalid LSP frame body"
        }
    }
}
