import Foundation

/// Classifies how a message entered the conversation.
/// Used by the Watermark pruner to decide whether a stored user message can be
/// replaced by a compact metadata stub when context pressure demands compression.
///
/// `.userText` is sacred — it represents content the human actually typed and must
/// NEVER be compressed or rewritten.
enum MessageKind: String, Codable {
    case userText         // User actually typed this (default; NEVER compressed)
    case emailArrived     // Email monitor injected
    case subagentComplete // Background subagent finished
    case bashComplete     // Background bash finished (NOT compressed — too small)
    case reminderFired    // Scheduled reminder fired
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    
    // Multiple attachments support (primary storage)
    let imageFileNames: [String]
    let documentFileNames: [String]
    let imageFileSizes: [Int]
    let documentFileSizes: [Int]
    
    // Referenced attachments from replied-to messages (also multiple)
    let referencedImageFileNames: [String]
    let referencedDocumentFileNames: [String]
    let referencedDocumentFileSizes: [Int]
    
    // Files downloaded via tools (email attachments, URL downloads, etc.)
    var downloadedDocumentFileNames: [String]

    // Files the agent modified during this turn (write_file / edit_file / apply_patch on pre-existing files)
    var editedFilePaths: [String]

    // Files the agent newly created during this turn (write_file / apply_patch / image gen etc.)
    var generatedFilePaths: [String]

    // Project workspaces accessed during the turn
    var accessedProjectIds: [String]

    // Tool interactions from the agentic loop (persisted for prompt cache continuity)
    var toolInteractions: [ToolInteraction]

    // Compact tool log — generated at turn end, used as fallback when toolInteractions are pruned
    var compactToolLog: String?

    // Origin classification for synthetic user messages — drives Watermark-time compression.
    // Default `.userText` means the user actually typed this and it must NEVER be compressed.
    var kind: MessageKind

    enum Role: String, Codable {
        case user
        case assistant
    }
    
    // MARK: - Convenience accessors for single-attachment cases
    
    var imageFileName: String? { imageFileNames.first }
    var documentFileName: String? { documentFileNames.first }
    var imageFileSize: Int? { imageFileSizes.first }
    var documentFileSize: Int? { documentFileSizes.first }
    var referencedImageFileName: String? { referencedImageFileNames.first }
    var referencedDocumentFileName: String? { referencedDocumentFileNames.first }
    var referencedDocumentFileSize: Int? { referencedDocumentFileSizes.first }
    
    // MARK: - Initializers
    
    /// Full initializer with array support
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        imageFileNames: [String] = [],
        documentFileNames: [String] = [],
        imageFileSizes: [Int] = [],
        documentFileSizes: [Int] = [],
        referencedImageFileNames: [String] = [],
        referencedDocumentFileNames: [String] = [],
        referencedDocumentFileSizes: [Int] = [],
        downloadedDocumentFileNames: [String] = [],
        editedFilePaths: [String] = [],
        generatedFilePaths: [String] = [],
        accessedProjectIds: [String] = [],
        toolInteractions: [ToolInteraction] = [],
        compactToolLog: String? = nil,
        kind: MessageKind = .userText
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.imageFileNames = imageFileNames
        self.documentFileNames = documentFileNames
        self.imageFileSizes = imageFileSizes
        self.documentFileSizes = documentFileSizes
        self.referencedImageFileNames = referencedImageFileNames
        self.referencedDocumentFileNames = referencedDocumentFileNames
        self.referencedDocumentFileSizes = referencedDocumentFileSizes
        self.downloadedDocumentFileNames = downloadedDocumentFileNames
        self.editedFilePaths = editedFilePaths
        self.generatedFilePaths = generatedFilePaths
        self.accessedProjectIds = accessedProjectIds
        self.toolInteractions = toolInteractions
        self.compactToolLog = compactToolLog
        self.kind = kind
    }
    
    // MARK: - Codable (with backward compatibility)
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        // New array fields
        case imageFileNames, documentFileNames, imageFileSizes, documentFileSizes
        case referencedImageFileNames, referencedDocumentFileNames
        case referencedDocumentFileSizes
        case downloadedDocumentFileNames, editedFilePaths, generatedFilePaths, accessedProjectIds, toolInteractions, compactToolLog, kind
        // Legacy single-value fields (for decoding old data)
        case imageFileName, documentFileName, imageFileSize, documentFileSize
        case referencedImageFileName, referencedDocumentFileName
        case referencedDocumentFileSize
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        
        // Try new array format first, fall back to legacy single-value format
        if let names = try? container.decode([String].self, forKey: .imageFileNames) {
            imageFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .imageFileName) {
            imageFileNames = [name]
        } else {
            imageFileNames = []
        }
        
        if let names = try? container.decode([String].self, forKey: .documentFileNames) {
            documentFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .documentFileName) {
            documentFileNames = [name]
        } else {
            documentFileNames = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .imageFileSizes) {
            imageFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .imageFileSize) {
            imageFileSizes = [size]
        } else {
            imageFileSizes = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .documentFileSizes) {
            documentFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .documentFileSize) {
            documentFileSizes = [size]
        } else {
            documentFileSizes = []
        }
        
        // Referenced attachments
        if let names = try? container.decode([String].self, forKey: .referencedImageFileNames) {
            referencedImageFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .referencedImageFileName) {
            referencedImageFileNames = [name]
        } else {
            referencedImageFileNames = []
        }
        
        if let names = try? container.decode([String].self, forKey: .referencedDocumentFileNames) {
            referencedDocumentFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .referencedDocumentFileName) {
            referencedDocumentFileNames = [name]
        } else {
            referencedDocumentFileNames = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .referencedDocumentFileSizes) {
            referencedDocumentFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .referencedDocumentFileSize) {
            referencedDocumentFileSizes = [size]
        } else {
            referencedDocumentFileSizes = []
        }
        
        // Downloaded files (new field, default to empty for old messages)
        downloadedDocumentFileNames = (try? container.decode([String].self, forKey: .downloadedDocumentFileNames)) ?? []

        // Edited/generated file paths (new fields, default to empty for old messages)
        editedFilePaths = (try? container.decode([String].self, forKey: .editedFilePaths)) ?? []
        generatedFilePaths = (try? container.decode([String].self, forKey: .generatedFilePaths)) ?? []

        // Accessed projects (new field, default to empty for old messages)
        accessedProjectIds = (try? container.decode([String].self, forKey: .accessedProjectIds)) ?? []

        // Tool interactions (new field, default to empty for old messages)
        toolInteractions = (try? container.decode([ToolInteraction].self, forKey: .toolInteractions)) ?? []

        // Compact tool log (new field, default nil for old messages)
        compactToolLog = try? container.decodeIfPresent(String.self, forKey: .compactToolLog)

        // Message kind (new field, default to `.userText` for old stored messages so
        // legacy data is never accidentally treated as compressible).
        kind = (try? container.decodeIfPresent(MessageKind.self, forKey: .kind)) ?? .userText
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        
        // Always encode in new array format
        try container.encode(imageFileNames, forKey: .imageFileNames)
        try container.encode(documentFileNames, forKey: .documentFileNames)
        try container.encode(imageFileSizes, forKey: .imageFileSizes)
        try container.encode(documentFileSizes, forKey: .documentFileSizes)
        try container.encode(referencedImageFileNames, forKey: .referencedImageFileNames)
        try container.encode(referencedDocumentFileNames, forKey: .referencedDocumentFileNames)
        try container.encode(referencedDocumentFileSizes, forKey: .referencedDocumentFileSizes)
        try container.encode(downloadedDocumentFileNames, forKey: .downloadedDocumentFileNames)
        if !editedFilePaths.isEmpty {
            try container.encode(editedFilePaths, forKey: .editedFilePaths)
        }
        if !generatedFilePaths.isEmpty {
            try container.encode(generatedFilePaths, forKey: .generatedFilePaths)
        }
        try container.encode(accessedProjectIds, forKey: .accessedProjectIds)
        if !toolInteractions.isEmpty {
            try container.encode(toolInteractions, forKey: .toolInteractions)
        }
        try container.encodeIfPresent(compactToolLog, forKey: .compactToolLog)
        // Only encode kind when non-default, mirroring the conditional-encode pattern above.
        if kind != .userText {
            try container.encode(kind, forKey: .kind)
        }
    }

    // Manual Equatable — excludes toolInteractions (ToolInteraction is not Equatable)
    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id &&
        lhs.role == rhs.role &&
        lhs.content == rhs.content &&
        lhs.timestamp == rhs.timestamp &&
        lhs.imageFileNames == rhs.imageFileNames &&
        lhs.documentFileNames == rhs.documentFileNames &&
        lhs.imageFileSizes == rhs.imageFileSizes &&
        lhs.documentFileSizes == rhs.documentFileSizes &&
        lhs.referencedImageFileNames == rhs.referencedImageFileNames &&
        lhs.referencedDocumentFileNames == rhs.referencedDocumentFileNames &&
        lhs.referencedDocumentFileSizes == rhs.referencedDocumentFileSizes &&
        lhs.downloadedDocumentFileNames == rhs.downloadedDocumentFileNames &&
        lhs.editedFilePaths == rhs.editedFilePaths &&
        lhs.generatedFilePaths == rhs.generatedFilePaths &&
        lhs.accessedProjectIds == rhs.accessedProjectIds &&
        lhs.kind == rhs.kind
    }
}
