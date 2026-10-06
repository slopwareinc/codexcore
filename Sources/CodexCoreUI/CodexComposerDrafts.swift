import Foundation
import CodexCore

/// An independent local composer identity, including drafts that have no native thread yet.
public struct CodexComposerDraftID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = "draft:" + UUID().uuidString }

    /// Compatibility identity for hosts that do not supply independent pre-thread drafts.
    public static let unassigned = Self(rawValue: "__codex_unassigned_draft__")

    /// Compatibility identity for an existing native thread. This value is local metadata.
    public static func thread(_ threadID: String) -> Self {
        Self(rawValue: "thread:" + threadID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum CodexComposerDraftStorageError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case exceedsLimit(String)
    case invalidSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported composer draft version \(version)."
        case .exceedsLimit(let field): "Composer drafts exceed the storage limit for \(field)."
        case .invalidSnapshot(let field): "Invalid composer draft data: \(field)."
        }
    }
}

/// Immutable persisted content for one draft. File paths are references; file bytes are never stored.
public struct CodexComposerDraftSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let draftID: CodexComposerDraftID
    public let threadID: String?
    public let workspacePath: String?
    public let projectID: String?
    public let isProjectless: Bool
    public let prompt: String
    private let files: [FileRecord]
    private let annotations: [AnnotationRecord]
    private let skills: [SkillRecord]
    private let mentions: [FuzzyFileSearchResult]

    public var id: CodexComposerDraftID { draftID }
    public var referencedFiles: [CodexReferencedFile] { files.map(\.value) }
    public var responseAnnotations: [CodexResponseTextAnnotation] { annotations.map(\.value) }
    public var attachedSkills: [CodexSlashCommand] { skills.map(\.value) }
    public var selectedMentions: [FuzzyFileSearchResult] { mentions }
    public var isEmpty: Bool {
        prompt.isEmpty && files.isEmpty && annotations.isEmpty && skills.isEmpty && mentions.isEmpty
    }

    public init(
        draftID: CodexComposerDraftID,
        threadID: String? = nil,
        workspacePath: String? = nil,
        projectID: String? = nil,
        isProjectless: Bool = false,
        prompt: String = "",
        referencedFiles: [CodexReferencedFile] = [],
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        attachedSkills: [CodexSlashCommand] = [],
        selectedMentions: [FuzzyFileSearchResult] = []
    ) {
        self.draftID = draftID
        self.threadID = threadID
        self.workspacePath = workspacePath
        self.projectID = projectID
        self.isProjectless = isProjectless
        self.prompt = prompt
        self.files = referencedFiles.map(FileRecord.init)
        self.annotations = responseAnnotations.map(AnnotationRecord.init)
        self.skills = attachedSkills.map(SkillRecord.init)
        self.mentions = selectedMentions
    }

    fileprivate func validate() throws {
        try requireIdentifier(draftID.rawValue, field: "draftID")
        if let threadID { try requireIdentifier(threadID, field: "threadID") }
        if let workspacePath { try requirePath(workspacePath, field: "workspacePath") }
        if let projectID { try requireIdentifier(projectID, field: "projectID") }
        try requireSize(prompt, limit: 256 * 1_024, field: "prompt")
        for (field, count) in [("files", files.count), ("annotations", annotations.count),
                               ("skills", skills.count), ("mentions", mentions.count)] {
            guard count <= 64 else { throw CodexComposerDraftStorageError.exceedsLimit(field) }
        }
        guard Set(files.map(\.path)).count == files.count,
              Set(annotations.map(\.id)).count == annotations.count,
              Set(mentions.map(\.fileName)).count == mentions.count else {
            throw CodexComposerDraftStorageError.invalidSnapshot("duplicate context")
        }
        for file in files {
            try requirePath(file.path, field: "file path")
            try requireSize(file.displayName, limit: 4_096, field: "file name")
            guard CodexReferencedFile.Kind(rawValue: file.kind) != nil else {
                throw CodexComposerDraftStorageError.invalidSnapshot("file kind")
            }
        }
        for annotation in annotations {
            try requireIdentifier(annotation.id, field: "annotation ID")
            try requireIdentifier(annotation.renderItemID, field: "annotation anchor")
            try requireSize(annotation.content.text, limit: 64 * 1_024, field: "annotation text")
            try requireSize(annotation.content.annotation ?? "", limit: 64 * 1_024, field: "annotation comment")
            guard annotation.startOffset >= 0, annotation.endOffset >= annotation.startOffset else {
                throw CodexComposerDraftStorageError.invalidSnapshot("annotation range")
            }
        }
        for skill in skills {
            try requireIdentifier(skill.id, field: "skill ID")
            guard let name = skill.skillName, let path = skill.skillPath else {
                throw CodexComposerDraftStorageError.invalidSnapshot("skill identity")
            }
            try requireIdentifier(name, field: "skill name")
            try requirePath(path, field: "skill path")
            for text in [skill.title, skill.detail, skill.systemImage, skill.section, skill.scopeBadge ?? ""] {
                try requireSize(text, limit: 4_096, field: "skill metadata")
            }
            try requireSize(skill.draftText ?? "", limit: 256 * 1_024, field: "skill draft text")
        }
        for mention in mentions {
            try requireIdentifier(mention.fileName, field: "mention name")
            try requirePath(mention.absolutePath, field: "mention path")
            try requireSize(mention.root, limit: 8_192, field: "mention root")
            try requireSize(mention.path, limit: 8_192, field: "mention relative path")
            guard mention.score.isFinite, (mention.indices?.count ?? 0) <= 4_096,
                  mention.indices?.allSatisfy({ $0 >= 0 }) ?? true else {
                throw CodexComposerDraftStorageError.invalidSnapshot("mention search metadata")
            }
        }
    }

    private struct FileRecord: Codable, Equatable, Sendable {
        let path: String
        let displayName: String
        let kind: String
        init(_ file: CodexReferencedFile) {
            path = file.path; displayName = file.displayName; kind = file.kind.rawValue
        }
        var value: CodexReferencedFile {
            CodexReferencedFile(path: path, displayName: displayName, kind: .init(rawValue: kind) ?? .file)
        }
    }

    private struct AnnotationRecord: Codable, Equatable, Sendable {
        let id: String
        let content: CodexResponseAnnotationContent
        let renderItemID: String
        let startOffset: Int
        let endOffset: Int
        init(_ annotation: CodexResponseTextAnnotation) {
            id = annotation.id; content = annotation.content
            renderItemID = annotation.anchor.renderItemID
            startOffset = annotation.anchor.startOffset; endOffset = annotation.anchor.endOffset
        }
        var value: CodexResponseTextAnnotation {
            CodexResponseTextAnnotation(id: id, text: content.text, annotation: content.annotation,
                anchor: .init(renderItemID: renderItemID, startOffset: startOffset, endOffset: endOffset))
        }
    }

    private struct SkillRecord: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let section: String
        let scopeBadge: String?
        let draftText: String?
        let skillName: String?
        let skillPath: String?
        let requiresEmptyComposer: Bool
        let isEnabled: Bool
        init(_ skill: CodexSlashCommand) {
            id = skill.id; title = skill.title; detail = skill.detail; systemImage = skill.systemImage
            section = skill.section; scopeBadge = skill.scopeBadge; draftText = skill.draftText
            skillName = skill.skillName; skillPath = skill.skillPath
            requiresEmptyComposer = skill.requiresEmptyComposer; isEnabled = skill.isEnabled
        }
        var value: CodexSlashCommand {
            CodexSlashCommand(id: id, title: title, detail: detail, systemImage: systemImage,
                section: section, scopeBadge: scopeBadge, draftText: draftText, skillName: skillName,
                skillPath: skillPath, requiresEmptyComposer: requiresEmptyComposer, isEnabled: isEnabled)
        }
    }
}

/// Validated, versioned persistence boundary. Queues and live search results remain server/runtime state.
public struct CodexComposerDraftsSnapshot: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 4 * 1_024 * 1_024
    public static let maximumDrafts = 128
    public let version: Int
    public let activeDraftID: CodexComposerDraftID
    public let drafts: [CodexComposerDraftSnapshot]

    public init(activeDraftID: CodexComposerDraftID, drafts: [CodexComposerDraftSnapshot]) throws {
        self.version = 1
        self.activeDraftID = activeDraftID
        self.drafts = drafts
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, activeDraftID, drafts }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        activeDraftID = try container.decode(CodexComposerDraftID.self, forKey: .activeDraftID)
        drafts = try container.decode([CodexComposerDraftSnapshot].self, forKey: .drafts)
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw CodexComposerDraftStorageError.unsupportedVersion(version) }
        guard drafts.count <= Self.maximumDrafts else {
            throw CodexComposerDraftStorageError.exceedsLimit("draft count")
        }
        try requireIdentifier(activeDraftID.rawValue, field: "active draftID")
        var ids: Set<CodexComposerDraftID> = []
        var threads: Set<String> = []
        for draft in drafts {
            try draft.validate()
            guard ids.insert(draft.draftID).inserted else {
                throw CodexComposerDraftStorageError.invalidSnapshot("duplicate draftID")
            }
            if let thread = draft.threadID, !threads.insert(thread).inserted {
                throw CodexComposerDraftStorageError.invalidSnapshot("duplicate thread binding")
            }
        }
        guard ids.contains(activeDraftID) else {
            throw CodexComposerDraftStorageError.invalidSnapshot("missing active draft")
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw CodexComposerDraftStorageError.exceedsLimit("encoded bytes")
        }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw CodexComposerDraftStorageError.exceedsLimit("encoded bytes")
        }
        return data
    }
}

/// Explicit host-owned persistence. Constructing a composer session performs no filesystem access.
public protocol CodexComposerDraftStorage: Sendable {
    func load() throws -> CodexComposerDraftsSnapshot?
    func save(_ snapshot: CodexComposerDraftsSnapshot) throws
}

/// An injectable atomic JSON store. The host chooses its URL and when reads/writes occur.
public struct CodexComposerDraftFileStorage: CodexComposerDraftStorage, Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> CodexComposerDraftsSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let maximumRead = CodexComposerDraftsSnapshot.maximumEncodedBytes + 1
        var data = Data()
        while data.count < maximumRead {
            let chunk = try handle.read(upToCount: min(64 * 1_024, maximumRead - data.count)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try CodexComposerDraftsSnapshot.decode(data)
    }

    public func save(_ snapshot: CodexComposerDraftsSnapshot) throws {
        let data = try snapshot.encoded()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private func requireIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw CodexComposerDraftStorageError.invalidSnapshot(field)
    }
    try requireSize(value, limit: 1_024, field: field)
}

private func requirePath(_ value: String, field: String) throws {
    guard value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
        throw CodexComposerDraftStorageError.invalidSnapshot(field)
    }
    try requireSize(value, limit: 8_192, field: field)
}

private func requireSize(_ value: String, limit: Int, field: String) throws {
    guard value.utf8.count <= limit else { throw CodexComposerDraftStorageError.exceedsLimit(field) }
}
