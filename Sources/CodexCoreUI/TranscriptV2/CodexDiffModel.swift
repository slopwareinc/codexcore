import CodexCore
import Foundation

struct CodexDiffFile: Sendable, Equatable {
    var path: String
    var kind: String
    var added: Int
    var removed: Int
    var hunks: [CodexDiffHunk]
    var isBinary: Bool = false
}

struct CodexDiffHunk: Sendable, Equatable {
    var header: String
    var lines: [CodexDiffLine]
}

struct CodexDiffLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case context, add, remove }
    var kind: Kind
    var text: String
}

struct CodexRetainedDiffHeaders: Sendable {
    var diff: String?
    var oldFile: String?
    var newFile: String?
    var renameFrom: String?
    var renameTo: String?
}

struct CodexParsedDiff: Sendable {
    var files: [CodexDiffFile]
    var fileSourceRanges: [Range<String.Index>] = []
    var totalLineCount: Int
    var retainedLineCount: Int
    var retainedUTF8ByteCount: Int
    var rawFingerprint: UInt64 = 0
    var containsBinaryPatch: Bool = false
    var totalFileCount: Int = 0
    var totalAdded: Int = 0
    var totalRemoved: Int = 0
    var didTruncateFileRecords: Bool = false
    var retainedHeaders = CodexRetainedDiffHeaders()

    var isTruncated: Bool { retainedLineCount < totalLineCount || didTruncateFileRecords }
}

/// A zero-copy reference to one file section inside a legacy aggregate patch.
/// The selected section is copied only when the user requests exact patch text.
struct CodexExactPatchSliceV2: @unchecked Sendable {
    private let source: String
    private let range: Range<String.Index>

    init(source: String, range: Range<String.Index>) {
        self.source = source
        self.range = range
    }

    func materialized() -> String { String(source[range]) }
}

struct CodexPreparedFileChangeV2: Sendable {
    var changeID: String
    var path: String
    var previousPath: String?
    var kind: CodexFileChangeKindV2
    var added: Int
    var removed: Int
    var file: CodexDiffFile
    var displayPatch: String
    var displayLines: [CodexDiffLine]
    var exactPatch: CodexExactPatchSliceV2?
    var isBinary: Bool
    var isMalformed: Bool
    var isTruncated: Bool
    var omittedLineCount: Int
    var fingerprint: UInt64
    var retainedUTF8ByteCount: Int
    var retainedLineCount: Int
}

/// Immutable analysis shared by incremental projections. Raw patches remain in
/// `CodexFileChangeV2`; this object retains only byte-bounded display data.
final class CodexPreparedFileChangeSetV2: @unchecked Sendable {
    static let maximumRetainedUTF8Bytes = 256 * 1_024
    static let maximumRetainedLineCount = 4_096
    static let maximumPreparedEntryCount = 512

    let entries: [CodexPreparedFileChangeV2]
    let retainedUTF8ByteCount: Int
    let retainedLineCount: Int
    let totalAdded: Int
    let totalRemoved: Int

    init(
        entries: [CodexPreparedFileChangeV2],
        retainedUTF8ByteCount: Int,
        retainedLineCount: Int,
        totalAdded: Int? = nil,
        totalRemoved: Int? = nil
    ) {
        self.entries = entries
        self.retainedUTF8ByteCount = retainedUTF8ByteCount
        self.retainedLineCount = retainedLineCount
        self.totalAdded = totalAdded ?? entries.reduce(0) { $0 + $1.added }
        self.totalRemoved = totalRemoved ?? entries.reduce(0) { $0 + $1.removed }
    }

    static let empty = CodexPreparedFileChangeSetV2(
        entries: [],
        retainedUTF8ByteCount: 0,
        retainedLineCount: 0,
        totalAdded: 0,
        totalRemoved: 0
    )
}

struct CodexFileChangePreparationKey: Sendable, Equatable {
    var itemKey: ItemKey?
    var sourceRevision: StateRevision?
    var contentFingerprint: UInt64
}
