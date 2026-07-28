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
    var retainedDiffHeader: String?
    var retainedOldFileHeader: String?
    var retainedNewFileHeader: String?
    var retainedRenameFromHeader: String?
    var retainedRenameToHeader: String?

    var isTruncated: Bool {
        retainedLineCount < totalLineCount || didTruncateFileRecords
    }
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

    func materialized() -> String {
        String(source[range])
    }
}

private enum CodexUTF8LineScanner {
    struct Summary {
        var lineCount: Int
        var rawFingerprint: UInt64
    }

    /// Visits logical lines without first allocating an array of slices. The
    /// fingerprint always covers the exact wire bytes, while a CR immediately
    /// before LF is omitted from the normalized line passed to `body`.
    static func scan(
        _ text: String,
        omitTerminalEmptyLine: Bool,
        body: (Substring, Int) -> Void
    ) -> Summary {
        var hasher = CodexStableFingerprint()
        guard !text.isEmpty else {
            hasher.finishRawField()
            return .init(lineCount: 0, rawFingerprint: hasher.value)
        }

        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var cursor = lineStart
        var lineByteCount = 0
        var lineCount = 0

        func visitLine(
            endingAt lineEnd: String.Index,
            byteCount: Int,
            wasTerminated: Bool
        ) {
            var line = text[lineStart..<lineEnd]
            var normalizedByteCount = byteCount
            if wasTerminated, line.last == "\r" {
                line = line.dropLast()
                normalizedByteCount -= 1
            }
            body(line, normalizedByteCount)
            lineCount += 1
        }

        while cursor != utf8.endIndex {
            let byte = utf8[cursor]
            hasher.combineRawByte(byte)
            let next = utf8.index(after: cursor)
            if byte == 0x0A {
                visitLine(
                    endingAt: cursor,
                    byteCount: lineByteCount,
                    wasTerminated: true
                )
                lineStart = next
                lineByteCount = 0
            } else {
                lineByteCount += 1
            }
            cursor = next
        }
        if lineStart != utf8.endIndex || !omitTerminalEmptyLine {
            visitLine(
                endingAt: utf8.endIndex,
                byteCount: lineByteCount,
                wasTerminated: false
            )
        }
        hasher.finishRawField()
        return .init(lineCount: lineCount, rawFingerprint: hasher.value)
    }
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

struct CodexFileChangeDiffPreparer: Sendable {
    private struct Source {
        var id: String
        var path: String
        var previousPath: String?
        var kind: CodexFileChangeKindV2
        var diff: String
        var isMalformed: Bool
    }

    private let implementation: @Sendable (
        [CodexFileChangeV2],
        String?,
        Int
    ) -> CodexPreparedFileChangeSetV2

    init(
        implementation: @escaping @Sendable (
            [CodexFileChangeV2],
            String?,
            Int
        ) -> CodexPreparedFileChangeSetV2 = CodexFileChangeDiffPreparer.prepare
    ) {
        self.implementation = implementation
    }

    func prepare(
        changes: [CodexFileChangeV2],
        legacyDiff: String?,
        maximumRetainedUTF8Bytes: Int = CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
    ) -> CodexPreparedFileChangeSetV2 {
        implementation(changes, legacyDiff, max(0, maximumRetainedUTF8Bytes))
    }

    static func prepare(
        changes: [CodexFileChangeV2],
        legacyDiff: String?,
        maximumRetainedUTF8Bytes: Int
    ) -> CodexPreparedFileChangeSetV2 {
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        let lineLimit = CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        let parserByteLimit = byteLimit / 2
        let parserLineLimit = lineLimit / 2
        let displayByteLimit = byteLimit - parserByteLimit
        let displayLineLimit = lineLimit - parserLineLimit

        if changes.isEmpty {
            guard let legacyDiff, !legacyDiff.isEmpty else { return .empty }
            let parsed = CodexUnifiedDiffParser.parseBounded(
                legacyDiff,
                maximumRetainedUTF8Bytes: parserByteLimit,
                maximumRetainedLineCount: parserLineLimit
            )
            return prepareLegacy(
                legacyDiff: legacyDiff,
                parsed: parsed,
                maximumDisplayUTF8Bytes: displayByteLimit,
                maximumDisplayLineCount: displayLineLimit
            )
        }

        var remainingParserBytes = parserByteLimit
        var remainingParserLines = parserLineLimit
        var remainingDisplayBytes = displayByteLimit
        var remainingDisplayLines = displayLineLimit
        var entries: [CodexPreparedFileChangeV2] = []
        entries.reserveCapacity(changes.count)
        for change in changes {
            let source = Source(
                id: change.id,
                path: change.displayPath,
                previousPath: change.destinationPath == nil ? nil : change.path,
                kind: change.kind,
                diff: change.diff,
                isMalformed: change.isMalformed
            )
            let parsed: CodexParsedDiff
            switch source.kind {
            case .added:
                parsed = parseContent(
                    source.diff,
                    path: source.path,
                    kind: "added",
                    isAddition: true,
                    maximumRetainedUTF8Bytes: remainingParserBytes,
                    maximumRetainedLineCount: remainingParserLines
                )
            case .deleted:
                parsed = parseContent(
                    source.diff,
                    path: source.path,
                    kind: "deleted",
                    isAddition: false,
                    maximumRetainedUTF8Bytes: remainingParserBytes,
                    maximumRetainedLineCount: remainingParserLines
                )
            case .modified, .renamed, .unknown:
                parsed = CodexUnifiedDiffParser.parseBounded(
                    source.diff,
                    fallbackPath: source.path,
                    fallbackKind: source.kind.diffKind,
                    maximumRetainedUTF8Bytes: remainingParserBytes,
                    maximumRetainedLineCount: remainingParserLines
                )
            }
            remainingParserBytes -= parsed.retainedUTF8ByteCount
            remainingParserLines -= parsed.retainedLineCount
            let consolidated = consolidate(
                parsed.files,
                path: source.path,
                kind: source.kind.diffKind,
                exactAdded: parsed.totalAdded,
                exactRemoved: parsed.totalRemoved,
                containsBinaryPatch: parsed.containsBinaryPatch
            )
            let suppressesWireHeaders: Bool = switch source.kind {
            case .modified, .renamed: true
            case .added, .deleted, .unknown: false
            }
            let display = boundedPatchText(
                file: consolidated,
                normalizedHeaderLines: normalizedHeaderLines(
                    for: source,
                    parsed: parsed
                ),
                suppressRecognizedFileHeaders: suppressesWireHeaders,
                omittedLineCount: max(
                    0,
                    parsed.totalLineCount - parsed.retainedLineCount
                ),
                maximumRetainedUTF8Bytes: remainingDisplayBytes,
                maximumRetainedLineCount: remainingDisplayLines
            )
            remainingDisplayBytes -= display.retainedUTF8ByteCount
            remainingDisplayLines -= display.retainedLineCount
            var entryHasher = CodexStableFingerprint()
            entryHasher.combine(source.id)
            entryHasher.combine(source.path)
            entryHasher.combine(source.previousPath ?? "")
            entryHasher.combine(source.kind.stableValue)
            entryHasher.combine(parsed.rawFingerprint)
            entryHasher.combine(display.fingerprint)
            entryHasher.combine(UInt64(display.omittedLineCount))
            entryHasher.combine(display.isTruncated ? "truncated" : "complete")
            entryHasher.combine(source.isMalformed ? "malformed" : "valid")
            let entryFingerprint = entryHasher.value
            entries.append(.init(
                changeID: source.id,
                path: source.path,
                previousPath: source.previousPath,
                kind: source.kind,
                added: consolidated.added,
                removed: consolidated.removed,
                file: consolidated,
                displayPatch: display.text,
                displayLines: display.lines,
                exactPatch: nil,
                isBinary: parsed.containsBinaryPatch,
                isMalformed: source.isMalformed,
                isTruncated: parsed.isTruncated || display.isTruncated,
                omittedLineCount: display.omittedLineCount,
                fingerprint: entryFingerprint,
                retainedUTF8ByteCount: parsed.retainedUTF8ByteCount
                    + display.retainedUTF8ByteCount,
                retainedLineCount: parsed.retainedLineCount
                    + display.retainedLineCount
            ))
        }
        let retainedBytes = parserByteLimit - remainingParserBytes
            + displayByteLimit - remainingDisplayBytes
        let retainedLines = parserLineLimit - remainingParserLines
            + displayLineLimit - remainingDisplayLines
        return .init(
            entries: entries,
            retainedUTF8ByteCount: retainedBytes,
            retainedLineCount: retainedLines
        )
    }

    private static func prepareLegacy(
        legacyDiff: String,
        parsed: CodexParsedDiff,
        maximumDisplayUTF8Bytes: Int,
        maximumDisplayLineCount: Int
    ) -> CodexPreparedFileChangeSetV2 {
        var remainingDisplayBytes = maximumDisplayUTF8Bytes
        var remainingDisplayLines = maximumDisplayLineCount
        var entries: [CodexPreparedFileChangeV2] = []
        entries.reserveCapacity(parsed.files.count)
        for (index, file) in parsed.files.enumerated() {
            let id = "legacy:\(index)"
            let display = boundedPatchText(
                file: file,
                normalizedHeaderLines: [],
                suppressRecognizedFileHeaders: false,
                omittedLineCount: max(
                    0,
                    parsed.totalLineCount - parsed.retainedLineCount
                ),
                maximumRetainedUTF8Bytes: remainingDisplayBytes,
                maximumRetainedLineCount: remainingDisplayLines
            )
            remainingDisplayBytes -= display.retainedUTF8ByteCount
            remainingDisplayLines -= display.retainedLineCount
            var hasher = CodexStableFingerprint()
            hasher.combine(id)
            hasher.combine(parsed.rawFingerprint)
            hasher.combine(display.fingerprint)
            hasher.combine(UInt64(display.omittedLineCount))
            hasher.combine(display.isTruncated ? "truncated" : "complete")
            let fingerprint = hasher.value
            let sourceRange = parsed.fileSourceRanges.indices.contains(index)
                ? parsed.fileSourceRanges[index]
                : legacyDiff.startIndex..<legacyDiff.endIndex
            entries.append(.init(
                changeID: id,
                path: file.path,
                previousPath: nil,
                kind: CodexFileChangeKindV2.fromDiffKind(file.kind),
                added: file.added,
                removed: file.removed,
                file: file,
                displayPatch: display.text,
                displayLines: display.lines,
                exactPatch: .init(source: legacyDiff, range: sourceRange),
                isBinary: file.isBinary,
                isMalformed: false,
                isTruncated: parsed.isTruncated || display.isTruncated,
                omittedLineCount: display.omittedLineCount,
                fingerprint: fingerprint,
                retainedUTF8ByteCount: file.retainedUTF8ByteCount
                    + display.retainedUTF8ByteCount,
                retainedLineCount: file.retainedLineCount
                    + display.retainedLineCount
            ))
        }
        let retainedDisplayBytes = maximumDisplayUTF8Bytes - remainingDisplayBytes
        let retainedDisplayLines = maximumDisplayLineCount - remainingDisplayLines
        return .init(
            entries: entries,
            retainedUTF8ByteCount: parsed.retainedUTF8ByteCount
                + retainedDisplayBytes,
            retainedLineCount: parsed.retainedLineCount
                + retainedDisplayLines,
            totalAdded: parsed.totalAdded,
            totalRemoved: parsed.totalRemoved
        )
    }

    private static func normalizedHeaderLines(
        for source: Source,
        parsed: CodexParsedDiff
    ) -> [String] {
        let contentLineCount = parsed.totalLineCount
        let range = contentLineCount == 1 ? "1" : "1,\(contentLineCount)"
        switch source.kind {
        case .added:
            var lines = [
                "diff --git a/\(source.path) b/\(source.path)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(source.path)",
            ]
            if contentLineCount > 0 {
                lines.append("@@ -0,0 +\(range) @@")
            }
            return lines
        case .deleted:
            var lines = [
                "diff --git a/\(source.path) b/\(source.path)",
                "deleted file mode 100644",
                "--- a/\(source.path)",
                "+++ /dev/null",
            ]
            if contentLineCount > 0 {
                lines.append("@@ -\(range) +0,0 @@")
            }
            return lines
        case .modified:
            return [
                parsed.retainedDiffHeader
                    ?? "diff --git a/\(source.path) b/\(source.path)",
                parsed.retainedOldFileHeader ?? "--- a/\(source.path)",
                parsed.retainedNewFileHeader ?? "+++ b/\(source.path)",
            ]
        case .renamed:
            let previousPath = source.previousPath ?? source.path
            var lines = [
                parsed.retainedDiffHeader
                    ?? "diff --git a/\(previousPath) b/\(source.path)",
            ]
            if source.diff.isEmpty {
                lines.append("similarity index 100%")
            }
            lines.append(
                parsed.retainedRenameFromHeader ?? "rename from \(previousPath)"
            )
            lines.append(
                parsed.retainedRenameToHeader ?? "rename to \(source.path)"
            )
            if !source.diff.isEmpty {
                lines.append(
                    parsed.retainedOldFileHeader ?? "--- a/\(previousPath)"
                )
                lines.append(
                    parsed.retainedNewFileHeader ?? "+++ b/\(source.path)"
                )
            }
            return lines
        case .unknown:
            return []
        }
    }

    private static func parseContent(
        _ content: String,
        path: String,
        kind: String,
        isAddition: Bool,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int
    ) -> CodexParsedDiff {
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        let lineLimit = max(0, maximumRetainedLineCount)
        var retainedLines: [CodexDiffLine] = []
        var retainedBytes = 0
        var didExhaustRetention = false
        retainedLines.reserveCapacity(min(lineLimit, 512))
        let prefix: Character = isAddition ? "+" : "-"
        let scan = CodexUTF8LineScanner.scan(
            content,
            omitTerminalEmptyLine: true
        ) { rawLine, rawLineByteCount in
            let retainedLineBytes = rawLineByteCount + 1
            guard !didExhaustRetention,
                  retainedLines.count < lineLimit,
                  retainedBytes + retainedLineBytes
                    <= byteLimit else {
                didExhaustRetention = true
                return
            }
            var text = String(prefix)
            text.append(contentsOf: rawLine)
            retainedLines.append(.init(
                kind: isAddition ? .add : .remove,
                text: text
            ))
            retainedBytes += retainedLineBytes
        }
        let count = scan.lineCount
        let file = CodexDiffFile(
            path: path,
            kind: kind,
            added: isAddition ? count : 0,
            removed: isAddition ? 0 : count,
            hunks: [.init(header: "", lines: retainedLines)]
        )
        return .init(
            files: [file],
            totalLineCount: count,
            retainedLineCount: retainedLines.count,
            retainedUTF8ByteCount: retainedBytes,
            rawFingerprint: scan.rawFingerprint,
            containsBinaryPatch: false,
            totalFileCount: 1,
            totalAdded: isAddition ? count : 0,
            totalRemoved: isAddition ? 0 : count
        )
    }

    private static func consolidate(
        _ files: [CodexDiffFile],
        path: String,
        kind: String,
        exactAdded: Int,
        exactRemoved: Int,
        containsBinaryPatch: Bool
    ) -> CodexDiffFile {
        guard !files.isEmpty else {
            return .init(
                path: path,
                kind: kind,
                added: exactAdded,
                removed: exactRemoved,
                hunks: [],
                isBinary: containsBinaryPatch
            )
        }
        var hunks: [CodexDiffHunk] = []
        for file in files {
            hunks.append(contentsOf: file.hunks)
        }
        return .init(
            path: path,
            kind: kind,
            added: exactAdded,
            removed: exactRemoved,
            hunks: hunks,
            isBinary: containsBinaryPatch
        )
    }

    private static func boundedPatchText(
        file: CodexDiffFile,
        normalizedHeaderLines: [String],
        suppressRecognizedFileHeaders: Bool,
        omittedLineCount: Int,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int
    ) -> (
        text: String,
        lines: [CodexDiffLine],
        isTruncated: Bool,
        omittedLineCount: Int,
        retainedUTF8ByteCount: Int,
        retainedLineCount: Int,
        fingerprint: UInt64
    ) {
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        let lineLimit = max(0, maximumRetainedLineCount)
        var retained: [CodexDiffLine] = []
        retained.reserveCapacity(min(lineLimit, 512))
        var retainedBytes = 0
        var candidateCount = 0
        var didExhaustRetention = false

        func storageCost(for text: String, isFirst: Bool) -> Int? {
            let separatorBytes = isFirst ? 0 : 1
            let remainingAfterSeparator = byteLimit - retainedBytes
                - separatorBytes
            guard remainingAfterSeparator >= 0 else { return nil }
            let textByteCount = text.utf8.count
            guard textByteCount <= remainingAfterSeparator / 2 else {
                return nil
            }
            return textByteCount * 2 + separatorBytes
        }
        func offer(_ candidate: CodexDiffLine) {
            candidateCount += 1
            guard !didExhaustRetention,
                  retained.count < lineLimit,
                  let cost = storageCost(
                      for: candidate.text,
                      isFirst: retained.isEmpty
                  ) else {
                didExhaustRetention = true
                return
            }
            retained.append(candidate)
            retainedBytes += cost
        }

        offer(.init(
            kind: .context,
            text: "\(file.path) · +\(file.added) −\(file.removed)"
        ))
        for line in normalizedHeaderLines {
            offer(.init(kind: .context, text: line))
        }
        for hunk in file.hunks {
            let isFileMetadataHunk = hunk.header.isEmpty
            if !hunk.header.isEmpty {
                offer(.init(kind: .context, text: hunk.header))
            }
            for line in hunk.lines {
                if suppressRecognizedFileHeaders,
                   isFileMetadataHunk,
                   isRecognizedFileHeaderLine(line.text) {
                    continue
                }
                offer(line)
            }
        }

        var totalOmitted = omittedLineCount + candidateCount - retained.count
        if totalOmitted > 0, lineLimit > 0 {
            while retained.count >= lineLimit, let removed = retained.popLast() {
                let removedCost = removed.text.utf8.count * 2
                    + (retained.isEmpty ? 0 : 1)
                retainedBytes -= removedCost
                totalOmitted += 1
            }
            while true {
                let marker = "… \(totalOmitted) more lines"
                if let cost = storageCost(
                    for: marker,
                    isFirst: retained.isEmpty
                ) {
                    retained.append(.init(kind: .context, text: marker))
                    retainedBytes += cost
                    break
                }
                guard let removed = retained.popLast() else { break }
                let removedCost = removed.text.utf8.count * 2
                    + (retained.isEmpty ? 0 : 1)
                retainedBytes -= removedCost
                totalOmitted += 1
            }
        }

        var text = ""
        text.reserveCapacity(min(byteLimit, retainedBytes))
        for index in retained.indices {
            if index != retained.startIndex {
                text.append("\n")
            }
            text.append(contentsOf: retained[index].text)
        }
        var fingerprint = CodexStableFingerprint()
        fingerprint.combine(text)
        return (
            text,
            retained,
            totalOmitted > 0,
            totalOmitted,
            retainedBytes,
            retained.count,
            fingerprint.value
        )
    }

    private static func isRecognizedFileHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("diff --git ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
    }
}

enum CodexUnifiedDiffParser {
    static let defaultMaximumRetainedUTF8Bytes = 128 * 1_024
    static let defaultMaximumRetainedLineCount = 4_096

    static func parse(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil
    ) -> [CodexDiffFile] {
        parseBounded(
            diff,
            fallbackPath: fallbackPath,
            fallbackKind: fallbackKind,
            maximumRetainedUTF8Bytes: defaultMaximumRetainedUTF8Bytes,
            maximumRetainedLineCount: defaultMaximumRetainedLineCount
        ).files
    }

    static func parseBounded(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int = defaultMaximumRetainedLineCount
    ) -> CodexParsedDiff {
        guard !diff.isEmpty else {
            var hasher = CodexStableFingerprint()
            hasher.finishRawField()
            return .init(
                files: [],
                totalLineCount: 0,
                retainedLineCount: 0,
                retainedUTF8ByteCount: 0,
                rawFingerprint: hasher.value,
                containsBinaryPatch: false
            )
        }
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        let lineLimit = max(0, maximumRetainedLineCount)
        var files: [CodexDiffFile] = []
        var fileSourceRanges: [Range<String.Index>] = []
        var currentFileStart = diff.startIndex
        var path = fallbackPath
        var kind = fallbackKind ?? "modified"
        var hunks: [CodexDiffHunk] = []
        var headerLines: [CodexDiffLine] = []
        var insideHunk = false
        var currentHeader: String?
        var currentLines: [CodexDiffLine] = []
        var added = 0
        var removed = 0
        var hasCurrentFileHeader = false
        var shouldRetainCurrentFile = lineLimit > 0
        var currentFileIsBinary = false
        var containsBinaryPatch = false
        var totalFileCount = 0
        var totalAdded = 0
        var totalRemoved = 0
        var didTruncateFileRecords = false
        var retainedDiffHeader: String?
        var retainedOldFileHeader: String?
        var retainedNewFileHeader: String?
        var retainedRenameFromHeader: String?
        var retainedRenameToHeader: String?
        var retainedBytes = 0
        var retainedLineCount = 0
        var didExhaustRetention = false

        func retainText(_ line: Substring, byteCount: Int) -> String? {
            guard !didExhaustRetention,
                  retainedLineCount < lineLimit,
                  retainedBytes + byteCount <= byteLimit else {
                didExhaustRetention = true
                return nil
            }
            retainedBytes += byteCount
            retainedLineCount += 1
            return String(line)
        }
        func retain(
            _ line: Substring,
            byteCount: Int,
            kind: CodexDiffLine.Kind
        ) -> CodexDiffLine? {
            guard let text = retainText(line, byteCount: byteCount) else {
                return nil
            }
            return .init(kind: kind, text: text)
        }
        func flushHunk() {
            if insideHunk {
                if let currentHeader {
                    hunks.append(.init(header: currentHeader, lines: currentLines))
                } else if !currentLines.isEmpty {
                    hunks.append(.init(header: "", lines: currentLines))
                }
            } else if !headerLines.isEmpty {
                hunks.append(.init(header: "", lines: headerLines))
            }
            insideHunk = false
            currentHeader = nil
            currentLines = []
            headerLines = []
        }
        func flushFile(endingAt sourceEnd: String.Index) {
            flushHunk()
            guard hasCurrentFileHeader
                || !hunks.isEmpty
                || added > 0
                || removed > 0
                || currentFileIsBinary else {
                currentFileStart = sourceEnd
                return
            }
            totalFileCount += 1
            totalAdded += added
            totalRemoved += removed
            if shouldRetainCurrentFile {
                files.append(.init(
                    path: path,
                    kind: kind,
                    added: added,
                    removed: removed,
                    hunks: hunks,
                    isBinary: currentFileIsBinary
                ))
                fileSourceRanges.append(currentFileStart..<sourceEnd)
            } else {
                didTruncateFileRecords = true
            }
            currentFileStart = sourceEnd
            path = fallbackPath
            hunks = []
            added = 0
            removed = 0
            kind = fallbackKind ?? "modified"
            hasCurrentFileHeader = false
            shouldRetainCurrentFile = !didExhaustRetention
            currentFileIsBinary = false
        }

        let scan = CodexUTF8LineScanner.scan(
            diff,
            omitTerminalEmptyLine: false
        ) { line, lineByteCount in
            if line.hasPrefix("diff --git ") {
                flushFile(endingAt: line.startIndex)
                currentFileStart = line.startIndex
                hasCurrentFileHeader = true
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    shouldRetainCurrentFile = true
                    if retainedDiffHeader == nil {
                        retainedDiffHeader = retained.text
                    }
                    if let separator = line.lastIndex(of: " "),
                       separator < line.endIndex {
                        let candidateStart = line.index(after: separator)
                        path = cleanPath(line[candidateStart...])
                    }
                    headerLines.append(retained)
                } else {
                    shouldRetainCurrentFile = false
                }
            } else if line.hasPrefix("@@") {
                flushHunk()
                insideHunk = true
                currentHeader = retainText(line, byteCount: lineByteCount)
            } else if insideHunk {
                let lineKind: CodexDiffLine.Kind
                if line.hasPrefix("+") {
                    lineKind = .add
                    added += 1
                } else if line.hasPrefix("-") {
                    lineKind = .remove
                    removed += 1
                } else {
                    lineKind = .context
                }
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: lineKind
                ) {
                    currentLines.append(retained)
                }
            } else if line.hasPrefix("new file mode") {
                kind = "added"
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    headerLines.append(retained)
                }
            } else if line.hasPrefix("deleted file mode") {
                kind = "deleted"
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    headerLines.append(retained)
                }
            } else if line.hasPrefix("rename from ") {
                kind = "renamed"
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    if retainedRenameFromHeader == nil {
                        retainedRenameFromHeader = retained.text
                    }
                    headerLines.append(retained)
                }
            } else if line.hasPrefix("rename to ") {
                kind = "renamed"
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    if retainedRenameToHeader == nil {
                        retainedRenameToHeader = retained.text
                    }
                    headerLines.append(retained)
                }
            } else if line.hasPrefix("--- ") {
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    if retainedOldFileHeader == nil {
                        retainedOldFileHeader = retained.text
                    }
                    headerLines.append(retained)
                }
            } else if line.hasPrefix("+++ ") {
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    if shouldRetainCurrentFile {
                        let candidate = cleanPath(line.dropFirst(4))
                        if candidate != "/dev/null" { path = candidate }
                    }
                    if retainedNewFileHeader == nil {
                        retainedNewFileHeader = retained.text
                    }
                    headerLines.append(retained)
                }
            } else if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                currentFileIsBinary = true
                containsBinaryPatch = true
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: .context
                ) {
                    headerLines.append(retained)
                }
            } else {
                let lineKind: CodexDiffLine.Kind
                if line.hasPrefix("+") {
                    lineKind = .add
                    added += 1
                } else if line.hasPrefix("-") {
                    lineKind = .remove
                    removed += 1
                } else {
                    lineKind = .context
                }
                if let retained = retain(
                    line,
                    byteCount: lineByteCount,
                    kind: lineKind
                ) {
                    headerLines.append(retained)
                }
            }
        }
        flushFile(endingAt: diff.endIndex)
        if files.isEmpty {
            files = [.init(
                path: fallbackPath,
                kind: fallbackKind ?? "unknown",
                added: totalAdded,
                removed: totalRemoved,
                hunks: [],
                isBinary: containsBinaryPatch
            )]
            fileSourceRanges = [diff.startIndex..<diff.endIndex]
            if totalFileCount == 0 {
                totalFileCount = 1
            } else {
                didTruncateFileRecords = true
            }
        }
        return .init(
            files: files,
            fileSourceRanges: fileSourceRanges,
            totalLineCount: scan.lineCount,
            retainedLineCount: retainedLineCount,
            retainedUTF8ByteCount: retainedBytes,
            rawFingerprint: scan.rawFingerprint,
            containsBinaryPatch: containsBinaryPatch,
            totalFileCount: totalFileCount,
            totalAdded: totalAdded,
            totalRemoved: totalRemoved,
            didTruncateFileRecords: didTruncateFileRecords,
            retainedDiffHeader: retainedDiffHeader,
            retainedOldFileHeader: retainedOldFileHeader,
            retainedNewFileHeader: retainedNewFileHeader,
            retainedRenameFromHeader: retainedRenameFromHeader,
            retainedRenameToHeader: retainedRenameToHeader
        )
    }

    private static func cleanPath(_ value: Substring) -> String {
        let end = value.firstIndex(of: "\t") ?? value.endIndex
        let path = value[..<end]
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return String(path)
    }
}

struct CodexStableFingerprint: Sendable {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combineRawByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }

    mutating func finishRawField() {
        combineSeparator()
    }

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combineRawByte(byte)
        }
        combineSeparator()
    }

    mutating func combine(_ number: UInt64) {
        var littleEndian = number.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes {
                combineRawByte(byte)
            }
        }
        combineSeparator()
    }

    private mutating func combineSeparator() {
        value ^= 0xFF
        value &*= 1_099_511_628_211
    }
}

extension CodexFileChangeKindV2 {
    var diffKind: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .unknown(let value): value
        }
    }

    var stableValue: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .unknown(let value): "unknown:\(value)"
        }
    }

    static func fromDiffKind(_ value: String) -> Self {
        switch value {
        case "added": .added
        case "modified": .modified
        case "deleted": .deleted
        case "renamed": .renamed
        default: .unknown(value)
        }
    }
}

private extension CodexDiffFile {
    var retainedUTF8ByteCount: Int {
        var result = 0
        for hunk in hunks {
            result += hunk.header.utf8.count
            for line in hunk.lines {
                result += line.text.utf8.count
            }
        }
        return result
    }

    var retainedLineCount: Int {
        var result = 0
        for hunk in hunks {
            if !hunk.header.isEmpty {
                result += 1
            }
            result += hunk.lines.count
        }
        return result
    }
}
