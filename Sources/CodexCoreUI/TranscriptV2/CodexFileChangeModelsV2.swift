import CodexCore
import Foundation

public enum CodexFileChangeKindV2: Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case unknown(String)
}

public struct CodexFileChangeV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var destinationPath: String?
    public var kind: CodexFileChangeKindV2
    public var diff: String
    var isMalformed: Bool
    var wireValue: CodexJSONValue?

    public init(
        id: String,
        path: String,
        destinationPath: String? = nil,
        kind: CodexFileChangeKindV2,
        diff: String
    ) {
        self.id = id
        self.path = path
        self.destinationPath = destinationPath
        self.kind = kind
        self.diff = diff
        self.isMalformed = false
        self.wireValue = nil
    }

    init(
        id: String,
        path: String,
        destinationPath: String? = nil,
        kind: CodexFileChangeKindV2,
        diff: String,
        isMalformed: Bool,
        wireValue: CodexJSONValue?
    ) {
        self.id = id
        self.path = path
        self.destinationPath = destinationPath
        self.kind = kind
        self.diff = diff
        self.isMalformed = isMalformed
        self.wireValue = wireValue
    }

    public var displayPath: String { destinationPath ?? path }
}

enum CodexFileChangeSourceV2: Sendable, Equatable {
    case legacy(files: [String], diff: String?)
    case canonical(revision: StateRevision, changes: [CodexFileChangeV2])

    var files: [String] {
        switch self {
        case .legacy(let files, _):
            files
        case .canonical(_, let changes):
            changes.map(\.displayPath)
        }
    }

    var diff: String? {
        guard case .legacy(_, let diff) = self else { return nil }
        return diff
    }

    var changes: [CodexFileChangeV2] {
        guard case .canonical(_, let changes) = self else { return [] }
        return changes
    }

    var canonicalRevision: StateRevision? {
        guard case .canonical(let revision, _) = self else { return nil }
        return revision
    }

    var fileCount: Int {
        switch self {
        case .legacy(let files, _): files.count
        case .canonical(_, let changes): changes.count
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.legacy(let lhsFiles, let lhsDiff), .legacy(let rhsFiles, let rhsDiff)):
            lhsFiles == rhsFiles && lhsDiff == rhsDiff
        case (.canonical(_, let lhsChanges), .canonical(_, let rhsChanges)):
            lhsChanges == rhsChanges
        default:
            false
        }
    }
}

/// One immutable file-change source plus its bounded render preparation.
///
/// Replace a row to change its source. Lifecycle fields remain independently
/// mutable and never trigger hidden patch parsing.
public struct CodexFileChangeRowV2: Identifiable, Sendable, Equatable {
    public var id: String
    private let source: CodexFileChangeSourceV2

    public var files: [String] {
        source.files
    }

    public var status: CodexWorkItemStatusV2
    public var durationMs: Int?

    /// Legacy aggregate patch supplied by hosts that construct Transcript V2
    /// directly. Canonical rows retain exact patches in `changes` instead of a
    /// second concatenated copy.
    public var diff: String? {
        source.diff
    }

    public var changes: [CodexFileChangeV2] {
        source.changes
    }

    let preparedFileChanges: CodexPreparedFileChangeSetV2

    var preparedChanges: [CodexPreparedFileChangeV2] {
        preparedFileChanges.entries
    }

    var retainedPreparedUTF8ByteCount: Int {
        preparedFileChanges.retainedUTF8ByteCount
    }

    var hasPreparedDetail: Bool {
        !preparedFileChanges.entries.isEmpty
    }

    var fileCount: Int {
        source.fileCount
    }

    var preparedAddedLineCount: Int {
        preparedFileChanges.totalAdded
    }

    var preparedRemovedLineCount: Int {
        preparedFileChanges.totalRemoved
    }

    public init(
        id: String,
        files: [String],
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil,
        diff: String? = nil
    ) {
        self.id = id
        self.source = .legacy(files: files, diff: diff)
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = CodexFileChangeDiffPreparer().prepare(
            changes: [],
            legacyDiff: diff
        )
    }

    public init(
        id: String,
        changes: [CodexFileChangeV2],
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.source = .canonical(revision: .zero, changes: changes)
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = CodexFileChangeDiffPreparer().prepare(
            changes: changes,
            legacyDiff: nil
        )
    }

    init(
        id: String,
        sourceRevision: StateRevision,
        changes: [CodexFileChangeV2],
        status: CodexWorkItemStatusV2,
        durationMs: Int?,
        preparedFileChanges: CodexPreparedFileChangeSetV2
    ) {
        self.id = id
        self.source = .canonical(
            revision: sourceRevision,
            changes: changes
        )
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = preparedFileChanges
    }

    var canonicalSourceRevision: StateRevision? {
        source.canonicalRevision
    }

    func exactChange(forPreparedChangeID changeID: String) -> CodexFileChangeV2? {
        changes.first { $0.id == changeID }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.status == rhs.status
            && lhs.durationMs == rhs.durationMs
    }
}
