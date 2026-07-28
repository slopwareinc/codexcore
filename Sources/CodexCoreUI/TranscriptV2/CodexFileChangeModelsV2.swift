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

/// One file-change work item with either legacy aggregate input or canonical
/// per-file changes.
///
/// Public mutation goes through computed properties so the three compatibility
/// surfaces (`files`, `diff`, and `changes`) cannot recursively trigger each
/// other's observers. Canonical projection supplies its revision key through
/// the internal initializer; client-authored rows do not hash the raw patch a
/// second time merely to manufacture a cache key.
public struct CodexFileChangeRowV2: Identifiable, Sendable, Equatable {
    public var id: String
    private var legacyFiles: [String]
    private var legacyDiff: String?
    private var canonicalChanges: [CodexFileChangeV2]

    public var files: [String] {
        get {
            canonicalChanges.isEmpty
                ? legacyFiles
                : canonicalChanges.map(\.displayPath)
        }
        set {
            guard !canonicalChanges.isEmpty else {
                legacyFiles = newValue
                return
            }
            guard newValue.count == canonicalChanges.count else { return }
            var updated = canonicalChanges
            for index in updated.indices {
                if updated[index].destinationPath == nil {
                    updated[index].path = newValue[index]
                } else {
                    updated[index].destinationPath = newValue[index]
                }
            }
            changes = updated
        }
    }

    public var status: CodexWorkItemStatusV2
    public var durationMs: Int?

    /// Legacy aggregate patch supplied by hosts that construct Transcript V2
    /// directly. Canonical rows retain exact patches in `changes` instead of a
    /// second concatenated copy.
    public var diff: String? {
        get { canonicalChanges.isEmpty ? legacyDiff : nil }
        set {
            guard canonicalChanges.isEmpty else { return }
            legacyDiff = newValue
            refreshPublicPreparation()
        }
    }

    public var changes: [CodexFileChangeV2] {
        get { canonicalChanges }
        set {
            canonicalChanges = newValue
            if !newValue.isEmpty {
                legacyFiles = []
                legacyDiff = nil
            }
            refreshPublicPreparation()
        }
    }

    var preparationKey: CodexFileChangePreparationKey?
    var preparedFileChanges: CodexPreparedFileChangeSetV2

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
        canonicalChanges.isEmpty ? legacyFiles.count : canonicalChanges.count
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
        self.legacyFiles = files
        self.legacyDiff = diff
        self.canonicalChanges = []
        self.status = status
        self.durationMs = durationMs
        self.preparationKey = nil
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
        self.legacyFiles = []
        self.legacyDiff = nil
        self.canonicalChanges = changes
        self.status = status
        self.durationMs = durationMs
        self.preparationKey = nil
        self.preparedFileChanges = CodexFileChangeDiffPreparer().prepare(
            changes: changes,
            legacyDiff: nil
        )
    }

    init(
        id: String,
        changes: [CodexFileChangeV2],
        status: CodexWorkItemStatusV2,
        durationMs: Int?,
        preparationKey: CodexFileChangePreparationKey,
        preparedFileChanges: CodexPreparedFileChangeSetV2
    ) {
        self.id = id
        self.legacyFiles = []
        self.legacyDiff = nil
        self.canonicalChanges = changes
        self.status = status
        self.durationMs = durationMs
        self.preparationKey = preparationKey
        self.preparedFileChanges = preparedFileChanges
    }

    func exactChange(forPreparedChangeID changeID: String) -> CodexFileChangeV2? {
        canonicalChanges.first { $0.id == changeID }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.files == rhs.files
            && lhs.status == rhs.status
            && lhs.durationMs == rhs.durationMs
            && lhs.diff == rhs.diff
            && lhs.changes == rhs.changes
    }

    private mutating func refreshPublicPreparation() {
        preparationKey = nil
        preparedFileChanges = CodexFileChangeDiffPreparer().prepare(
            changes: canonicalChanges,
            legacyDiff: canonicalChanges.isEmpty ? legacyDiff : nil
        )
    }
}
