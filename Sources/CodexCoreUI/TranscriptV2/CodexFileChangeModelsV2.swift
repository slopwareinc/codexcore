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
    var wireFingerprint: UInt64

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
        self.wireFingerprint = 0
    }

    init(
        id: String,
        path: String,
        destinationPath: String? = nil,
        kind: CodexFileChangeKindV2,
        diff: String,
        isMalformed: Bool,
        wireValue: CodexJSONValue?,
        wireFingerprint: UInt64
    ) {
        self.id = id
        self.path = path
        self.destinationPath = destinationPath
        self.kind = kind
        self.diff = diff
        self.isMalformed = isMalformed
        self.wireValue = wireValue
        self.wireFingerprint = wireFingerprint
    }

    public var displayPath: String { destinationPath ?? path }
}

enum CodexFileChangeSourceV2: Sendable, Equatable {
    case legacy(files: [String], diff: String?, fingerprint: UInt64)
    case canonical(
        revision: StateRevision,
        changes: [CodexFileChangeV2],
        fingerprint: UInt64
    )

    var files: [String] {
        switch self {
        case .legacy(let files, _, _):
            files
        case .canonical(_, let changes, _):
            changes.map(\.displayPath)
        }
    }

    var diff: String? {
        guard case .legacy(_, let diff, _) = self else { return nil }
        return diff
    }

    var changes: [CodexFileChangeV2] {
        guard case .canonical(_, let changes, _) = self else { return [] }
        return changes
    }

    var canonicalRevision: StateRevision? {
        guard case .canonical(let revision, _, _) = self else { return nil }
        return revision
    }

    var fileCount: Int {
        switch self {
        case .legacy(let files, _, _): files.count
        case .canonical(_, let changes, _): changes.count
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (
            .legacy(let lhsFiles, _, let lhsFingerprint),
            .legacy(let rhsFiles, _, let rhsFingerprint)
        ):
            lhsFiles.count == rhsFiles.count
                && lhsFingerprint == rhsFingerprint
        case (
            .canonical(_, let lhsChanges, let lhsFingerprint),
            .canonical(_, let rhsChanges, let rhsFingerprint)
        ):
            lhsChanges.count == rhsChanges.count
                && lhsFingerprint == rhsFingerprint
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

    var omittedPreparedFileCount: Int {
        preparedFileChanges.omittedEntryCount
    }

    var preparedSourceFingerprint: UInt64 {
        preparedFileChanges.sourceFingerprint
    }

    public init(
        id: String,
        files: [String],
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil,
        diff: String? = nil
    ) {
        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: [],
            legacyDiff: diff,
            checkpoint: {}
        )
        var sourceHasher = CodexStableFingerprint()
        sourceHasher.combine("legacy-row")
        sourceHasher.combine(UInt64(files.count))
        for file in files { sourceHasher.combine(file) }
        sourceHasher.combine(prepared.sourceFingerprint)
        self.id = id
        self.source = .legacy(
            files: files,
            diff: diff,
            fingerprint: sourceHasher.value
        )
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = prepared
    }

    public init(
        id: String,
        changes: [CodexFileChangeV2],
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil
    ) {
        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: changes,
            legacyDiff: nil,
            checkpoint: {}
        )
        self.id = id
        self.source = .canonical(
            revision: .zero,
            changes: changes,
            fingerprint: prepared.sourceFingerprint
        )
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = prepared
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
            changes: changes,
            fingerprint: preparedFileChanges.sourceFingerprint
        )
        self.status = status
        self.durationMs = durationMs
        self.preparedFileChanges = preparedFileChanges
    }

    var canonicalSourceRevision: StateRevision? {
        source.canonicalRevision
    }

    func exactChange(
        at sourceIndex: Int
    ) -> CodexFileChangeV2? {
        guard changes.indices.contains(sourceIndex) else { return nil }
        return changes[sourceIndex]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.status == rhs.status
            && lhs.durationMs == rhs.durationMs
    }
}
