import Foundation

private enum CodexUTF8LineScanner {
    struct Summary {
        var lineCount: Int
        var rawFingerprint: UInt64
    }

    static func scan(
        _ text: String,
        logicalStart: String.Index? = nil,
        omitTerminalEmptyLine: Bool,
        checkpoint: () throws -> Void = {},
        body: (Substring, Int) -> Void
    ) rethrows -> Summary {
        var hasher = CodexStableFingerprint()
        guard !text.isEmpty else {
            hasher.finishRawField()
            return .init(lineCount: 0, rawFingerprint: hasher.value)
        }

        let utf8 = text.utf8
        let parseStart = logicalStart ?? utf8.startIndex
        var cursor = utf8.startIndex
        var bytesUntilCheckpoint = 64 * 1_024
        while cursor != parseStart {
            hasher.combineRawByte(utf8[cursor])
            cursor = utf8.index(after: cursor)
            bytesUntilCheckpoint -= 1
            if bytesUntilCheckpoint == 0 {
                try checkpoint()
                bytesUntilCheckpoint = 64 * 1_024
            }
        }

        var lineStart = parseStart
        var lineByteCount = 0
        var lineCount = 0
        while cursor != utf8.endIndex {
            let byte = utf8[cursor]
            hasher.combineRawByte(byte)
            let next = utf8.index(after: cursor)
            if byte == 0x0A {
                var line = text[lineStart..<cursor]
                var normalizedByteCount = lineByteCount
                if line.last == "\r" {
                    line = line.dropLast()
                    normalizedByteCount -= 1
                }
                body(line, normalizedByteCount)
                lineCount += 1
                lineStart = next
                lineByteCount = 0
                if lineCount.isMultiple(of: 1_024) { try checkpoint() }
            } else {
                lineByteCount += 1
            }
            cursor = next
            bytesUntilCheckpoint -= 1
            if bytesUntilCheckpoint == 0 {
                try checkpoint()
                bytesUntilCheckpoint = 64 * 1_024
            }
        }
        if lineStart != utf8.endIndex || !omitTerminalEmptyLine {
            body(text[lineStart..<utf8.endIndex], lineByteCount)
            lineCount += 1
        }
        hasher.finishRawField()
        try checkpoint()
        return .init(lineCount: lineCount, rawFingerprint: hasher.value)
    }
}

private struct CodexDiffRetentionBudget {
    let byteLimit: Int
    let lineLimit: Int
    let fileLimit: Int
    private(set) var bytes = 0
    private(set) var lines = 0
    private(set) var files = 0
    private var linesClosed = false
    private var filesClosed = false

    init(bytes: Int, lines: Int, files: Int) {
        byteLimit = max(0, bytes)
        lineLimit = max(0, lines)
        fileLimit = max(0, files)
    }

    mutating func reserveLine(bytes offered: Int) -> Bool {
        guard !linesClosed, lines < lineLimit, reserve(bytes: offered) else {
            linesClosed = true
            return false
        }
        lines += 1
        return true
    }

    mutating func reserveFile(pathBytes: Int) -> Bool {
        guard !filesClosed, files < fileLimit, reserve(bytes: pathBytes) else {
            filesClosed = true
            return false
        }
        files += 1
        return true
    }

    mutating func extendPath(by offered: Int) -> Bool {
        reserve(bytes: max(0, offered))
    }

    private mutating func reserve(bytes offered: Int) -> Bool {
        let count = max(0, offered)
        guard bytes <= byteLimit, count <= byteLimit - bytes else {
            return false
        }
        bytes += count
        return true
    }
}

private struct CodexDiffFileAccumulator {
    var sourceStart: String.Index
    var path: String
    var pathBytes = 0
    var kind: String
    var hunks: [CodexDiffHunk] = []
    var headerLines: [CodexDiffLine] = []
    var currentHeader: String?
    var currentLines: [CodexDiffLine] = []
    var added = 0
    var removed = 0
    var insideHunk = false
    var isBinary = false
    var isMeaningful = false
    var hasPatchSyntax = false
    var retainsRecord = false

    mutating func flushHunk(retainHunks: Bool) {
        guard retainHunks else {
            headerLines.removeAll(keepingCapacity: true)
            currentLines.removeAll(keepingCapacity: true)
            currentHeader = nil
            insideHunk = false
            return
        }
        if insideHunk, let currentHeader {
            hunks.append(.init(header: currentHeader, lines: currentLines))
        } else if insideHunk, !currentLines.isEmpty {
            hunks.append(.init(header: "", lines: currentLines))
        } else if !headerLines.isEmpty {
            hunks.append(.init(header: "", lines: headerLines))
        }
        headerLines = []
        currentHeader = nil
        currentLines = []
        insideHunk = false
    }
}

enum CodexUnifiedDiffParser {
    static let defaultMaximumRetainedUTF8Bytes = 128 * 1_024
    static let defaultMaximumRetainedLineCount = 4_096
    static let defaultMaximumRetainedFileCount = 512

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
            checkpoint: {}
        ).files
    }

    static func parseContentBounded(
        _ content: String,
        path: String,
        kind: String,
        isAddition: Bool,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int,
        maximumRetainedFileCount: Int = 1,
        checkpoint: () throws -> Void = {}
    ) rethrows -> CodexParsedDiff {
        var budget = CodexDiffRetentionBudget(
            bytes: maximumRetainedUTF8Bytes,
            lines: maximumRetainedLineCount,
            files: maximumRetainedFileCount
        )
        let retainsFile = budget.reserveFile(pathBytes: path.utf8.count)
        var retained: [CodexDiffLine] = []
        retained.reserveCapacity(max(0, min(maximumRetainedLineCount, 512)))
        let lineKind: CodexDiffLine.Kind = isAddition ? .add : .remove
        let prefix = isAddition ? "+" : "-"
        let scan = try CodexUTF8LineScanner.scan(
            content,
            omitTerminalEmptyLine: true,
            checkpoint: checkpoint
        ) { line, byteCount in
            guard retainsFile, budget.reserveLine(bytes: byteCount + 1) else {
                return
            }
            var text = prefix
            text.append(contentsOf: line)
            retained.append(.init(kind: lineKind, text: text))
        }
        let count = scan.lineCount
        let files: [CodexDiffFile] = retainsFile ? [.init(
            path: path,
            kind: kind,
            added: isAddition ? count : 0,
            removed: isAddition ? 0 : count,
            hunks: retained.isEmpty ? [] : [.init(header: "", lines: retained)]
        )] : []
        return .init(
            files: files,
            totalLineCount: count,
            retainedLineCount: budget.lines,
            retainedUTF8ByteCount: budget.bytes,
            rawFingerprint: scan.rawFingerprint,
            totalFileCount: 1,
            totalAdded: isAddition ? count : 0,
            totalRemoved: isAddition ? 0 : count,
            didTruncateFileRecords: !retainsFile && maximumRetainedFileCount > 0
        )
    }

    static func parseMetadataBounded(
        _ diff: String,
        maximumRetainedUTF8Bytes: Int = defaultMaximumRetainedUTF8Bytes,
        maximumRetainedFileCount: Int = defaultMaximumRetainedFileCount,
        checkpoint: () throws -> Void = {}
    ) rethrows -> CodexParsedDiff {
        try parseBounded(
            diff,
            maximumRetainedUTF8Bytes: maximumRetainedUTF8Bytes,
            maximumRetainedLineCount: 0,
            maximumRetainedFileCount: maximumRetainedFileCount,
            retainHunks: false,
            synthesizeFallbackRecord: false,
            checkpoint: checkpoint
        )
    }

    static func parseBounded(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int = defaultMaximumRetainedLineCount,
        maximumRetainedFileCount: Int = defaultMaximumRetainedFileCount,
        retainHunks: Bool = true,
        trimOfficialLeadingWhitespace: Bool = false,
        synthesizeFallbackRecord: Bool = true,
        checkpoint: () throws -> Void = {}
    ) rethrows -> CodexParsedDiff {
        guard !diff.isEmpty else {
            var hasher = CodexStableFingerprint()
            hasher.finishRawField()
            return .init(
                files: [],
                totalLineCount: 0,
                retainedLineCount: 0,
                retainedUTF8ByteCount: 0,
                rawFingerprint: hasher.value
            )
        }

        let logicalStart = try officialLogicalStart(
            in: diff,
            enabled: trimOfficialLeadingWhitespace,
            checkpoint: checkpoint
        )
        let defaultKind = fallbackKind ?? "modified"
        var budget = CodexDiffRetentionBudget(
            bytes: maximumRetainedUTF8Bytes,
            lines: maximumRetainedLineCount,
            files: maximumRetainedFileCount
        )
        var state = CodexDiffFileAccumulator(
            sourceStart: logicalStart,
            path: fallbackPath,
            kind: defaultKind
        )
        var files: [CodexDiffFile] = []
        var ranges: [Range<String.Index>] = []
        var totalFiles = 0
        var totalAdded = 0
        var totalRemoved = 0
        var containsBinary = false
        var didTruncateFiles = false
        var headers = CodexRetainedDiffHeaders()

        func cleanPath(
            _ value: Substring,
            stripGitPrefix: Bool
        ) -> Substring? {
            let end = value.firstIndex(of: "\t") ?? value.endIndex
            var path = value[..<end]
            if stripGitPrefix, path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = path.dropFirst(2)
            }
            return path == "/dev/null" || path.isEmpty ? nil : path
        }

        func ensureRecord(path candidate: Substring? = nil) {
            if state.retainsRecord {
                guard let candidate else { return }
                let byteCount = candidate.utf8.count
                guard budget.extendPath(by: byteCount - state.pathBytes) else {
                    didTruncateFiles = true
                    return
                }
                state.path = String(candidate)
                state.pathBytes = max(state.pathBytes, byteCount)
                return
            }
            let byteCount = candidate?.utf8.count ?? fallbackPath.utf8.count
            guard budget.reserveFile(pathBytes: byteCount) else { return }
            state.retainsRecord = true
            state.pathBytes = byteCount
            state.path = candidate.map(String.init) ?? fallbackPath
        }

        func retain(
            _ line: Substring,
            bytes: Int,
            kind: CodexDiffLine.Kind = .context
        ) -> CodexDiffLine? {
            guard state.retainsRecord, retainHunks,
                  budget.reserveLine(bytes: bytes) else {
                return nil
            }
            return .init(kind: kind, text: String(line))
        }

        func retainHeader(
            _ line: Substring,
            bytes: Int,
            kind: CodexDiffLine.Kind = .context
        ) -> String? {
            guard let retained = retain(line, bytes: bytes, kind: kind) else {
                return nil
            }
            state.headerLines.append(retained)
            return retained.text
        }

        func flush(endingAt end: String.Index) {
            state.flushHunk(retainHunks: retainHunks)
            guard state.isMeaningful,
                  synthesizeFallbackRecord || state.hasPatchSyntax else {
                return
            }
            totalFiles += 1
            totalAdded += state.added
            totalRemoved += state.removed
            containsBinary = containsBinary || state.isBinary
            if state.retainsRecord {
                files.append(.init(
                    path: state.path,
                    kind: state.kind,
                    added: state.added,
                    removed: state.removed,
                    hunks: state.hunks,
                    isBinary: state.isBinary
                ))
                ranges.append(state.sourceStart..<end)
            } else if maximumRetainedFileCount > 0 {
                didTruncateFiles = true
            }
        }

        let scan = try CodexUTF8LineScanner.scan(
            diff,
            logicalStart: logicalStart,
            omitTerminalEmptyLine: false,
            checkpoint: checkpoint
        ) { line, byteCount in
            if line.hasPrefix("diff --git "), state.isMeaningful {
                flush(endingAt: line.startIndex)
                state = .init(
                    sourceStart: line.startIndex,
                    path: fallbackPath,
                    kind: defaultKind
                )
            }
            state.isMeaningful = true

            if line.hasPrefix("diff --git ") {
                state.hasPatchSyntax = true
                let separator = line.lastIndex(of: " ")
                let candidate = separator.flatMap {
                    cleanPath(line[line.index(after: $0)...], stripGitPrefix: true)
                }
                ensureRecord(path: candidate)
                if let text = retainHeader(line, bytes: byteCount),
                   headers.diff == nil { headers.diff = text }
            } else if line.hasPrefix("@@") {
                state.hasPatchSyntax = true
                ensureRecord()
                state.flushHunk(retainHunks: retainHunks)
                state.insideHunk = true
                state.currentHeader = retain(line, bytes: byteCount)?.text
            } else if state.insideHunk {
                let kind: CodexDiffLine.Kind = line.hasPrefix("+")
                    ? .add : line.hasPrefix("-") ? .remove : .context
                if kind == .add { state.added += 1 }
                if kind == .remove { state.removed += 1 }
                ensureRecord()
                if let retained = retain(line, bytes: byteCount, kind: kind) {
                    state.currentLines.append(retained)
                }
            } else if line.hasPrefix("new file mode") {
                state.hasPatchSyntax = true
                state.kind = "added"
                ensureRecord()
                _ = retainHeader(line, bytes: byteCount)
            } else if line.hasPrefix("deleted file mode") {
                state.hasPatchSyntax = true
                state.kind = "deleted"
                ensureRecord()
                _ = retainHeader(line, bytes: byteCount)
            } else if line.hasPrefix("rename from ") {
                state.hasPatchSyntax = true
                state.kind = "renamed"
                ensureRecord()
                if let text = retainHeader(line, bytes: byteCount),
                   headers.renameFrom == nil { headers.renameFrom = text }
            } else if line.hasPrefix("rename to ") {
                state.hasPatchSyntax = true
                state.kind = "renamed"
                ensureRecord(path: cleanPath(
                    line.dropFirst("rename to ".count),
                    stripGitPrefix: false
                ))
                if let text = retainHeader(line, bytes: byteCount),
                   headers.renameTo == nil { headers.renameTo = text }
            } else if line.hasPrefix("--- ") {
                state.hasPatchSyntax = true
                ensureRecord()
                if let text = retainHeader(line, bytes: byteCount),
                   headers.oldFile == nil { headers.oldFile = text }
            } else if line.hasPrefix("+++ ") {
                state.hasPatchSyntax = true
                ensureRecord(path: cleanPath(line.dropFirst(4), stripGitPrefix: true))
                if let text = retainHeader(line, bytes: byteCount),
                   headers.newFile == nil { headers.newFile = text }
            } else if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                state.hasPatchSyntax = true
                state.isBinary = true
                ensureRecord()
                _ = retainHeader(line, bytes: byteCount)
            } else {
                let kind: CodexDiffLine.Kind = line.hasPrefix("+")
                    ? .add : line.hasPrefix("-") ? .remove : .context
                guard synthesizeFallbackRecord || state.hasPatchSyntax else {
                    return
                }
                if kind == .add { state.added += 1 }
                if kind == .remove { state.removed += 1 }
                ensureRecord()
                _ = retainHeader(line, bytes: byteCount, kind: kind)
            }
        }
        flush(endingAt: diff.endIndex)
        return .init(
            files: files,
            fileSourceRanges: ranges,
            totalLineCount: scan.lineCount,
            retainedLineCount: budget.lines,
            retainedUTF8ByteCount: budget.bytes,
            rawFingerprint: scan.rawFingerprint,
            containsBinaryPatch: containsBinary,
            totalFileCount: totalFiles,
            totalAdded: totalAdded,
            totalRemoved: totalRemoved,
            didTruncateFileRecords: didTruncateFiles,
            retainedHeaders: headers
        )
    }

    private static func officialLogicalStart(
        in diff: String,
        enabled: Bool,
        checkpoint: () throws -> Void
    ) rethrows -> String.Index {
        guard enabled else { return diff.startIndex }
        var cursor = diff.startIndex
        var count = 0
        while cursor != diff.endIndex,
              diff[cursor].isWhitespace || diff[cursor] == "\u{FEFF}" {
            cursor = diff.index(after: cursor)
            count += 1
            if count.isMultiple(of: 4_096) { try checkpoint() }
        }
        let suffix = diff[cursor...]
        let recognized = suffix.hasPrefix("diff --git ")
            || suffix.hasPrefix("--- ") || suffix.hasPrefix("+++ ")
            || suffix.hasPrefix("@@") || suffix.hasPrefix("rename from ")
            || suffix.hasPrefix("rename to ") || suffix.hasPrefix("new file mode ")
            || suffix.hasPrefix("deleted file mode ")
            || suffix.hasPrefix("GIT binary patch")
            || suffix.hasPrefix("Binary files ")
        return cursor != diff.endIndex && recognized ? cursor : diff.startIndex
    }
}
