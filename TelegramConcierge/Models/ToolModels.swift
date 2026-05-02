import Foundation
import AppKit
import PDFKit

enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Tool Definitions (OpenAI Function Calling Format)

struct ToolDefinition: Codable {
    let type: String
    let function: FunctionDefinition
    
    init(function: FunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct FunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: FunctionParameters
}

struct FunctionParameters: Codable {
    let type: String
    let properties: [String: ParameterProperty]
    let required: [String]
    
    init(properties: [String: ParameterProperty], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct ParameterProperty: Codable {
    let type: String
    let description: String
    let enumValues: [String]?
    /// Required when `type == "array"` — describes the element schema.
    /// Gemini and other providers reject array parameters without items.
    let items: ArrayItemsSchema?
    /// Populated when `type == "object"` to describe nested fields.
    let properties: [String: ParameterProperty]?
    /// Populated when `type == "object"` to mark required nested fields.
    let required: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
        case properties
        case required
    }

    init(
        type: String,
        description: String,
        enumValues: [String]? = nil,
        items: ArrayItemsSchema? = nil,
        properties: [String: ParameterProperty]? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
        self.properties = properties
        self.required = required
    }

    // Manual encode so nil fields are omitted rather than serialised as
    // `"items": null` (some providers reject null schema nodes).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(enumValues, forKey: .enumValues)
        try c.encodeIfPresent(items, forKey: .items)
        try c.encodeIfPresent(properties, forKey: .properties)
        try c.encodeIfPresent(required, forKey: .required)
    }
}

/// Schema describing the element of an `array`-typed parameter. Supports
/// primitive items (e.g. `{ type: "string" }`) and object items with their
/// own properties / required list.
final class ArrayItemsSchema: Codable {
    let type: String                                    // "string" | "number" | "integer" | "boolean" | "object"
    let description: String?
    let enumValues: [String]?
    let items: ArrayItemsSchema?                        // populated when type == "array"
    let properties: [String: ParameterProperty]?        // populated when type == "object"
    let required: [String]?                             // populated when type == "object"

    enum CodingKeys: String, CodingKey {
        case type, description, items, properties, required
        case enumValues = "enum"
    }

    init(
        type: String,
        description: String? = nil,
        enumValues: [String]? = nil,
        items: ArrayItemsSchema? = nil,
        properties: [String: ParameterProperty]? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
        self.properties = properties
        self.required = required
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(enumValues, forKey: .enumValues)
        try c.encodeIfPresent(items, forKey: .items)
        try c.encodeIfPresent(properties, forKey: .properties)
        try c.encodeIfPresent(required, forKey: .required)
    }
}

// MARK: - Tool Calls (from LLM response)

struct ToolCall: Codable, Identifiable {
    let id: String
    let type: String
    let function: FunctionCall
}

struct FunctionCall: Codable {
    let name: String
    let arguments: String  // JSON string that needs parsing
}

// MARK: - Tool Results (sent back to LLM)

/// Represents file data to be shown to the LLM as multimodal content
struct FileAttachment {
    let data: Data
    let mimeType: String
    let filename: String
    let sourcePath: String?
    let pageRange: String?

    init(data: Data, mimeType: String, filename: String, sourcePath: String? = nil, pageRange: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        self.sourcePath = sourcePath
        self.pageRange = pageRange
    }
}

/// Persisted reference to multimodal tool output. We store enough metadata to
/// rehydrate the file bytes on later turns without putting base64 blobs into
/// conversation.json.
struct FileAttachmentReference: Codable {
    let filename: String
    let mimeType: String
    let snapshotPath: String?
    let sourcePath: String?
    let pageRange: String?
    let byteSize: Int?
    let imageWidth: Int?
    let imageHeight: Int?
    let pdfPageCount: Int?

    enum CodingKeys: String, CodingKey {
        case filename, mimeType, snapshotPath, sourcePath, pageRange
        case byteSize, imageWidth, imageHeight, pdfPageCount
    }

    init(
        filename: String,
        mimeType: String,
        snapshotPath: String? = nil,
        sourcePath: String? = nil,
        pageRange: String? = nil,
        byteSize: Int? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        pdfPageCount: Int? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.snapshotPath = snapshotPath
        self.sourcePath = sourcePath
        self.pageRange = pageRange
        self.byteSize = byteSize
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pdfPageCount = pdfPageCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        snapshotPath = try c.decodeIfPresent(String.self, forKey: .snapshotPath)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        pageRange = try c.decodeIfPresent(String.self, forKey: .pageRange)
        byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        pdfPageCount = try c.decodeIfPresent(Int.self, forKey: .pdfPageCount)
    }

    func resolvedURL(imagesDirectory: URL, documentsDirectory: URL) -> URL? {
        let fm = FileManager.default
        if let snapshotPath, fm.fileExists(atPath: snapshotPath) {
            return URL(fileURLWithPath: snapshotPath)
        }
        if let sourcePath, fm.fileExists(atPath: sourcePath) {
            return URL(fileURLWithPath: sourcePath)
        }

        let imageURL = imagesDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: imageURL.path) {
            return imageURL
        }

        let documentURL = documentsDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: documentURL.path) {
            return documentURL
        }

        return nil
    }
}

struct ToolResultMessage: Codable {
    let role: String
    let toolCallId: String
    var content: String
    
    /// Optional files to inject as multimodal content (not serialized to API directly)
    var fileAttachments: [FileAttachment]

    /// Persisted references for fileAttachments. Historical tool replay uses
    /// these to keep inline images/PDFs visible until pruning.
    var fileAttachmentReferences: [FileAttachmentReference]
    
    /// Optional spend associated with tool-internal API calls (not serialized to API directly)
    var spendUSD: Double?
    
    enum CodingKeys: String, CodingKey {
        case role
        case toolCallId = "tool_call_id"
        case content
        case fileAttachmentReferences
    }
    
    init(
        toolCallId: String,
        content: String,
        fileAttachment: FileAttachment? = nil,
        fileAttachments: [FileAttachment]? = nil,
        spendUSD: Double? = nil
    ) {
        self.role = "tool"
        self.toolCallId = toolCallId
        self.content = content
        // Support both single and multiple attachments
        if let attachments = fileAttachments {
            self.fileAttachments = attachments
        } else if let single = fileAttachment {
            self.fileAttachments = [single]
        } else {
            self.fileAttachments = []
        }
        self.fileAttachmentReferences = self.fileAttachments.map {
            Self.persistAttachmentReference(for: $0)
        }
        self.spendUSD = spendUSD
    }
    
    // Manual Decodable conformance - fileAttachments is not serialized
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
        self.content = try container.decode(String.self, forKey: .content)
        self.fileAttachmentReferences = (try? container.decode([FileAttachmentReference].self, forKey: .fileAttachmentReferences)) ?? []
        self.fileAttachments = [] // Not decoded, only used transiently
        self.spendUSD = nil // Not decoded, only used transiently
    }

    private static func persistAttachmentReference(for attachment: FileAttachment) -> FileAttachmentReference {
        let snapshotPath = snapshotAttachmentData(attachment.data, filename: attachment.filename)
        let imageDimensions = imageDimensions(for: attachment.data, mimeType: attachment.mimeType)
        let pdfPageCount = pdfPageCount(for: attachment.data, mimeType: attachment.mimeType)

        return FileAttachmentReference(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            snapshotPath: snapshotPath,
            sourcePath: attachment.sourcePath,
            pageRange: attachment.pageRange,
            byteSize: attachment.data.count,
            imageWidth: imageDimensions?.width,
            imageHeight: imageDimensions?.height,
            pdfPageCount: pdfPageCount
        )
    }

    private static func snapshotAttachmentData(_ data: Data, filename: String) -> String? {
        guard !data.isEmpty else { return nil }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("LocalAgent", isDirectory: true)
            .appendingPathComponent("tool_attachments", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = sanitizedSnapshotFilename(filename)
            let url = dir.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            print("[ToolResultMessage] Failed to snapshot attachment \(filename): \(error)")
            return nil
        }
    }

    private static func sanitizedSnapshotFilename(_ filename: String) -> String {
        let last = URL(fileURLWithPath: filename).lastPathComponent
        let cleaned = last.map { char -> Character in
            if char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" {
                return char
            }
            return "_"
        }
        let result = String(cleaned)
        return result.isEmpty ? "attachment.bin" : result
    }

    private static func normalizedMimeType(_ mimeType: String) -> String {
        mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()
    }

    private static func imageDimensions(for data: Data, mimeType: String) -> (width: Int, height: Int)? {
        guard normalizedMimeType(mimeType).hasPrefix("image/"),
              let image = NSImage(data: data) else {
            return nil
        }
        let width = image.representations.map(\.pixelsWide).filter { $0 > 0 }.max()
            ?? max(Int(image.size.width), 1)
        let height = image.representations.map(\.pixelsHigh).filter { $0 > 0 }.max()
            ?? max(Int(image.size.height), 1)
        return (width, height)
    }

    private static func pdfPageCount(for data: Data, mimeType: String) -> Int? {
        guard normalizedMimeType(mimeType) == "application/pdf",
              let doc = PDFDocument(data: data) else {
            return nil
        }
        return doc.pageCount
    }
}

// MARK: - Web Search Tool Result

struct WebSearchResult: Codable {
    let summary: String
    let sources: [String]
    let searchQueriesUsed: [String]
    let spendUSD: Double?
    
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"summary\": \"\(summary)\", \"sources\": [], \"searchQueriesUsed\": [], \"spendUSD\": null}"
        }
        return json
    }
}

// MARK: - LLM Response Types

enum LLMResponse {
    case text(String, promptTokens: Int?, completionTokens: Int?, spendUSD: Double?)
    case toolCalls(assistantMessage: AssistantToolCallMessage, calls: [ToolCall], promptTokens: Int?, completionTokens: Int?, spendUSD: Double?)
}

/// The assistant's message when it decides to call tools (must be preserved for the follow-up)
struct AssistantToolCallMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]
    let reasoning: JSONValue?
    let reasoningDetails: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case reasoning
        case reasoningDetails = "reasoning_details"
    }
    
    init(content: String?, toolCalls: [ToolCall], reasoning: JSONValue? = nil, reasoningDetails: JSONValue? = nil) {
        self.role = "assistant"
        self.content = content
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
    }
}

// MARK: - Available Tools Registry

enum AvailableTools {
    static let webSearch = ToolDefinition(
        function: FunctionDefinition(
            name: "web_search",
            description: "Quick web-grounded answer. Runs a short internal agent loop that searches and (if useful) scrapes a few pages, then returns a concise synthesized answer with inline source citations. Use for current events, prices, stock quotes, weather, single facts, or any question needing fresh info you don't already know. Lighter and faster than web_research_sweep — prefer it when one short answer will do, not a survey. Do NOT use for general knowledge you already know. If you need the raw content of a known URL, use web_fetch.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "The user's question or topic to research. Be specific and include relevant context from the conversation."
                    )
                ],
                required: ["query"]
            )
        )
    )

    static let webResearchSweep = ToolDefinition(
        function: FunctionDefinition(
            name: "web_research_sweep",
            description: "Broad multi-source research. Runs an internal agent loop that queries many sites, scrapes relevant pages, and returns a synthesized prose answer with inline source citations. The answer is condensed across sources — page contents are NOT returned verbatim. Use for topic overviews, market scans, long-form researched answers, or 'what does the web say about X' questions. Do NOT use to analyze or compare specific known URLs — use web_fetch on each URL for raw content.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "The research question or topic to investigate in depth. Include constraints, scope, and context from the conversation."
                    )
                ],
                required: ["query"]
            )
        )
    )
    
    static let manageReminders = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_reminders",
            description: "Single reminder tool. Use action='set' to schedule, action='list' to view pending reminders, and action='delete' to cancel one or many reminders.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Reminder action: 'set', 'list', or 'delete'.",
                        enumValues: ["set", "list", "delete"]
                    ),
                    "trigger_datetime": ParameterProperty(
                        type: "string",
                        description: "Required for action='set'. Local datetime in the future (e.g., '2026-04-12T15:00:00'). Use the same timezone as the conversation timestamps."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "Required for action='set'. Reminder instructions."
                    ),
                    "recurrence": ParameterProperty(
                        type: "string",
                        description: "Optional for action='set'. 'daily', 'weekly', 'monthly', 'every_X_minutes', or 'every_X_hours'. Also optional for action='delete' when delete_recurring=true to filter which recurring reminders to delete."
                    ),
                    "reminder_id": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Single reminder UUID to delete."
                    ),
                    "reminder_ids": ParameterProperty(
                        type: "array",
                        description: "For action='delete'. Multiple reminder IDs to delete.",
                        items: ArrayItemsSchema(type: "string")
                    ),
                    "delete_all": ParameterProperty(
                        type: "boolean",
                        description: "For action='delete'. If true, deletes all pending reminders."
                    ),
                    "delete_recurring": ParameterProperty(
                        type: "boolean",
                        description: "For action='delete'. If true, deletes all pending recurring reminders. Optional recurrence filter can narrow to daily/weekly/monthly/every_X_minutes/every_X_hours."
                    )
                ],
                required: ["action"]
            )
        )
    )
        // MARK: - Conversation History Tool
    
    static let viewConversationChunk = ToolDefinition(
        function: FunctionDefinition(
            name: "view_conversation_chunk",
            description: "Access your long-term conversation memory. This tool has TWO uses: (1) LIST PAGINATED OLDER SUMMARIES: Call without chunk_id to list archived chunk summaries in pages of 15, newest to oldest, excluding summaries already shown in context. Use page=1 for the most recent older summaries and increment page to go further back. (2) VIEW FULL CHUNK: Call with a chunk_id to retrieve complete messages from that specific archived chunk.",
            parameters: FunctionParameters(
                properties: [
                    "chunk_id": ParameterProperty(
                        type: "string",
                        description: "Optional. If provided, returns the full messages from that chunk."
                    ),
                    "page": ParameterProperty(
                        type: "integer",
                        description: "Optional for summary listing mode (ignored when chunk_id is provided). 1-based page number. Each page shows 15 older summaries, ordered newest to oldest."
                    )
                ],
                required: []
            )
        )
    )
    // MARK: - Image Generation Tool
    
    static let generateImage = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_image",
            description: "Generate an image from a text description using AI, or transform/edit an existing image. Use when the user asks you to create, generate, draw, make, edit, or transform an image/picture/illustration. The generated image will be sent to the user in the chat. For image edits, provide source_image with the stored image filename from recent image/file metadata; this tool does not infer the most recent image automatically.",
            parameters: FunctionParameters(
                properties: [
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "A detailed description of the image to generate, or instructions for how to transform the source image. For new images: be specific about subjects, style, colors, lighting, composition, and mood. For edits: describe what changes to make (e.g., 'make the sky more dramatic', 'add a rainbow', 'convert to oil painting style')."
                    ),
                    "source_image": ParameterProperty(
                        type: "string",
                        description: "Optional. Stored image filename in the LocalAgent images store, e.g. 'abc123.jpg'. Required when editing a specific prior image. Use the exact basename from recent image/file metadata; do not pass an absolute path. Leave empty to generate a new image from scratch."
                    ),
                    "size": ParameterProperty(
                        type: "string",
                        description: "Optional output size. Supported values: '1K' (default), '2K', '4K'. Use '4K' when the user requests ultra-high resolution or when high-detail output is important.",
                        enumValues: ["1K", "2K", "4K"]
                    )
                ],
                required: ["prompt"]
            )
        )
    )
    
    // MARK: - URL Viewing and Download Tools

    static let webFetch = ToolDefinition(
        function: FunctionDefinition(
            name: "web_fetch",
            description: "IMPORTANT: web_fetch WILL FAIL for authenticated or private URLs. Before using this tool, check if the URL points to an authenticated service (e.g. Google Docs, Confluence, Jira, Notion). If so, look for a specialized MCP tool that provides authenticated access.\n\nFetches content from a URL and processes it with an AI model that extracts only the information matching your prompt. Use AFTER web_search or web_research_sweep when you need the content of a specific page. Returns a focused excerpt plus structured image and link arrays. If you want to actually SEE an image from the page, download it with bash curl -o /tmp/img.png <url> then read_file to view it multimodally. Ideal for: reading articles, documentation, product pages, API references, or any URL from search results where you need targeted information.\n\nUsage notes:\n- For GitHub URLs (PRs, issues, pull request diffs, repo contents), prefer using the gh CLI via bash instead — e.g. `gh pr view`, `gh issue view`, `gh api repos/<owner>/<repo>/...`. It handles auth automatically and is faster.\n- For a single known file in a public repo, `web_fetch` on the raw.githubusercontent.com URL is the lightest option (no clone, no API).\n- If the URL redirects to a different host, the tool will inform you and provide the redirect URL in the response. Make a new web_fetch request with the redirect URL to fetch the content.\n- The tool includes a short-lived cache so repeated calls on the same URL within a single session are cheap — you can re-fetch without worrying about re-ranking cost.",
            parameters: FunctionParameters(
                properties: [
                    "url": ParameterProperty(
                        type: "string",
                        description: "The full URL to fetch (e.g., 'https://example.com/article'). Must be http:// or https://."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "What you want to know from this page. Be specific — the tool extracts only the relevant excerpt using this prompt. Examples: 'How do I configure the X option?', 'Summarize the migration steps', 'What is the pricing for the pro plan?'. Vague prompts like 'summarize' produce noisier results."
                    )
                ],
                required: ["url", "prompt"]
            )
        )
    )

    // MARK: - Send Document to Telegram Chat
    
    static let sendDocumentToChat = ToolDefinition(
        function: FunctionDefinition(
            name: "send_document_to_chat",
            description: "Send a document or file directly to the user via Telegram. Use when the user asks you to send/share a file, document, or image. Accepts any absolute file path on the filesystem. This sends the file to the user as an external side effect.",
            parameters: FunctionParameters(
                properties: [
                    "file_path": ParameterProperty(
                        type: "string",
                        description: "Absolute path to the file to send (e.g. '/tmp/photo.jpg', '/Users/alice/Documents/report.pdf')."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption to include with the document."
                    )
                ],
                required: ["file_path"]
            )
        )
    )
        // MARK: - macOS Shortcuts Tools
    
    static let shortcuts = ToolDefinition(
        function: FunctionDefinition(
            name: "shortcuts",
            description: "Unified macOS Shortcuts tool. Use action='list' to discover available shortcuts. Use action='run' to execute a shortcut by exact name with optional input text. If a shortcut returns an image or other media, it will be made visible for analysis. Examples: {action:'list'} or {action:'run', name:'My Shortcut', input:'some text'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required shortcuts action: 'list' or 'run'.",
                        enumValues: ["list", "run"]
                    ),
                    "name": ParameterProperty(
                        type: "string",
                        description: "For action='run'. Exact name of the Shortcut to run, as shown in the Shortcuts app or from shortcuts action='list'."
                    ),
                    "input": ParameterProperty(
                        type: "string",
                        description: "For action='run'. Optional input text to pass to the shortcut. Some shortcuts accept input (text, URLs, etc.) to process."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    // MARK: - (legacy Code-CLI project tools removed in Phase 2 — the Agent subagent tool replaces them)

    // MARK: - Filesystem Tools (new surface)

    static let readFile = ToolDefinition(
        function: FunctionDefinition(
            name: "read_file",
            description: "Reads a file from the local filesystem. You can access any file directly by using this tool.\n\nUsage:\n- The path parameter must be an absolute path, not a relative path.\n- By default, it reads up to 2000 lines starting from the beginning of the file.\n- Whole-file reads are capped at 256 KB. Files larger than that must be read with offset/limit parameters to read specific portions, or you should search for specific content instead of reading the whole file.\n- When you already know which part of the file you need, only read that part. This can be important for larger files.\n- Results are returned with 1-indexed line numbers prepended in the format '  42→content'. IMPORTANT: when passing content back to edit_file as old_string, DO NOT include the line-number prefix — it is display-only, not part of the file.\n- This tool allows you to read images (PNG, JPG, etc). Image files are attached as multimodal content — they become visible to you as a user-role attachment on the next turn (you do NOT see them inside the tool result).\n- This tool can read PDF files (.pdf). Small PDFs (≤10 pages) are attached whole. For larger PDFs, the 'pages' parameter is REQUIRED — specify a range like '1-5', '3', or '10-20' (max 20 pages per call); call again with a different range to page through.\n- This tool can only read files, not directories. To list directory contents, use list_dir.\n- You will regularly be asked to read screenshots. If the user provides a path to a screenshot, ALWAYS use this tool to view the file at the path.\n- If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.\n- Do NOT re-read a file you just edited to verify — edit_file/write_file would have errored if the change failed, and the harness tracks file state for you.\n- Use list_recent_files or glob/list_dir to discover paths first when you don't know the absolute path.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path (starts with '/' or '~'). Relative paths are rejected."),
                    "offset": ParameterProperty(type: "integer", description: "Optional 1-indexed starting line for text files. Omit to start from line 1."),
                    "limit": ParameterProperty(type: "integer", description: "Optional line limit (default 2000, also capped at 256 KB of output)."),
                    "pages": ParameterProperty(type: "string", description: "PDF only. Page range like '1-5', '3', or '10-20'. Required when the PDF has more than 10 pages. Max 20 pages per call. Ignored for non-PDF files.")
                ],
                required: ["path"]
            )
        )
    )

    static let writeFile = ToolDefinition(
        function: FunctionDefinition(
            name: "write_file",
            description: "Writes a file to the local filesystem.\n\nUsage:\n- This tool will overwrite the existing file if there is one at the provided path.\n- If this is an existing file, you MUST use the read_file tool first to read the file's contents. This tool will fail if you did not read the file first.\n- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.\n- Prefer apply_patch for modifying existing code. Use this tool only to create new files or for complete rewrites.\n- Parent directories are created automatically.\n- NEVER create documentation files (*.md) or README files unless explicitly requested by the user.\n- Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.\n- The result includes a 'diff' field (unified-diff preview, capped 50 lines / 4 KB) and a 'diagnostics' array (errors/warnings from sourcekit-lsp / typescript-language-server / pylsp / gopls / rust-analyzer) — inspect both; always re-read and fix before continuing if any diagnostic has severity='error'.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to write."),
                    "content": ParameterProperty(type: "string", description: "Full file contents as a string."),
                    "description": ParameterProperty(type: "string", description: "Optional short description of the file's purpose. Stored in the ledger for later list_recent_files queries.")
                ],
                required: ["path", "content"]
            )
        )
    )

    static let editFile = ToolDefinition(
        function: FunctionDefinition(
            name: "edit_file",
            description: "Performs string replacements in files. Prefer apply_patch for code edits; use this for tiny one-location replacements or as a fallback after apply_patch fails.\n\nUsage:\n- You must use the read_file tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.\n- When editing text from read_file output, preserve the exact indentation (tabs/spaces) after the display-only line prefix. The line prefix looks like '42→' or ' 42→'. Everything after the arrow is actual file content to match. Never include any part of the line number prefix in old_string or new_string.\n- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.\n- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.\n- The edit will FAIL if old_string is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use replace_all to change every instance of old_string.\n- Use replace_all for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.\n- The result includes a 'diff' field (unified-diff preview, capped 50 lines / 4 KB) and diagnostics. If 'match_strategy_warning' appears, inspect the diff carefully and prefer apply_patch next time.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to the file."),
                    "old_string": ParameterProperty(type: "string", description: "Exact substring to find. Include enough surrounding context to make the match unique. Must match whitespace and indentation exactly."),
                    "new_string": ParameterProperty(type: "string", description: "Replacement text. Must differ from old_string."),
                    "replace_all": ParameterProperty(type: "boolean", description: "Optional. When true, replaces every occurrence of old_string; otherwise old_string must be unique.")
                ],
                required: ["path", "old_string", "new_string"]
            )
        )
    )

    static let applyPatch = ToolDefinition(
        function: FunctionDefinition(
            name: "apply_patch",
            description: "Apply a multi-file Codex-style patch atomically. This is the preferred tool for code edits, especially coordinated edits across one or more files. All operations are validated against current file contents before any disk write; on failure, nothing is modified.\n\nEnvelope format:\n*** Begin Patch\n*** Update File: /abs/path\n@@ optional anchor (e.g. a function signature)\n context line\n-removed line\n+added line\n*** Add File: /abs/path\n+new file line 1\n+new file line 2\n*** Delete File: /abs/path\n*** End Patch\n\nFor Update with rename, add '*** Move to: /new/abs/path' directly after the Update File header.\n\nThe result includes 'diffs_by_file' (unified-diff preview per path, capped) and 'diagnostics_by_file' (per-path map with the same 'diagnostics' / 'diagnostics_skipped' / 'diagnostics_summary' shape returned by write_file). Inspect both — re-read and fix any file with severity='error' before continuing.",
            parameters: FunctionParameters(
                properties: [
                    "patch_text": ParameterProperty(type: "string", description: "The full patch text including the Begin/End Patch markers.")
                ],
                required: ["patch_text"]
            )
        )
    )

    static let grep = ToolDefinition(
        function: FunctionDefinition(
            name: "grep",
            description: "A powerful search tool built on ripgrep.\n\nUsage:\n- ALWAYS use grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The grep tool has been optimized for correct permissions, ignore lists, and output shaping — the Bash equivalents bypass all of that.\n- Supports full regex syntax (e.g., \"log.*Error\", \"function\\s+\\w+\").\n- Filter files with the include glob parameter (e.g., \"*.js\", \"**/*.tsx\") or type parameter (e.g., \"js\", \"py\", \"rust\").\n- Output modes: \"content\" shows matching lines (supports context_before/context_after/context), \"files_with_matches\" shows only file paths (use when you only need to know which files contain the pattern — much cheaper), \"count\" shows match counts per file.\n- Pattern syntax: uses ripgrep (not POSIX grep) — literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code).\n- Multiline matching: by default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`.\n- Use the Agent tool for open-ended searches requiring multiple rounds of grep/glob.\n- 100-entry cap, 2000-char-per-line cap, results sorted by mtime descending. Common project ignores (.git, node_modules, DerivedData, etc.) are always applied.",
            parameters: FunctionParameters(
                properties: [
                    "pattern": ParameterProperty(type: "string", description: "Regex pattern to search for (ripgrep/ECMAScript-compatible)."),
                    "path": ParameterProperty(type: "string", description: "Absolute directory path to search under."),
                    "include": ParameterProperty(type: "string", description: "Optional filename glob to filter, e.g. '*.swift' or '*.{ts,tsx}'."),
                    "type": ParameterProperty(type: "string", description: "Optional ripgrep file-type filter (e.g. 'swift', 'ts', 'py', 'rust'). More efficient than include for standard languages. Requires ripgrep. Run `rg --type-list` to see all types."),
                    "output_mode": ParameterProperty(type: "string", description: "Output shape: 'content' (default, returns matching lines), 'files_with_matches' (returns just file paths — use when you only need to know which files contain the pattern), or 'count' (returns match counts per file). Prefer files_with_matches when scanning a large repo; it's much cheaper than reading every matching line.", enumValues: ["content", "files_with_matches", "count"]),
                    "case_insensitive": ParameterProperty(type: "boolean", description: "Optional. If true, matches regardless of case (equivalent to ripgrep -i). Default false."),
                    "multiline": ParameterProperty(type: "boolean", description: "Optional. If true, allows regex patterns to span multiple lines (`.` matches newlines). Useful for patterns like 'struct Foo \\{[\\s\\S]*?bar'. Default false."),
                    "context_after": ParameterProperty(type: "integer", description: "Optional. Lines of context to show AFTER each match (content mode only). Prefer this over the legacy -A alias."),
                    "context_before": ParameterProperty(type: "integer", description: "Optional. Lines of context to show BEFORE each match (content mode only). Prefer this over the legacy -B alias."),
                    "context": ParameterProperty(type: "integer", description: "Optional. Lines of context to show BOTH before and after each match (content mode only). Prefer this over the legacy -C alias."),
                    "-A": ParameterProperty(type: "integer", description: "Legacy alias for context_after. Optional lines of context to show AFTER each match (content mode only)."),
                    "-B": ParameterProperty(type: "integer", description: "Legacy alias for context_before. Optional lines of context to show BEFORE each match (content mode only)."),
                    "-C": ParameterProperty(type: "integer", description: "Legacy alias for context. Optional lines of context to show BOTH before and after each match (content mode only)."),
                    "max_results": ParameterProperty(type: "integer", description: "Optional. Maximum entries (lines/files) to return (default 100, hard cap 100).")
                ],
                required: ["pattern", "path"]
            )
        )
    )

    static let glob = ToolDefinition(
        function: FunctionDefinition(
            name: "glob",
            description: "Fast file pattern matching tool that works with any codebase size.\n\nUsage:\n- Supports glob patterns like \"**/*.js\" or \"src/**/*.ts\".\n- Returns matching file paths sorted by modification time.\n- Use this tool when you need to find files by name patterns.\n- Use instead of bash find/ls — the glob tool has optimized permissions and output.\n- When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead.\n- 100-file cap.",
            parameters: FunctionParameters(
                properties: [
                    "pattern": ParameterProperty(type: "string", description: "Glob pattern, e.g. '**/*.swift', 'README.md', 'src/*.ts'."),
                    "path": ParameterProperty(type: "string", description: "Optional absolute directory to search under. Defaults to the user's home directory."),
                    "max_results": ParameterProperty(type: "integer", description: "Optional. Maximum file paths to return (default 100, hard cap 100).")
                ],
                required: ["pattern"]
            )
        )
    )

    static let listDir = ToolDefinition(
        function: FunctionDefinition(
            name: "list_dir",
            description: "List the immediate contents of a directory with sizes and mtimes. Honors a baked-in ignore list for common junk (.git, node_modules, DerivedData, etc.). 100-entry cap. Use this for on-demand filesystem inspection; use list_recent_files to see what you've touched recently.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute directory path."),
                    "ignore": ParameterProperty(
                        type: "array",
                        description: "Optional array of additional names to skip.",
                        items: ArrayItemsSchema(type: "string")
                    )
                ],
                required: ["path"]
            )
        )
    )

    static let listRecentFiles = ToolDefinition(
        function: FunctionDefinition(
            name: "list_recent_files",
            description: "Show files you've recently written, generated, or received (from Telegram, email, or downloads). This reads an in-app ledger — not the disk — so it spans the whole filesystem. Sorted by last-touched descending. Use this to re-find something the user sent earlier without knowing where on disk it lives.",
            parameters: FunctionParameters(
                properties: [
                    "limit": ParameterProperty(type: "integer", description: "Optional page size (default 20)."),
                    "offset": ParameterProperty(type: "integer", description: "Optional pagination offset (default 0)."),
                    "filter_origin": ParameterProperty(type: "string", description: "Optional filter by origin.", enumValues: ["edited", "generated", "telegram", "email", "download"])
                ],
                required: []
            )
        )
    )

    static let bash = ToolDefinition(
        function: FunctionDefinition(
            name: "bash",
            description: "Executes a given shell command via /bin/zsh -lc and returns its output.\n\nThe working directory does not persist between calls — use the workdir parameter on each call if you need a specific directory. Supports ~ and $VAR expansion.\n\nIMPORTANT: Avoid using this tool to run `find`, `grep`, `rg`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:\n\n - File search: use glob (NOT find or ls)\n - Content search: use grep (NOT grep or rg)\n - Read files: use read_file (NOT cat/head/tail)\n - Edit files: use edit_file (NOT sed/awk)\n - Write files: use write_file (NOT echo >/cat <<EOF)\n - Communication: output text directly (NOT echo/printf)\n\nWhile the bash tool can do similar things, it's better to use the built-in tools as they provide a better experience and make it easier to review tool calls and give permission.\n\nForeground (default): waits for the command to finish, returns stdout/stderr/exit_code. Default 120s timeout, 600s hard max, 30 KB output cap per stream.\n\nBackground (run_in_background=true): returns immediately with a handle like 'bash_1' and the process keeps running. You will be notified automatically when it exits. Use bash_manage(mode='output') to peek at live output, bash_manage(mode='kill') to stop it, or bash_manage(mode='watch') to subscribe to regex matches. Use background mode for dev servers, long builds, and any command that may exceed the foreground timeout.",
            parameters: FunctionParameters(
                properties: [
                    "command": ParameterProperty(type: "string", description: "The shell command to run."),
                    "timeout_ms": ParameterProperty(type: "integer", description: "Optional foreground timeout in milliseconds (max 600000). Ignored when run_in_background=true."),
                    "workdir": ParameterProperty(type: "string", description: "Optional absolute working directory. Must exist."),
                    "description": ParameterProperty(type: "string", description: "Short 5-10 word description of what the command does (for your own future reference in background mode)."),
                    "run_in_background": ParameterProperty(type: "boolean", description: "Optional. When true, spawn detached and return a handle immediately."),
                    "service_key_env": ParameterProperty(type: "object", description: "Optional per-command secret injection. Maps the CLI-expected env-var name to the friendly service key label. Example: {\"VERCEL_TOKEN\": \"Vercel Token\"} — the app resolves the label to the real secret and injects VERCEL_TOKEN=<secret> into this command's environment only. The secret never appears in the conversation.")
                ],
                required: ["command"]
            )
        )
    )

    static let bashManage = ToolDefinition(
        function: FunctionDefinition(
            name: "bash_manage",
            description: "Manage background bash processes. Four modes: (1) 'output' — read accumulated stdout/stderr without stopping the process, with optional incremental reads via 'since' byte offset. (2) 'input' — write text to the running process's stdin; set append_newline=true for line-oriented prompts. This is pipe-based stdin, not a real TTY. (3) 'watch' — subscribe to live output matching a regex pattern; matches arrive as synthetic [BASH WATCH MATCH] user messages so you can react immediately. Auto-unsubscribes after 'limit' matches or on process exit. (4) 'kill' — send SIGTERM then SIGKILL after a grace period.",
            parameters: FunctionParameters(
                properties: [
                    "mode": ParameterProperty(
                        type: "string",
                        description: "Action to perform on the background process.",
                        enumValues: ["output", "input", "watch", "kill"]
                    ),
                    "handle": ParameterProperty(
                        type: "string",
                        description: "The background bash handle (e.g. 'bash_1') returned by bash(run_in_background=true)."
                    ),
                    "since": ParameterProperty(
                        type: "integer",
                        description: "For mode='output' only. Byte offset into stdout stream for incremental reads. Omit or pass 0 for full output."
                    ),
                    "text": ParameterProperty(
                        type: "string",
                        description: "For mode='input' only. Text to write to the process's stdin. This is sent exactly unless append_newline=true."
                    ),
                    "append_newline": ParameterProperty(
                        type: "boolean",
                        description: "For mode='input' only. If true, appends a single newline after text. Default false."
                    ),
                    "pattern": ParameterProperty(
                        type: "string",
                        description: "For mode='watch' only. Regex (POSIX/NSRegularExpression) matched against each line of stdout/stderr. Case-sensitive; prefix with (?i) for case-insensitive."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "For mode='watch' only. Max match events before auto-unsubscribe. Default 10, range 1-50."
                    )
                ],
                required: ["mode", "handle"]
            )
        )
    )

    static let todoWrite = ToolDefinition(
        function: FunctionDefinition(
            name: "todo_write",
            description: "Plan and track multi-step work. Send the FULL desired todo list every call — it replaces the stored state (same semantics as Claude Code's TodoWrite and OpenCode's todowrite). Use for any non-trivial task: break work into discrete steps, mark exactly one step as in_progress while you work on it, mark each completed as soon as it's done. Over-use beats under-use.",
            parameters: FunctionParameters(
                properties: [
                    "todos": ParameterProperty(
                        type: "array",
                        description: "Complete todo list. Replaces stored state on every call. Only one item may be in_progress at a time.",
                        items: ArrayItemsSchema(
                            type: "object",
                            description: "A single todo entry.",
                            properties: [
                                "content": ParameterProperty(
                                    type: "string",
                                    description: "Past/present-tense noun describing the task (e.g. 'Build the LSP client')."
                                ),
                                "activeForm": ParameterProperty(
                                    type: "string",
                                    description: "Imperative form shown while the task is in_progress (e.g. 'Building the LSP client')."
                                ),
                                "status": ParameterProperty(
                                    type: "string",
                                    description: "Lifecycle state of this item.",
                                    enumValues: ["pending", "in_progress", "completed"]
                                )
                            ],
                            required: ["content", "activeForm", "status"]
                        )
                    )
                ],
                required: ["todos"]
            )
        )
    )

    static let lsp = ToolDefinition(
        function: FunctionDefinition(
            name: "lsp",
            description: "Query the language server for symbol information. Three modes: (1) 'hover' — type signature, docstring, brief description of the symbol at the given position. (2) 'definition' — go-to-definition, returns locations {path, line, column, end_line, end_column}. Much more accurate than grep because the language server understands scope and imports. (3) 'references' — find every use of a symbol across the workspace. Prefer over grep for code-symbol search. All positions are 1-indexed to match read_file output.",
            parameters: FunctionParameters(
                properties: [
                    "mode": ParameterProperty(
                        type: "string",
                        description: "LSP operation to perform.",
                        enumValues: ["hover", "definition", "references"]
                    ),
                    "path": ParameterProperty(type: "string", description: "Absolute path to the file."),
                    "line": ParameterProperty(type: "integer", description: "1-indexed line number of the symbol."),
                    "column": ParameterProperty(type: "integer", description: "1-indexed column of the symbol."),
                    "include_declaration": ParameterProperty(type: "boolean", description: "For mode='references' only. Include the declaration site in results. Default true.")
                ],
                required: ["mode", "path", "line", "column"]
            )
        )
    )

    // MARK: - Agent / Subagent Tool

    /// Agent tool — dynamic enum values include built-in subagents plus any user-defined ones
    /// discovered via `UserAgentLoader`. The definition is computed so new user agents appear
    /// on the next tool-list build without a restart. Per-subagent descriptions are injected
    /// into the tool's free-text description so the LLM knows what each one does, not just
    /// that it exists.
    static var agentTool: ToolDefinition {
        let allSubagents = SubagentTypes.all()
        let subagentNames = allSubagents.map { $0.name }
        let listing = allSubagents
            .map { "  - \($0.name): \($0.description)" }
            .joined(separator: "\n")
        let description = """
        Launch a new subagent with a fresh, isolated context for focused work. Useful for broad codebase exploration, architectural planning, or focused investigations that would otherwise bloat your own context. The subagent has its own tools and returns only its final message to you.

        Available subagents:
        \(listing)

        ## When not to use

        If the target is already known, use the direct tool: read_file for a known path, grep for a specific symbol or string. Reserve this tool for open-ended questions that span the codebase, or tasks that match an available subagent type.

        ## Usage notes

        - Always include a short description summarizing what the subagent will do.
        - When you launch multiple subagents for independent work, send them in a single message with multiple tool uses so they run concurrently.
        - When the subagent is done, it will return a single message back to you. The result returned is not visible to the user; relay the relevant findings yourself.
        - Trust but verify: a subagent's summary describes what it intended to do, not necessarily what it did. When a subagent writes or edits code, check the actual changes before reporting the work as done.
        - You can optionally run subagents in the background using run_in_background. When one completes, you'll be notified via a synthetic [SUBAGENT COMPLETE] message — do NOT sleep, poll, or proactively check on its progress.
        - **Foreground vs background**: Use foreground (default) when you need the subagent's results before you can proceed. Use background when you have genuinely independent work to do in parallel.
        - To continue a previously spawned subagent, pass its session_id — that resumes it with full context. A new Agent call starts a fresh subagent with no memory of prior runs.
        - Clearly tell the subagent whether you expect it to write code or just do research (search, file reads, web fetches), since it is not aware of the user's intent.
        - Subagents CANNOT spawn other subagents. Provide a self-contained prompt — the subagent sees none of your conversation history.

        ## Writing the prompt

        Brief the subagent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.
        - Explain what you're trying to accomplish and why.
        - Describe what you've already learned or ruled out.
        - Give enough context about the surrounding problem that the subagent can make judgment calls rather than just following a narrow instruction.
        - If you need a short response, say so ("report in under 200 words").
        - Lookups: hand over the exact command. Investigations: hand over the question — prescribed steps become dead weight when the premise is wrong.

        Terse command-style prompts produce shallow, generic work.

        **Never delegate understanding.** Don't write "based on your findings, fix the bug" or "based on the research, implement it." Those phrases push synthesis onto the subagent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, what specifically to change.
        """
        return ToolDefinition(
            function: FunctionDefinition(
                name: "Agent",
                description: description,
                parameters: FunctionParameters(
                    properties: [
                        "subagent_type": ParameterProperty(
                            type: "string",
                            description: "Which subagent to spawn (for new sessions) or which type the existing session belongs to (for resumes).",
                            enumValues: subagentNames
                        ),
                        "description": ParameterProperty(
                            type: "string",
                            description: "A short (3-5 word) description of the task. Used for progress display."
                        ),
                        "prompt": ParameterProperty(
                            type: "string",
                            description: "The task or continuation message. For new sessions: the full self-contained task. For resumed sessions: the follow-up instruction (the subagent already has its prior context)."
                        ),
                        "session_id": ParameterProperty(
                            type: "string",
                            description: "Optional. Pass a session_id from a prior Agent call to resume that subagent's conversation with its full prior context intact. Omit to start a fresh session. Every Agent call returns a session_id in its result — save it if you might want to continue later. Use subagent_manage(mode='list_sessions') to see all available sessions."
                        ),
                        "run_in_background": ParameterProperty(
                            type: "boolean",
                            description: "Optional. When true, run the subagent in the background and receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Useful for long-running Explore or Plan tasks so the parent can continue in parallel. Default false (synchronous)."
                        ),
                        "model": ParameterProperty(
                            type: "string",
                            description: "Optional per-task model override. Leave empty to inherit parent model.",
                            enumValues: ["sonnet", "opus", "haiku", "inherit"]
                        )
                    ],
                    required: ["subagent_type", "description", "prompt"]
                )
            )
        )
    }

    static let subagentManage = ToolDefinition(
        function: FunctionDefinition(
            name: "subagent_manage",
            description: "Manage background subagents. Three modes: (1) 'list_running' — list every subagent currently running in the background. Returns {handle, subagent_type, description, started_at, running_seconds} for each. (2) 'list_sessions' — list all subagent sessions from this app run, sorted by most-recently-used. Each session is resumable by passing its session_id to the Agent tool. (3) 'cancel' — cancel a running background subagent by handle. Cancellation is best-effort at the next turn boundary.",
            parameters: FunctionParameters(
                properties: [
                    "mode": ParameterProperty(
                        type: "string",
                        description: "Action to perform.",
                        enumValues: ["list_running", "list_sessions", "cancel"]
                    ),
                    "handle": ParameterProperty(
                        type: "string",
                        description: "For mode='cancel' only. The handle returned by Agent(run_in_background=true), e.g. 'subagent_1'."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "For mode='list_sessions' only. Max sessions to return. Default 20."
                    ),
                    "offset": ParameterProperty(
                        type: "integer",
                        description: "For mode='list_sessions' only. Number of sessions to skip for pagination. Default 0."
                    )
                ],
                required: ["mode"]
            )
        )
    )

    // MARK: - Skills

    static let skill = ToolDefinition(
        function: FunctionDefinition(
            name: "skill",
            description: "Load a curated procedural skill from ~/LocalAgent/skills/ into your context. Skills are hand-authored guides for specialized tasks (e.g., generating a polished PDF). The compact skill index at the top of the system prompt lists every installed skill and its trigger description — when a user's request matches one, call this tool with the skill's name BEFORE starting the task, then follow the procedure the skill returns. Skills are reference material: combine them with your own judgment, don't recite them verbatim. Calling this tool is cheap (it's a local file read) and the loaded body stays available for the rest of the session. You CANNOT create new skills via this tool — the user curates them manually.",
            parameters: FunctionParameters(
                properties: [
                    "skill_name": ParameterProperty(type: "string", description: "The canonical short name of the skill, matching its entry in the skills index (e.g., 'pdf'). Case-insensitive.")
                ],
                required: ["skill_name"]
            )
        )
    )

    // MARK: - Deferred MCP Discovery

    static let toolSearch = ToolDefinition(
        function: FunctionDefinition(
            name: "tool_search",
            description: "Fetch the full tool schemas for a deferred MCP server. Call this when you see a server listed in the 'On-demand MCPs' section of the system prompt and decide you need its tools. Returns every tool name, description, and parameter schema as formatted text. After reading the result, use mcp_call to invoke specific tools.",
            parameters: FunctionParameters(
                properties: [
                    "server": ParameterProperty(type: "string", description: "The MCP server name exactly as shown in the on-demand list (e.g. 'playwright').")
                ],
                required: ["server"]
            )
        )
    )

    static let mcpCall = ToolDefinition(
        function: FunctionDefinition(
            name: "mcp_call",
            description: "Invoke a tool on a deferred MCP server. Use tool_search first to discover available tools and their parameter schemas, then call this with the exact tool name and arguments. The server must be listed in the on-demand MCPs section.",
            parameters: FunctionParameters(
                properties: [
                    "server": ParameterProperty(type: "string", description: "The MCP server name (e.g. 'playwright')."),
                    "tool": ParameterProperty(type: "string", description: "The tool name as returned by tool_search (e.g. 'browser_navigate')."),
                    "arguments": ParameterProperty(type: "object", description: "The tool's arguments as a JSON object. Pass {} if the tool takes no arguments.")
                ],
                required: ["server", "tool", "arguments"]
            )
        )
    )

    // MARK: - Tool Arrays

    /// New filesystem tool surface (replaces the sandboxed document tools).
    static var filesystemTools: [ToolDefinition] {
        [readFile, writeFile, editFile, applyPatch, grep, glob, listDir, listRecentFiles, bash, bashManage, todoWrite, lsp]
    }

    /// Non-email tools that do not depend on web search credentials.
    ///
    /// As of the gws-CLI migration, Gmail / Calendar / Contacts no longer have
    /// dedicated tools — the agent invokes them via `bash gws …`. Ambient inbox
    /// snapshot + 30-day agenda are still injected into the system prompt via
    /// GoogleWorkspaceService.
    ///
    /// When `localagent.subagentsEnabled` is false in UserDefaults, the Agent
    /// tool and its management tool (subagent_manage) are omitted — gives a
    /// fully local setup a way to disable cloud-delegating tools in one switch.
    static var coreToolsWithoutWebSearch: [ToolDefinition] {
        let subagentsEnabled = UserDefaults.standard.object(forKey: "localagent.subagentsEnabled") as? Bool ?? true
        let subagentTools: [ToolDefinition] = subagentsEnabled
            ? [agentTool, subagentManage]
            : []
        return filesystemTools + [manageReminders, viewConversationChunk, generateImage, sendDocumentToChat, shortcuts] + subagentTools + [skill]
    }

    /// All available tools. `includeWebSearch` toggles whether the four web tools
    /// are added; `hasDeferredMCPs` adds the `tool_search` and `mcp_call` proxy
    /// tools for on-demand MCP discovery. Email/calendar/contacts tools have
    /// been fully removed from the agent surface in favor of the gws CLI.
    static func all(includeWebSearch: Bool, hasDeferredMCPs: Bool = false) -> [ToolDefinition] {
        let webTools = includeWebSearch ? [webSearch, webResearchSweep, webFetch] : []
        let deferredTools: [ToolDefinition] = hasDeferredMCPs ? [toolSearch, mcpCall] : []
        return webTools + coreToolsWithoutWebSearch + deferredTools
    }

    /// Backward-compatible default: include web search
    static var all: [ToolDefinition] {
        all(includeWebSearch: true)
    }
}
