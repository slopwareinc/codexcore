import Foundation

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

    static func parseContentBounded(
        _ content: String,
        path: String,
        kind: String,
        isAddition: Bool,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int,
        retainFileRecords: Bool = true
    ) -> CodexParsedDiff {
        let byteLimit = retainFileRecords ? max(0, maximumRetainedUTF8Bytes) : 0
        let lineLimit = retainFileRecords ? max(0, maximumRetainedLineCount) : 0
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
                  retainedBytes + retainedLineBytes <= byteLimit else {
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
        let files: [CodexDiffFile] = retainFileRecords
            ? [.init(
                path: path,
                kind: kind,
                added: isAddition ? count : 0,
                removed: isAddition ? 0 : count,
                hunks: [.init(header: "", lines: retainedLines)]
            )]
            : []
        return .init(
            files: files,
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

    static func parseBounded(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int = defaultMaximumRetainedLineCount,
        retainFileRecords: Bool = true
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
        let byteLimit = retainFileRecords ? max(0, maximumRetainedUTF8Bytes) : 0
        let lineLimit = retainFileRecords ? max(0, maximumRetainedLineCount) : 0
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
        var shouldRetainCurrentFile = retainFileRecords && lineLimit > 0
        var currentFileIsBinary = false
        var containsBinaryPatch = false
        var totalFileCount = 0
        var totalAdded = 0
        var totalRemoved = 0
        var didTruncateFileRecords = false
        var retainedHeaders = CodexRetainedDiffHeaders()
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
        func retainHeaderLine(
            _ line: Substring,
            byteCount: Int,
            lineKind: CodexDiffLine.Kind = .context
        ) -> String? {
            guard let retained = retain(
                line,
                byteCount: byteCount,
                kind: lineKind
            ) else {
                return nil
            }
            headerLines.append(retained)
            return retained.text
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
            } else if retainFileRecords {
                didTruncateFileRecords = true
            }
            currentFileStart = sourceEnd
            path = fallbackPath
            hunks = []
            added = 0
            removed = 0
            kind = fallbackKind ?? "modified"
            hasCurrentFileHeader = false
            shouldRetainCurrentFile = retainFileRecords && !didExhaustRetention
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
                if let text = retainHeaderLine(
                    line,
                    byteCount: lineByteCount
                ) {
                    shouldRetainCurrentFile = true
                    if retainedHeaders.diff == nil {
                        retainedHeaders.diff = text
                    }
                    if let separator = line.lastIndex(of: " "),
                       separator < line.endIndex {
                        let candidateStart = line.index(after: separator)
                        path = cleanPath(line[candidateStart...])
                    }
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
                _ = retainHeaderLine(line, byteCount: lineByteCount)
            } else if line.hasPrefix("deleted file mode") {
                kind = "deleted"
                _ = retainHeaderLine(line, byteCount: lineByteCount)
            } else if line.hasPrefix("rename from ") {
                kind = "renamed"
                if let text = retainHeaderLine(line, byteCount: lineByteCount),
                   retainedHeaders.renameFrom == nil {
                    retainedHeaders.renameFrom = text
                }
            } else if line.hasPrefix("rename to ") {
                kind = "renamed"
                if let text = retainHeaderLine(line, byteCount: lineByteCount),
                   retainedHeaders.renameTo == nil {
                    retainedHeaders.renameTo = text
                }
            } else if line.hasPrefix("--- ") {
                if let text = retainHeaderLine(line, byteCount: lineByteCount),
                   retainedHeaders.oldFile == nil {
                    retainedHeaders.oldFile = text
                }
            } else if line.hasPrefix("+++ ") {
                if let text = retainHeaderLine(line, byteCount: lineByteCount) {
                    if shouldRetainCurrentFile {
                        let candidate = cleanPath(line.dropFirst(4))
                        if candidate != "/dev/null" { path = candidate }
                    }
                    if retainedHeaders.newFile == nil {
                        retainedHeaders.newFile = text
                    }
                }
            } else if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                currentFileIsBinary = true
                containsBinaryPatch = true
                _ = retainHeaderLine(line, byteCount: lineByteCount)
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
                _ = retainHeaderLine(
                    line,
                    byteCount: lineByteCount,
                    lineKind: lineKind
                )
            }
        }
        flushFile(endingAt: diff.endIndex)
        if files.isEmpty, retainFileRecords {
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
            retainedHeaders: retainedHeaders
        )
    }

    private static func cleanPath(_ value: Substring) -> String {
        let end = value.firstIndex(of: "\t") ?? value.endIndex
        let path = value[..<end]
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return String(path)
    }
}
