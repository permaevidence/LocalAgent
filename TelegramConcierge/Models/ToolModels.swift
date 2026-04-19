import Foundation

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

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
    }

    init(type: String, description: String, enumValues: [String]? = nil, items: ArrayItemsSchema? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
    }

    // Manual encode so nil fields are omitted rather than serialised as
    // `"items": null` (some providers reject null schema nodes).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(enumValues, forKey: .enumValues)
        try c.encodeIfPresent(items, forKey: .items)
    }
}

/// Schema describing the element of an `array`-typed parameter. Supports
/// primitive items (e.g. `{ type: "string" }`) and object items with their
/// own properties / required list.
struct ArrayItemsSchema: Codable {
    let type: String                                    // "string" | "number" | "integer" | "boolean" | "object"
    let description: String?
    let enumValues: [String]?
    let properties: [String: ParameterProperty]?        // populated when type == "object"
    let required: [String]?                             // populated when type == "object"

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required
        case enumValues = "enum"
    }

    init(
        type: String,
        description: String? = nil,
        enumValues: [String]? = nil,
        properties: [String: ParameterProperty]? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.properties = properties
        self.required = required
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(enumValues, forKey: .enumValues)
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
}

struct ToolResultMessage: Codable {
    let role: String
    let toolCallId: String
    var content: String
    
    /// Optional files to inject as multimodal content (not serialized to API directly)
    var fileAttachments: [FileAttachment]
    
    /// Optional spend associated with tool-internal API calls (not serialized to API directly)
    var spendUSD: Double?
    
    enum CodingKeys: String, CodingKey {
        case role
        case toolCallId = "tool_call_id"
        case content
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
        self.spendUSD = spendUSD
    }
    
    // Manual Decodable conformance - fileAttachments is not serialized
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
        self.content = try container.decode(String.self, forKey: .content)
        self.fileAttachments = [] // Not decoded, only used transiently
        self.spendUSD = nil // Not decoded, only used transiently
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
    case text(String, promptTokens: Int?, spendUSD: Double?)
    case toolCalls(assistantMessage: AssistantToolCallMessage, calls: [ToolCall], promptTokens: Int?, spendUSD: Double?)
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
                        type: "string",
                        description: "For action='delete'. Multiple reminder IDs as JSON array string or CSV (e.g. [\"id1\",\"id2\"] or \"id1,id2\")."
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
        // MARK: - Document Tools
    
    static let listDocuments = ToolDefinition(
        function: FunctionDefinition(
            name: "list_documents",
            description: "List stored documents ranked by recent usage (most recently opened first; never-opened files fall back to newest created first). Use this to find document filenames before attaching them to emails. Supports pagination: pass limit (default 40, max 100) and cursor (from previous response next_cursor) to continue browsing older files page by page. Returns universal ISO 8601 UTC timestamps for each document.",
            parameters: FunctionParameters(
                properties: [
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Optional number of documents to return per page. Default 40, max 100."
                    ),
                    "cursor": ParameterProperty(
                        type: "string",
                        description: "Optional pagination cursor from a previous list_documents response (next_cursor). Omit on first call to get the latest documents."
                    )
                ],
                required: []
            )
        )
    )
    
    static let readDocument = ToolDefinition(
        function: FunctionDefinition(
            name: "read_document",
            description: "Open and read one or more documents from local file storage. Use proactively to view, analyze, read, or examine files that are relevant to the user's request, but of which you can only see the name and description. It is important that you see first hand the documents that you are analyzing. It returns raw file data (images, PDFs, documents) for direct multimodal analysis. You can open up to 10 documents per call. You can use list_documents to find available files to read/open.",
            parameters: FunctionParameters(
                properties: [
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of document filenames to read (from list_documents). Supports 1 to 10 files per call. Example: [\"a.pdf\", \"b.jpg\"]."
                    ),
                    "document_filename": ParameterProperty(
                        type: "string",
                        description: "Optional legacy single filename form (from list_documents, e.g. 'abc123.pdf'). Prefer document_filenames."
                    )
                ],
                required: ["document_filenames"]
            )
        )
    )
        // MARK: - Contact Tools
    
    // MARK: - Image Generation Tool
    
    static let generateImage = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_image",
            description: "Generate an image from a text description using AI, or transform/edit an existing image. Use when the user asks you to create, generate, draw, make, edit, or transform an image/picture/illustration. The generated image will be sent to the user in the chat. When editing a user's image, reference the most recently received image file.",
            parameters: FunctionParameters(
                properties: [
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "A detailed description of the image to generate, or instructions for how to transform the source image. For new images: be specific about subjects, style, colors, lighting, composition, and mood. For edits: describe what changes to make (e.g., 'make the sky more dramatic', 'add a rainbow', 'convert to oil painting style')."
                    ),
                    "source_image": ParameterProperty(
                        type: "string",
                        description: "Optional. The filename of an image previously sent in the conversation to use as source for transformation/editing. Use the exact filename (e.g., 'abc123.jpg') from a previously received image. Leave empty to generate a new image from scratch."
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
            description: "IMPORTANT: web_fetch WILL FAIL for authenticated or private URLs. Before using this tool, check if the URL points to an authenticated service (e.g. Google Docs, Confluence, Jira, Notion). If so, look for a specialized MCP tool that provides authenticated access.\n\nFetches content from a URL and processes it with an AI model that extracts only the information matching your prompt. Use AFTER web_search or web_research_sweep when you need the content of a specific page. Returns a focused excerpt plus structured image and link arrays. If you want to actually SEE an image from the page, use web_fetch_image with an image URL from the images array. Ideal for: reading articles, documentation, product pages, API references, or any URL from search results where you need targeted information.\n\nUsage notes:\n- For GitHub URLs (PRs, issues, pull request diffs, repo contents), prefer using the gh CLI via bash instead — e.g. `gh pr view`, `gh issue view`, `gh api repos/<owner>/<repo>/...`. It handles auth automatically and is faster.\n- For a single known file in a public repo, `web_fetch` on the raw.githubusercontent.com URL is the lightest option (no clone, no API).\n- If the URL redirects to a different host, the tool will inform you and provide the redirect URL in the response. Make a new web_fetch request with the redirect URL to fetch the content.\n- The tool includes a short-lived cache so repeated calls on the same URL within a single session are cheap — you can re-fetch without worrying about re-ranking cost.",
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

    static let webFetchImage = ToolDefinition(
        function: FunctionDefinition(
            name: "web_fetch_image",
            description: "Download and view a specific image from a webpage. Use AFTER web_fetch when you want to actually see and analyze an image. The images array from web_fetch contains captions and URLs - use the caption to decide which image is relevant, then call this tool with the image_url. The downloaded image will be visible to you for analysis.",
            parameters: FunctionParameters(
                properties: [
                    "image_url": ParameterProperty(
                        type: "string",
                        description: "Direct URL to the image to download and view. Use the url field from an image in the images array returned by web_fetch."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption or description for the image (from the web_fetch response). Helps with context."
                    )
                ],
                required: ["image_url"]
            )
        )
    )
    
    static let downloadFromUrl = ToolDefinition(
        function: FunctionDefinition(
            name: "download_from_url",
            description: "Download a file or image from a URL. Use to save images, PDFs, documents, or other files from the web. The file is saved locally and you can reference it in subsequent messages or attach it to emails. Supports: images (jpg, png, gif, webp), PDFs, and common document formats.",
            parameters: FunctionParameters(
                properties: [
                    "url": ParameterProperty(
                        type: "string",
                        description: "Direct URL to the file to download (e.g., 'https://example.com/image.jpg'). Must be a direct link to the file, not a webpage."
                    ),
                    "filename": ParameterProperty(
                        type: "string",
                        description: "Optional preferred filename for the downloaded file. If not provided, will be derived from the URL or generated."
                    )
                ],
                required: ["url"]
            )
        )
    )
    
    // MARK: - Document Generation Tool
    
    static let generateDocument = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_document",
            description: "Generate a document file (PDF, Word, or Excel/CSV) with specified content. Use for: creating reports, summaries, spreadsheets, formal documents, invoices, meeting notes, OR full-page image PDFs. For fullscreen images, use layout='fullscreen_image' with image_filename. IMPORTANT: When embedding images in PDFs, use read_document first to preview the image and verify it's appropriate for the content before referencing it. Generated files are saved and automatically sent via Telegram.",
            parameters: FunctionParameters(
                properties: [
                    "document_type": ParameterProperty(
                        type: "string",
                        description: "Type of document: 'pdf' (best for formatted reports, letters, or fullscreen images), 'excel' (CSV format, best for data/tables), or 'word' (RTF format, best for editable documents).",
                        enumValues: ["pdf", "excel", "word"]
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "Document title - used as filename and shown as main heading. Optional for fullscreen_image layout."
                    ),
                    "layout": ParameterProperty(
                        type: "string",
                        description: "PDF layout mode: 'standard' (default, with title/sections/margins) or 'fullscreen_image' (image fills entire page with no margins or title). Only applies to PDFs.",
                        enumValues: ["standard", "fullscreen_image"]
                    ),
                    "image_filenames": ParameterProperty(
                        type: "string",
                        description: "Required for fullscreen_image layout. Array of image filenames (e.g. [\"photo1.jpg\", \"photo2.jpg\"]) or single filename. Each image becomes a full page in the PDF. Use list_documents to find available images."
                    ),
                    "sections": ParameterProperty(
                        type: "string",
                        description: "JSON array of section objects for PDF/Word. Each section can have: 'heading' (string), 'body' (string), 'bullet_points' (array of strings), 'table' (object with 'headers' array and 'rows' 2D array), 'image' (object with 'filename' from documents/images directory, optional 'caption', optional 'width' as percentage 10-100 of page width default 50, optional 'alignment' left/center/right default center). Example: [{\"heading\":\"Introduction\",\"body\":\"Text here\"}]"
                    ),
                    "table_data": ParameterProperty(
                        type: "string",
                        description: "For Excel or simple table documents: JSON object with 'headers' (array of column names) and 'rows' (2D array of cell values). Example: {\"headers\":[\"Name\",\"Age\"],\"rows\":[[\"John\",\"30\"],[\"Jane\",\"25\"]]}"
                    )
                ],
                required: ["document_type"]
            )
        )
    )
    
    // MARK: - Send Document to Telegram Chat
    
    static let sendDocumentToChat = ToolDefinition(
        function: FunctionDefinition(
            name: "send_document_to_chat",
            description: "Send a document or file directly to the user via Telegram. Use when the user asks you to send/share a file, document, or image that's in your file management. Works with: PDFs, images, documents downloaded from URLs, email attachments, or any file in your documents folder. You can use list_documents to find the filename before sending.",
            parameters: FunctionParameters(
                properties: [
                    "document_filename": ParameterProperty(
                        type: "string",
                        description: "The filename of the document to send (from list_documents, e.g. 'abc123.pdf'). This is the stored filename."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption to include with the document."
                    )
                ],
                required: ["document_filename"]
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
            description: "Writes a file to the local filesystem.\n\nUsage:\n- This tool will overwrite the existing file if there is one at the provided path.\n- If this is an existing file, you MUST use the read_file tool first to read the file's contents. This tool will fail if you did not read the file first.\n- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.\n- Prefer the edit_file tool for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.\n- Parent directories are created automatically.\n- NEVER create documentation files (*.md) or README files unless explicitly requested by the user.\n- Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.\n- The result includes a 'diff' field (unified-diff preview, capped 50 lines / 4 KB) and a 'diagnostics' array (errors/warnings from sourcekit-lsp / typescript-language-server / pylsp / gopls / rust-analyzer) — inspect both; always re-read and fix before continuing if any diagnostic has severity='error'.",
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
            description: "Performs exact string replacements in files.\n\nUsage:\n- You must use the read_file tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.\n- When editing text from read_file output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: line number + tab. Everything after that is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.\n- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.\n- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.\n- The edit will FAIL if old_string is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use replace_all to change every instance of old_string.\n- Use replace_all for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.\n- The result includes a 'diff' field (unified-diff preview, capped 50 lines / 4 KB) and a 'diagnostics' array — inspect both. Re-read and fix on severity='error'.",
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
            description: "Apply a multi-file Codex-style patch atomically. Use when you need to make coordinated edits across several files in one step. All operations are validated against current file contents before any disk write; on failure, nothing is modified.\n\nEnvelope format:\n*** Begin Patch\n*** Update File: /abs/path\n@@ optional anchor (e.g. a function signature)\n context line\n-removed line\n+added line\n*** Add File: /abs/path\n+new file line 1\n+new file line 2\n*** Delete File: /abs/path\n*** End Patch\n\nFor Update with rename, add '*** Move to: /new/abs/path' directly after the Update File header.\n\nThe result includes 'diffs_by_file' (unified-diff preview per path, capped) and 'diagnostics_by_file' (per-path map with the same 'diagnostics' / 'diagnostics_skipped' / 'diagnostics_summary' shape returned by write_file). Inspect both — re-read and fix any file with severity='error' before continuing.",
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
            description: "A powerful search tool built on ripgrep.\n\nUsage:\n- ALWAYS use grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The grep tool has been optimized for correct permissions, ignore lists, and output shaping — the Bash equivalents bypass all of that.\n- Supports full regex syntax (e.g., \"log.*Error\", \"function\\s+\\w+\").\n- Filter files with the include glob parameter (e.g., \"*.js\", \"**/*.tsx\") or type parameter (e.g., \"js\", \"py\", \"rust\").\n- Output modes: \"content\" shows matching lines (supports -A/-B/-C context), \"files_with_matches\" shows only file paths (use when you only need to know which files contain the pattern — much cheaper), \"count\" shows match counts per file.\n- Pattern syntax: uses ripgrep (not POSIX grep) — literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code).\n- Multiline matching: by default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`.\n- Use the Agent tool for open-ended searches requiring multiple rounds of grep/glob.\n- 100-entry cap, 2000-char-per-line cap, results sorted by mtime descending. Common project ignores (.git, node_modules, DerivedData, etc.) are always applied.",
            parameters: FunctionParameters(
                properties: [
                    "pattern": ParameterProperty(type: "string", description: "Regex pattern to search for (ripgrep/ECMAScript-compatible)."),
                    "path": ParameterProperty(type: "string", description: "Absolute directory path to search under."),
                    "include": ParameterProperty(type: "string", description: "Optional filename glob to filter, e.g. '*.swift' or '*.{ts,tsx}'."),
                    "type": ParameterProperty(type: "string", description: "Optional ripgrep file-type filter (e.g. 'swift', 'ts', 'py', 'rust'). More efficient than include for standard languages. Requires ripgrep. Run `rg --type-list` to see all types."),
                    "output_mode": ParameterProperty(type: "string", description: "Output shape: 'content' (default, returns matching lines), 'files_with_matches' (returns just file paths — use when you only need to know which files contain the pattern), or 'count' (returns match counts per file). Prefer files_with_matches when scanning a large repo; it's much cheaper than reading every matching line."),
                    "case_insensitive": ParameterProperty(type: "boolean", description: "Optional. If true, matches regardless of case (equivalent to ripgrep -i). Default false."),
                    "multiline": ParameterProperty(type: "boolean", description: "Optional. If true, allows regex patterns to span multiple lines (`.` matches newlines). Useful for patterns like 'struct Foo \\{[\\s\\S]*?bar'. Default false."),
                    "-A": ParameterProperty(type: "integer", description: "Optional. Lines of context to show AFTER each match (content mode only). Use when you need to see what follows a match."),
                    "-B": ParameterProperty(type: "integer", description: "Optional. Lines of context to show BEFORE each match (content mode only)."),
                    "-C": ParameterProperty(type: "integer", description: "Optional. Lines of context to show BOTH before and after each match (content mode only). Shorthand for setting -A and -B to the same value."),
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
                    "ignore": ParameterProperty(type: "string", description: "Optional JSON array of additional names to skip, e.g. '[\"tmp\",\"logs\"]'.")
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
            description: "Executes a given shell command via /bin/zsh -lc and returns its output.\n\nThe working directory persists between commands is not supported — use the workdir parameter each call if you need a specific directory. Supports ~ and $VAR expansion.\n\nIMPORTANT: Avoid using this tool to run `find`, `grep`, `rg`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:\n\n - File search: use glob (NOT find or ls)\n - Content search: use grep (NOT grep or rg)\n - Read files: use read_file (NOT cat/head/tail)\n - Edit files: use edit_file (NOT sed/awk)\n - Write files: use write_file (NOT echo >/cat <<EOF)\n - Communication: output text directly (NOT echo/printf)\n\nWhile the bash tool can do similar things, it's better to use the built-in tools as they provide a better experience and make it easier to review tool calls and give permission.\n\nForeground (default): waits for the command to finish, returns stdout/stderr/exit_code. Default 120s timeout, 600s hard max, 30 KB output cap per stream.\n\nBackground (run_in_background=true): returns immediately with a handle like 'bash_1' and the process keeps running. You will be notified automatically when it exits. Use bash_output to peek at live output, bash_kill to stop it. Use background mode for dev servers, long builds, and any command that may exceed the foreground timeout.",
            parameters: FunctionParameters(
                properties: [
                    "command": ParameterProperty(type: "string", description: "The shell command to run."),
                    "timeout_ms": ParameterProperty(type: "integer", description: "Optional foreground timeout in milliseconds (max 600000). Ignored when run_in_background=true."),
                    "workdir": ParameterProperty(type: "string", description: "Optional absolute working directory. Must exist."),
                    "description": ParameterProperty(type: "string", description: "Short 5-10 word description of what the command does (for your own future reference in background mode)."),
                    "run_in_background": ParameterProperty(type: "boolean", description: "Optional. When true, spawn detached and return a handle immediately.")
                ],
                required: ["command"]
            )
        )
    )

    static let bashOutput = ToolDefinition(
        function: FunctionDefinition(
            name: "bash_output",
            description: "Read the current accumulated stdout/stderr of a background bash handle without stopping it. Returns status (running/exited/killed/crashed), exit_code when finished, and bytes-so-far. Use the 'since' byte offset for incremental reads across polls.",
            parameters: FunctionParameters(
                properties: [
                    "handle": ParameterProperty(type: "string", description: "The handle returned by bash(run_in_background=true), e.g. 'bash_1'."),
                    "since": ParameterProperty(type: "integer", description: "Optional byte offset into the stdout stream. Omit or pass 0 for the full accumulated output.")
                ],
                required: ["handle"]
            )
        )
    )

    static let bashWatch = ToolDefinition(
        function: FunctionDefinition(
            name: "bash_watch",
            description: "Subscribe to output from a running background bash process. When a line matching the regex pattern appears on stdout OR stderr, a synthetic [BASH WATCH MATCH] user message is injected into the conversation — the agent wakes up and can react immediately (kill the process, run a fix, notify user, etc.). The watch auto-unsubscribes after `limit` matches or when the process exits. Use for tailing dev servers, catching errors during installs, progress-gated workflows. For simple wait-for-completion, just use `bash` with run_in_background and wait for the completion event.",
            parameters: FunctionParameters(
                properties: [
                    "handle": ParameterProperty(
                        type: "string",
                        description: "The background bash handle returned from an earlier bash call (e.g. 'bash_3'). Process must still be running."
                    ),
                    "pattern": ParameterProperty(
                        type: "string",
                        description: "Regular expression (POSIX/NSRegularExpression syntax) matched against each line of stdout/stderr as it arrives. Case-sensitive by default — prefix with (?i) for case-insensitive. Keep it specific — broad patterns like '.' will flood the conversation and auto-unsubscribe on first match."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of match events to emit before auto-unsubscribing. Default 10. Reasonable range 1-50."
                    )
                ],
                required: ["handle", "pattern"]
            )
        )
    )

    static let bashKill = ToolDefinition(
        function: FunctionDefinition(
            name: "bash_kill",
            description: "Terminate a background bash handle. Sends SIGTERM, then SIGKILL after a short grace period if still running. Use when a background process is no longer needed or is misbehaving.",
            parameters: FunctionParameters(
                properties: [
                    "handle": ParameterProperty(type: "string", description: "The handle to kill, e.g. 'bash_1'.")
                ],
                required: ["handle"]
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
                            required: ["content", "status"]
                        )
                    )
                ],
                required: ["todos"]
            )
        )
    )

    static let lspHover = ToolDefinition(
        function: FunctionDefinition(
            name: "lsp_hover",
            description: "Ask the language server what a symbol is: type signature, docstring, brief description. Position is 1-indexed to match read_file's line numbers. Use when you need to understand code without reading the whole definition.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to the file."),
                    "line": ParameterProperty(type: "integer", description: "1-indexed line number (same numbering as read_file output)."),
                    "column": ParameterProperty(type: "integer", description: "1-indexed column within the line — point at the symbol name.")
                ],
                required: ["path", "line", "column"]
            )
        )
    )

    static let lspDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "lsp_definition",
            description: "Find where a symbol is defined (go-to-definition). Returns a list of locations {path, line, column, end_line, end_column} with 1-indexed positions. Much more accurate than grep because the language server understands scope and imports.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to the file containing the symbol reference."),
                    "line": ParameterProperty(type: "integer", description: "1-indexed line number where the symbol appears."),
                    "column": ParameterProperty(type: "integer", description: "1-indexed column of the symbol.")
                ],
                required: ["path", "line", "column"]
            )
        )
    )

    static let lspReferences = ToolDefinition(
        function: FunctionDefinition(
            name: "lsp_references",
            description: "Find every use of a symbol across the workspace. Returns locations {path, line, column, end_line, end_column} with 1-indexed positions. Prefer over grep for code-symbol search — the language server knows scope and excludes comments/strings/unrelated names.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to a file where the symbol appears."),
                    "line": ParameterProperty(type: "integer", description: "1-indexed line number of the symbol."),
                    "column": ParameterProperty(type: "integer", description: "1-indexed column of the symbol."),
                    "include_declaration": ParameterProperty(type: "boolean", description: "Include the declaration site in results. Default true.")
                ],
                required: ["path", "line", "column"]
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
                            description: "Optional. Pass a session_id from a prior Agent call to resume that subagent's conversation with its full prior context intact. Omit to start a fresh session. Every Agent call returns a session_id in its result — save it if you might want to continue later. Use list_subagent_sessions to see all available sessions."
                        ),
                        "run_in_background": ParameterProperty(
                            type: "string",
                            description: "Pass 'true' to run the subagent in the background and receive a synthetic [SUBAGENT COMPLETE] user message when it finishes. Useful for long-running Explore or Plan tasks so the parent can continue in parallel. Default 'false' (synchronous)."
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

    static let listRunningSubagents = ToolDefinition(
        function: FunctionDefinition(
            name: "list_running_subagents",
            description: "List every subagent currently running in the background (spawned via Agent with run_in_background='true'). Returns a JSON array of {handle, subagent_type, description, started_at, running_seconds}. Use to check what's in flight before cancelling or to confirm a background spawn is still working.",
            parameters: FunctionParameters(properties: [:], required: [])
        )
    )

    static let listSubagentSessions = ToolDefinition(
        function: FunctionDefinition(
            name: "list_subagent_sessions",
            description: "List all subagent sessions from this app run, sorted by most-recently-used first. Each session is resumable by passing its session_id to the Agent tool. Use this to find session IDs for resuming a prior subagent conversation.",
            parameters: FunctionParameters(
                properties: [
                    "limit": ParameterProperty(type: "integer", description: "Max sessions to return. Default 20."),
                    "offset": ParameterProperty(type: "integer", description: "Number of sessions to skip (for pagination). Default 0.")
                ],
                required: []
            )
        )
    )

    static let cancelSubagent = ToolDefinition(
        function: FunctionDefinition(
            name: "cancel_subagent",
            description: "Cancel a running background subagent by handle. Cancellation is best-effort and takes effect at the subagent's next turn boundary — an in-flight tool call finishes first, then the subagent exits and surfaces a truncated [SUBAGENT COMPLETE] message to you. Returns {cancelled: bool, handle, reason?}.",
            parameters: FunctionParameters(
                properties: [
                    "handle": ParameterProperty(type: "string", description: "The handle returned by Agent(run_in_background='true'), e.g. 'subagent_1'.")
                ],
                required: ["handle"]
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

    // MARK: - Tool Arrays

    /// New filesystem tool surface (replaces the sandboxed document tools).
    static var filesystemTools: [ToolDefinition] {
        [readFile, writeFile, editFile, applyPatch, grep, glob, listDir, listRecentFiles, bash, bashOutput, bashKill, bashWatch, todoWrite, lspHover, lspDefinition, lspReferences]
    }

    /// Non-email tools that do not depend on web search credentials.
    ///
    /// As of the gws-CLI migration, Gmail / Calendar / Contacts no longer have
    /// dedicated tools — the agent invokes them via `bash gws …`. Ambient inbox
    /// snapshot + 30-day agenda are still injected into the system prompt via
    /// GoogleWorkspaceService.
    static var coreToolsWithoutWebSearch: [ToolDefinition] {
        return filesystemTools + [manageReminders, viewConversationChunk, generateImage, downloadFromUrl, sendDocumentToChat, shortcuts, agentTool, listRunningSubagents, listSubagentSessions, cancelSubagent, skill]
    }

    /// All available tools. `includeWebSearch` toggles whether the four web tools
    /// are added; email/calendar/contacts tools have been fully removed from the
    /// agent surface in favor of the gws CLI.
    static func all(includeWebSearch: Bool) -> [ToolDefinition] {
        let webTools = includeWebSearch ? [webSearch, webResearchSweep, webFetch, webFetchImage] : []
        return webTools + coreToolsWithoutWebSearch
    }
    
    /// Backward-compatible default: include web search
    static var all: [ToolDefinition] {
        all(includeWebSearch: true)
    }
}
