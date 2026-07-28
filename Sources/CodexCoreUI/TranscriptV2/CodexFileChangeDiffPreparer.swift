import Foundation

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
        entries.reserveCapacity(min(
            changes.count,
            CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        ))
        var exactAdded = 0
        var exactRemoved = 0
        for change in changes {
            let retainsEntry = entries.count
                < CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
            let path = retainsEntry ? change.displayPath : ""
            let parsed = parseSource(
                diff: change.diff,
                path: path,
                kind: change.kind,
                maximumRetainedUTF8Bytes: retainsEntry
                    ? remainingParserBytes
                    : 0,
                maximumRetainedLineCount: retainsEntry
                    ? remainingParserLines
                    : 0,
                retainFileRecords: retainsEntry
            )
            exactAdded += parsed.totalAdded
            exactRemoved += parsed.totalRemoved
            guard retainsEntry else { continue }
            let source = Source(
                id: change.id,
                path: path,
                previousPath: change.destinationPath == nil ? nil : change.path,
                kind: change.kind,
                diff: change.diff,
                isMalformed: change.isMalformed
            )
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
            let suppressesWireHeaders = source.kind == .modified
                || source.kind == .renamed
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
            retainedLineCount: retainedLines,
            totalAdded: exactAdded,
            totalRemoved: exactRemoved
        )
    }

    private static func parseSource(
        diff: String,
        path: String,
        kind: CodexFileChangeKindV2,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int,
        retainFileRecords: Bool
    ) -> CodexParsedDiff {
        switch kind {
        case .added, .deleted:
            CodexUnifiedDiffParser.parseContentBounded(
                diff,
                path: path,
                kind: kind.diffKind,
                isAddition: kind == .added,
                maximumRetainedUTF8Bytes: maximumRetainedUTF8Bytes,
                maximumRetainedLineCount: maximumRetainedLineCount,
                retainFileRecords: retainFileRecords
            )
        case .modified, .renamed, .unknown:
            CodexUnifiedDiffParser.parseBounded(
                diff,
                fallbackPath: path,
                fallbackKind: retainFileRecords ? kind.diffKind : nil,
                maximumRetainedUTF8Bytes: maximumRetainedUTF8Bytes,
                maximumRetainedLineCount: maximumRetainedLineCount,
                retainFileRecords: retainFileRecords
            )
        }
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
        let entryLimit = CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        entries.reserveCapacity(min(parsed.files.count, entryLimit))
        for (index, file) in parsed.files.prefix(entryLimit).enumerated() {
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
            let retained = file.retainedDimensions
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
                retainedUTF8ByteCount: retained.utf8ByteCount
                    + display.retainedUTF8ByteCount,
                retainedLineCount: retained.lineCount
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
                parsed.retainedHeaders.diff
                    ?? "diff --git a/\(source.path) b/\(source.path)",
                parsed.retainedHeaders.oldFile ?? "--- a/\(source.path)",
                parsed.retainedHeaders.newFile ?? "+++ b/\(source.path)",
            ]
        case .renamed:
            let previousPath = source.previousPath ?? source.path
            var lines = [
                parsed.retainedHeaders.diff
                    ?? "diff --git a/\(previousPath) b/\(source.path)",
            ]
            if source.diff.isEmpty {
                lines.append("similarity index 100%")
            }
            lines.append(
                parsed.retainedHeaders.renameFrom
                    ?? "rename from \(previousPath)"
            )
            lines.append(
                parsed.retainedHeaders.renameTo ?? "rename to \(source.path)"
            )
            if !source.diff.isEmpty {
                lines.append(
                    parsed.retainedHeaders.oldFile ?? "--- a/\(previousPath)"
                )
                lines.append(
                    parsed.retainedHeaders.newFile ?? "+++ b/\(source.path)"
                )
            }
            return lines
        case .unknown:
            return []
        }
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

private extension CodexDiffFile {
    var retainedDimensions: (utf8ByteCount: Int, lineCount: Int) {
        var utf8ByteCount = 0
        var lineCount = 0
        for hunk in hunks {
            utf8ByteCount += hunk.header.utf8.count
            if !hunk.header.isEmpty {
                lineCount += 1
            }
            lineCount += hunk.lines.count
            for line in hunk.lines {
                utf8ByteCount += line.text.utf8.count
            }
        }
        return (utf8ByteCount, lineCount)
    }
}
