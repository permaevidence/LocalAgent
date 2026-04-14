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

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }

    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
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
            description: "Perform a comprehensive web search with multi-step reasoning. Use when the user asks about current events, recent news, specific facts you're uncertain about, prices, stock quotes, weather, availability, or any topic where fresh real-time information would improve your answer. Do NOT use for general knowledge questions you can answer directly.",
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

    static let deepResearch = ToolDefinition(
        function: FunctionDefinition(
            name: "deep_research",
            description: "Perform deep, comprehensive research with multi-step web search and source triangulation. Use when the user asks for a detailed report, a thorough analysis, a full comparison, or a long-form answer with extensive sourcing.",
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
    
    // MARK: - Calendar Tools
    
    static let manageCalendar = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_calendar",
            description: "Single calendar tool. Use action='view' to list events, action='add' to create events, action='edit' to update events, and action='delete' to remove events.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Calendar action: 'view', 'add', 'edit', or 'delete'.",
                        enumValues: ["view", "add", "edit", "delete"]
                    ),
                    "include_past": ParameterProperty(
                        type: "boolean",
                        description: "Optional for action='view'. If true, include past events."
                    ),
                    "event_id": ParameterProperty(
                        type: "string",
                        description: "Required for actions 'edit' and 'delete'. Event UUID."
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Optional for action='edit'. Event title."
                    ),
                    "datetime": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Optional for action='edit'. Local datetime (e.g., '2026-04-12T15:00:00'). Use the same timezone as the conversation timestamps."
                    ),
                    "notes": ParameterProperty(
                        type: "string",
                        description: "Optional for actions 'add' and 'edit'. Event notes."
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
    
    // MARK: - Email Tools
    
    static let readEmails = ToolDefinition(
        function: FunctionDefinition(
            name: "read_emails",
            description: "Read recent emails from the user's inbox via IMAP. Returns email details including 'messageId' (needed for reply_email), 'from' (sender), 'subject', 'date', and 'bodyPreview'. Use when the user asks about their emails or wants to check messages. If user wants to REPLY to an email, first use this to get the messageId and sender, then call reply_email.",
            parameters: FunctionParameters(
                properties: [
                    "count": ParameterProperty(
                        type: "integer",
                        description: "Number of recent emails to fetch (1-20). Default is 10."
                    )
                ],
                required: []
            )
        )
    )
    
    static let searchEmails = ToolDefinition(
        function: FunctionDefinition(
            name: "search_emails",
            description: "Search emails by keywords, sender, or date range in any folder. Use when: user asks 'find emails about X', 'emails from John', 'emails from last week', 'show sent emails', 'find emails I sent', or wants to search past emails. More powerful than read_emails which only shows recent inbox messages.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "Text to search in email subject and body. Use for keyword searches like 'invoice', 'meeting', 'project update'."
                    ),
                    "from": ParameterProperty(
                        type: "string",
                        description: "Filter by sender. Can be email address (john@example.com) or name (John)."
                    ),
                    "since": ParameterProperty(
                        type: "string",
                        description: "Find emails on or after this date. Format: YYYY-MM-DD (e.g., '2026-01-20')."
                    ),
                    "before": ParameterProperty(
                        type: "string",
                        description: "Find emails before this date. Format: YYYY-MM-DD (e.g., '2026-02-01')."
                    ),
                    "folder": ParameterProperty(
                        type: "string",
                        description: "Email folder to search. Use 'sent' to search sent emails, 'drafts' for drafts, 'trash' for trash, or 'inbox' (default). The tool automatically handles Gmail folder naming conventions.",
                        enumValues: ["inbox", "sent", "drafts", "trash"]
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of results (1-50). Default is 10."
                    )
                ],
                required: []  // All optional, but at least one filter recommended
            )
        )
    )
    
    static let sendEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "send_email",
            description: "Send a NEW email (not a reply). Use this only for composing fresh emails to someone. If the user wants to REPLY to an existing email, use reply_email instead (which maintains proper email threading).",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address (e.g., 'john@example.com')."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject line."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text email body content."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    )
                ],
                required: ["to", "subject", "body"]
            )
        )
    )
    
    static let replyEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "reply_email",
            description: "REPLY to an existing email with proper threading. Use this when the user wants to respond to an email they received. Requires the 'messageId' from read_emails output. The reply will appear in the same email thread as the original message in the recipient's inbox.",
            parameters: FunctionParameters(
                properties: [
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The Message-ID of the email being replied to (from the 'messageId' field in read_emails output, e.g. '<abc123@mail.example.com>')."
                    ),
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address (extract from the 'from' field of the original email)."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject (use 'Re: ' + original subject)."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text reply body content."
                    )
                ],
                required: ["message_id", "to", "subject", "body"]
            )
        )
    )
    
    static let forwardEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "forward_email",
            description: "FORWARD an email to someone else, INCLUDING all attachments. Use this when the user wants to share an email they received with another person. Requires the email's 'id' (UID) from read_emails to forward attachments. The forwarded email will include the original message content AND all original attachments.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Email address to forward the email to."
                    ),
                    "email_uid": ParameterProperty(
                        type: "string",
                        description: "The UID of the email to forward (from the 'id' field in read_emails). Required to forward attachments."
                    ),
                    "original_from": ParameterProperty(
                        type: "string",
                        description: "The original sender (from 'from' field in read_emails)."
                    ),
                    "original_date": ParameterProperty(
                        type: "string",
                        description: "The original email date (from 'date' field in read_emails)."
                    ),
                    "original_subject": ParameterProperty(
                        type: "string",
                        description: "The original email subject (from 'subject' field in read_emails)."
                    ),
                    "original_body": ParameterProperty(
                        type: "string",
                        description: "The original email body content (from 'bodyPreview' field in read_emails)."
                    ),
                    "comment": ParameterProperty(
                        type: "string",
                        description: "Optional comment to add before the forwarded message. Can be empty string if no comment needed."
                    )
                ],
                required: ["to", "email_uid", "original_from", "original_date", "original_subject", "original_body"]
            )
        )
    )
    
    static let getEmailThread = ToolDefinition(
        function: FunctionDefinition(
            name: "get_email_thread",
            description: "Fetch ALL emails in a conversation thread. Use when user wants to see a complete email conversation, understand the full context of a thread, or analyze an email chain. Requires a message_id from any email in the thread (from read_emails output). Returns all emails in the thread sorted chronologically (oldest first).",
            parameters: FunctionParameters(
                properties: [
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The Message-ID of any email in the thread (from 'messageId' field in read_emails output, e.g. '<abc123@mail.example.com>'). The tool will find all related emails."
                    )
                ],
                required: ["message_id"]
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
    
    static let sendEmailWithAttachment = ToolDefinition(
        function: FunctionDefinition(
            name: "send_email_with_attachment",
            description: "Send an email with one or more documents attached. Use when the user wants to email files/documents they previously sent via Telegram. First use list_documents to find the filenames.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject line."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text email body content."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of document filenames to attach (from list_documents). Example: [\"report.pdf\", \"image.jpg\"]. Use list_documents to find available files."
                    )
                ],
                required: ["to", "subject", "body", "document_filenames"]
            )
        )
    )
    
    // MARK: - Email Attachment Download Tool
    
    static let downloadEmailAttachment = ToolDefinition(
        function: FunctionDefinition(
            name: "download_email_attachment",
            description: "Download attachments from an email. Use read_emails first to see available attachments. Two modes: (1) Single attachment: provide email_uid and part_id to download one file. (2) Batch download: provide email_uid and set download_all=true to download ALL attachments at once and save them to the documents folder. Batch mode is more efficient when you need multiple or all attachments.",
            parameters: FunctionParameters(
                properties: [
                    "email_uid": ParameterProperty(
                        type: "string",
                        description: "The UID of the email containing the attachment (from the 'id' field in read_emails output)."
                    ),
                    "part_id": ParameterProperty(
                        type: "string",
                        description: "The MIME part ID of a specific attachment (from the 'partId' field in the attachments array). Required unless download_all is true."
                    ),
                    "download_all": ParameterProperty(
                        type: "boolean",
                        description: "Set to true to download ALL attachments from the email at once. Files are saved to documents folder. More efficient than downloading one at a time."
                    )
                ],
                required: ["email_uid"]
            )
        )
    )
    
    // MARK: - Contact Tools
    
    static let manageContacts = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_contacts",
            description: "Single contacts tool. Prefer action='find' to search by name/email (more token-efficient). Use action='add' to create a contact, action='list' to browse contacts with pagination, and action='delete' to remove one or many contacts.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Contact action: 'find', 'add', 'list', or 'delete'.",
                        enumValues: ["find", "add", "list", "delete"]
                    ),
                    "query": ParameterProperty(
                        type: "string",
                        description: "Required for action='find'. Name or email search query."
                    ),
                    "first_name": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Contact first name."
                    ),
                    "last_name": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact last name."
                    ),
                    "email": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact email."
                    ),
                    "phone": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact phone."
                    ),
                    "organization": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact organization."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Optional for action='list'. Page size (default 40, max 40)."
                    ),
                    "cursor": ParameterProperty(
                        type: "string",
                        description: "Optional for action='list'. Pagination cursor from previous response (next_cursor). Omit on first call."
                    ),
                    "contact_id": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Single contact UUID."
                    ),
                    "contact_ids": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Multiple contact IDs as JSON array string or CSV (e.g. [\"id1\",\"id2\"] or \"id1,id2\")."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
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
            description: "Fetches content from a URL and processes it with an AI model that extracts only the information matching your prompt. Use AFTER web_search or deep_research when you need the content of a specific page. Returns a focused excerpt plus structured image and link arrays. If you want to actually SEE an image from the page, use web_fetch_image with an image URL from the images array. Ideal for: reading articles, documentation, product pages, GitHub READMEs, API references, or any URL from search results where you need targeted information.",
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
    
    // MARK: - Gmail API Tools (2 consolidated tools)
    
    static let gmailReader = ToolDefinition(
        function: FunctionDefinition(
            name: "gmailreader",
            description: "Unified Gmail reading tool. Required field: action. Use action='search' to search/list emails with Gmail query syntax, action='read_message' to read one full message by message_id, action='read_thread' to read an entire thread by thread_id, and action='download_attachment' to download a specific attachment so it becomes visible for analysis. Examples: {action:'search', query:'from:john@example.com has:attachment'}, {action:'read_message', message_id:'...'}, {action:'read_thread', thread_id:'...'}, {action:'download_attachment', message_id:'...', attachment_id:'...', filename:'report.pdf'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required Gmail reader action: 'search', 'read_message', 'read_thread', or 'download_attachment'.",
                        enumValues: ["search", "read_message", "read_thread", "download_attachment"]
                    ),
                    "query": ParameterProperty(
                        type: "string",
                        description: "For action='search'. Gmail search query. Leave empty for recent inbox messages. Examples: 'from:sender@example.com', 'subject:meeting', 'after:2026/01/15', 'is:unread has:attachment'."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "For action='search'. Maximum number of emails to return (1-50). Default is 10."
                    ),
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "For action='read_message' or action='download_attachment'. The Gmail message ID."
                    ),
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "For action='read_thread'. The thread ID from a previous search/read result."
                    ),
                    "attachment_id": ParameterProperty(
                        type: "string",
                        description: "For action='download_attachment'. The attachment_id shown in search/read results."
                    ),
                    "filename": ParameterProperty(
                        type: "string",
                        description: "For action='download_attachment'. The exact attachment filename from search/read results. Required for proper file saving."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    static let gmailComposer = ToolDefinition(
        function: FunctionDefinition(
            name: "gmailcomposer",
            description: "Unified Gmail writing tool. Required field: action. Use action='new' to send a new email, action='reply' to reply in an existing thread, and action='forward' to forward an existing message with its attachments. For new/reply you can also pass cc, bcc, and attachment_filenames from list_documents. Examples: {action:'new', to:'a@example.com', subject:'Hello', body:'...'}, {action:'reply', to:'a@example.com', subject:'Re: Hello', body:'...', thread_id:'...', in_reply_to:'...'}, {action:'forward', to:'b@example.com', message_id:'...', comment:'FYI'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required Gmail composer action: 'new', 'reply', or 'forward'.",
                        enumValues: ["new", "reply", "forward"]
                    ),
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address. Required for all composer actions."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Email subject line. For replies, usually use 'Re: original subject'."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Plain text email body."
                    ),
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "For action='reply'. The thread ID from gmailreader search/read results. Required for proper reply threading."
                    ),
                    "in_reply_to": ParameterProperty(
                        type: "string",
                        description: "For action='reply'. Optional Message-ID header of the message being replied to. Use with thread_id for best threading."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "attachment_filenames": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional JSON array of filenames from list_documents to attach. Example: [\"document.pdf\", \"image.jpg\"]."
                    ),
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "For action='forward'. The Gmail message ID to forward."
                    ),
                    "comment": ParameterProperty(
                        type: "string",
                        description: "For action='forward'. Optional comment to add above the forwarded message."
                    )
                ],
                required: ["action", "to"]
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
            description: "Read a file by absolute path. Text files return up to 2000 lines / 50 KB per call with 1-indexed line numbers prepended in the format '  42→content'. Use offset and limit to page through larger files. IMPORTANT: when passing content back to edit_file as old_string, DO NOT include the line-number prefix — it is display-only, not part of the file. Image files are attached as multimodal content — they become visible to you as a user-role attachment on the next turn (you do NOT see them inside the tool result). For PDFs: small PDFs (≤10 pages) are attached whole. For larger PDFs, the 'pages' parameter is REQUIRED — specify a range like '1-5', '3', or '10-20' (max 20 pages per call); call again with a different range to page through. Use list_recent_files or glob/list_dir to discover paths first.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path (starts with '/' or '~'). Relative paths are rejected."),
                    "offset": ParameterProperty(type: "integer", description: "Optional 1-indexed starting line for text files. Omit to start from line 1."),
                    "limit": ParameterProperty(type: "integer", description: "Optional line limit (default 2000, also capped at 50 KB of output)."),
                    "pages": ParameterProperty(type: "string", description: "PDF only. Page range like '1-5', '3', or '10-20'. Required when the PDF has more than 10 pages. Max 20 pages per call. Ignored for non-PDF files.")
                ],
                required: ["path"]
            )
        )
    )

    static let writeFile = ToolDefinition(
        function: FunctionDefinition(
            name: "write_file",
            description: "Create a new file or overwrite an existing one. If the file exists, you MUST have called read_file on it this session first (freshness check). Parent directories are created automatically. Prefer edit_file for small changes — write_file rewrites the whole file. The result includes a 'diff' field with a unified-diff preview of the change (capped at 50 lines / 4 KB) and a 'diagnostics' array (errors/warnings from sourcekit-lsp / typescript-language-server / pylsp / gopls / rust-analyzer) — inspect both; always re-read and fix before continuing if any diagnostic has severity='error'.",
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
            description: "Surgical find-and-replace on an existing file. old_string must appear EXACTLY ONCE in the file (matching whitespace and indentation) unless replace_all=true. Requires a prior read_file this session. Much cheaper than write_file for targeted changes. The result includes a 'diff' field (unified-diff preview, capped 50 lines / 4 KB) and a 'diagnostics' array — inspect both. Re-read and fix on severity='error'.",
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
            description: "Regex content search over files under a directory. Uses ripgrep when available, otherwise a native Swift scan. 100-match cap, 2000-char-per-line cap, results sorted by mtime descending. Common project ignores (.git, node_modules, DerivedData, etc.) are always applied.",
            parameters: FunctionParameters(
                properties: [
                    "pattern": ParameterProperty(type: "string", description: "Regex pattern to search for (ripgrep/ECMAScript-compatible)."),
                    "path": ParameterProperty(type: "string", description: "Absolute directory path to search under."),
                    "include": ParameterProperty(type: "string", description: "Optional filename glob to filter, e.g. '*.swift' or '*.{ts,tsx}'."),
                    "max_results": ParameterProperty(type: "integer", description: "Optional. Maximum matching lines to return (default 100, hard cap 100).")
                ],
                required: ["pattern", "path"]
            )
        )
    )

    static let glob = ToolDefinition(
        function: FunctionDefinition(
            name: "glob",
            description: "Find files by filename pattern. Supports *, ?, and '**/' for recursive. 100-file cap, sorted by mtime descending. Use instead of bash find.",
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
            description: "Run a shell command via /bin/zsh -lc. Supports ~ and $VAR expansion. Default 120s timeout, 600s hard max, 30 KB output cap per stream.\n\nForeground (default): waits for the command to finish, returns stdout/stderr/exit_code.\n\nBackground (run_in_background=true): returns immediately with a handle like 'bash_1' and the process keeps running. You will be notified automatically when it exits. Use bash_output to peek at live output, bash_kill to stop it. Use background mode for dev servers, long builds, and any command that may exceed the foreground timeout.",
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
                        description: "Complete todo list. Each item: {content: past/present tense noun ('Build the LSP client'), activeForm: imperative while running ('Building the LSP client'), status: 'pending'|'in_progress'|'completed'}. Only one item may be in_progress at a time."
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
    /// on the next tool-list build without a restart.
    static var agentTool: ToolDefinition {
        let subagentNames = SubagentTypes.allNames()
        return ToolDefinition(
            function: FunctionDefinition(
                name: "Agent",
                description: "Launch a new subagent with a fresh, isolated context for focused work. Useful for broad codebase exploration, architectural planning, or focused investigations that would otherwise bloat your own context. The subagent has its own tools and returns only its final message to you. Built-in subagent_type values: 'general-purpose' (full tool access, open-ended tasks), 'Explore' (read-only, fast codebase search with parallel tool calls, cheap model), 'Plan' (read-only, produces an implementation plan without executing). User-defined subagents loaded from ~/LocalAgent/agents/*.md are also accepted. Subagents CANNOT spawn other subagents. Provide a self-contained prompt — the subagent sees none of your conversation history.",
                parameters: FunctionParameters(
                    properties: [
                        "subagent_type": ParameterProperty(
                            type: "string",
                            description: "Which subagent to spawn.",
                            enumValues: subagentNames
                        ),
                        "description": ParameterProperty(
                            type: "string",
                            description: "A short (3-5 word) description of the task. Used for progress display."
                        ),
                        "prompt": ParameterProperty(
                            type: "string",
                            description: "The full task for the subagent. Must be self-contained — include all context the subagent needs, since it sees none of your conversation."
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

    // MARK: - Tool Arrays

    /// IMAP email tools (8 tools - used when email_mode is "imap")
    static var imapEmailTools: [ToolDefinition] {
        [readEmails, searchEmails, sendEmail, replyEmail, forwardEmail, getEmailThread, sendEmailWithAttachment, downloadEmailAttachment]
    }
    
    /// Gmail API tools (2 consolidated tools - used when email_mode is "gmail")
    static var gmailEmailTools: [ToolDefinition] {
        [gmailReader, gmailComposer]
    }
    
    /// New filesystem tool surface (replaces the sandboxed document tools).
    static var filesystemTools: [ToolDefinition] {
        [readFile, writeFile, editFile, applyPatch, grep, glob, listDir, listRecentFiles, bash, bashOutput, bashKill, todoWrite, lspHover, lspDefinition, lspReferences]
    }

    /// Non-email tools that do not depend on web search credentials.
    static var coreToolsWithoutWebSearch: [ToolDefinition] {
        return filesystemTools + [manageReminders, manageCalendar, viewConversationChunk, manageContacts, generateImage, downloadFromUrl, sendDocumentToChat, shortcuts, agentTool, listRunningSubagents, cancelSubagent]
    }

    /// All available tools - dynamically selects email tools and optionally web search
    static func all(includeWebSearch: Bool) -> [ToolDefinition] {
        let emailMode = KeychainHelper.load(key: KeychainHelper.emailModeKey) ?? "imap"
        let emailTools = emailMode == "gmail" ? gmailEmailTools : imapEmailTools
        let webTools = includeWebSearch ? [webSearch, deepResearch, webFetch, webFetchImage] : []
        let coreTools = webTools + coreToolsWithoutWebSearch
        return coreTools + emailTools
    }
    
    /// Backward-compatible default: include web search
    static var all: [ToolDefinition] {
        all(includeWebSearch: true)
    }
}
