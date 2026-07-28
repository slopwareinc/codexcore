import Foundation

struct CodexFileChangeDiffPreparer: Sendable {
    typealias Implementation = @Sendable (
        [CodexFileChangeV2],
        String?,
        Int
    ) -> CodexPreparedFileChangeSetV2

    private struct Source {
        var id: String
        var path: String
        var previousPath: String?
        var kind: CodexFileChangeKindV2
        var diff: String
        var isMalformed: Bool
    }

    private let implementation: Implementation?

    init() {
        implementation = nil
    }

    init(implementation: @escaping Implementation) {
        self.implementation = implementation
    }

    func prepare(
        changes: [CodexFileChangeV2],
        legacyDiff: String?,
        maximumRetainedUTF8Bytes: Int = CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes,
        checkpoint: () throws -> Void = {}
    ) rethrows -> CodexPreparedFileChangeSetV2 {
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        if let implementation {
            try checkpoint()
            let result = implementation(changes, legacyDiff, byteLimit)
            try checkpoint()
            return result
        }
        return try Self.prepareProduction(
            changes: changes,
            legacyDiff: legacyDiff,
            byteLimit: byteLimit,
            checkpoint: checkpoint
        )
    }

    private static func prepareProduction(
        changes: [CodexFileChangeV2],
        legacyDiff: String?,
        byteLimit: Int,
        checkpoint: () throws -> Void
    ) rethrows -> CodexPreparedFileChangeSetV2 {
        if changes.isEmpty {
            guard let legacyDiff, !legacyDiff.isEmpty else { return .empty }
            let parsed = try CodexUnifiedDiffParser.parseBounded(
                legacyDiff,
                maximumRetainedUTF8Bytes: min(
                    byteLimit,
                    CodexUnifiedDiffParser.defaultMaximumRetainedUTF8Bytes
                ),
                checkpoint: checkpoint
            )
            return try prepareLegacy(
                legacyDiff: legacyDiff,
                parsed: parsed,
                byteLimit: byteLimit,
                checkpoint: checkpoint
            )
        }

        var entries: [CodexPreparedFileChangeV2] = []
        let entryLimit = CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        entries.reserveCapacity(min(changes.count, entryLimit))
        var remainingBytes = byteLimit
        var remainingLines = CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        var exactAdded = 0
        var exactRemoved = 0
        var sourceHasher = CodexStableFingerprint()
        sourceHasher.combine("canonical")
        sourceHasher.combine(UInt64(changes.count))

        for (sourceIndex, change) in changes.enumerated() {
            try checkpoint()
            let retainsEntry = sourceIndex < entryLimit
            let source = Source(
                id: change.id,
                path: retainsEntry ? change.displayPath : "",
                previousPath: change.destinationPath == nil ? nil : change.path,
                kind: change.kind,
                diff: change.diff,
                isMalformed: change.isMalformed
            )
            let parsed = try parseSource(
                source,
                retainsEntry: retainsEntry,
                checkpoint: checkpoint
            )
            exactAdded += parsed.totalAdded
            exactRemoved += parsed.totalRemoved
            sourceHasher.combine(UInt64(sourceIndex))
            sourceHasher.combine(change.id)
            sourceHasher.combine(change.path)
            sourceHasher.combine(change.destinationPath ?? "")
            sourceHasher.combine(change.kind.stableValue)
            sourceHasher.combine(parsed.rawFingerprint)
            sourceHasher.combine(change.isMalformed ? "malformed" : "valid")
            sourceHasher.combine(change.wireFingerprint)
            guard retainsEntry else { continue }

            let file = consolidate(
                parsed.files,
                path: source.path,
                kind: source.kind.diffKind,
                exactAdded: parsed.totalAdded,
                exactRemoved: parsed.totalRemoved,
                containsBinaryPatch: parsed.containsBinaryPatch
            )
            let display = try boundedPatchLines(
                file: file,
                normalizedHeaderLines: normalizedHeaderLines(
                    for: source,
                    parsed: parsed
                ),
                suppressRecognizedFileHeaders: source.kind == .modified
                    || source.kind == .renamed,
                omittedLineCount: max(
                    0,
                    parsed.totalLineCount - parsed.retainedLineCount
                ),
                maximumRetainedUTF8Bytes: remainingBytes,
                maximumRetainedLineCount: remainingLines,
                checkpoint: checkpoint
            )
            remainingBytes -= display.retainedUTF8ByteCount
            remainingLines -= display.lines.count
            let omittedFiles = max(
                0,
                parsed.totalFileCount - parsed.files.count
            )
            let truncation = parsed.isTruncated
                || display.omittedLineCount > 0
                || omittedFiles > 0
                ? CodexPreparedFileChangeTruncationV2(
                    omittedLineCount: display.omittedLineCount,
                    omittedFileCount: omittedFiles
                )
                : nil
            var entryHasher = CodexStableFingerprint()
            entryHasher.combine(source.id)
            entryHasher.combine(source.path)
            entryHasher.combine(source.previousPath ?? "")
            entryHasher.combine(source.kind.stableValue)
            entryHasher.combine(parsed.rawFingerprint)
            entryHasher.combine(display.fingerprint)
            entryHasher.combine(source.isMalformed ? "malformed" : "valid")
            entries.append(.init(
                sourceIndex: sourceIndex,
                summary: .init(
                    path: source.path,
                    previousPath: source.previousPath,
                    kind: source.kind,
                    added: parsed.totalAdded,
                    removed: parsed.totalRemoved,
                    isBinary: parsed.containsBinaryPatch
                ),
                displayLines: display.lines,
                exactPatch: nil,
                isMalformed: source.isMalformed,
                truncation: truncation,
                fingerprint: entryHasher.value,
                retainedUTF8ByteCount: display.retainedUTF8ByteCount,
                retainedLineCount: display.lines.count
            ))
        }
        return .init(
            entries: entries,
            retainedUTF8ByteCount: byteLimit - remainingBytes,
            retainedLineCount:
                CodexPreparedFileChangeSetV2.maximumRetainedLineCount
                - remainingLines,
            totalAdded: exactAdded,
            totalRemoved: exactRemoved,
            sourceFingerprint: sourceHasher.value,
            omittedEntryCount: changes.count - entries.count
        )
    }

    private static func parseSource(
        _ source: Source,
        retainsEntry: Bool,
        checkpoint: () throws -> Void
    ) rethrows -> CodexParsedDiff {
        let bytes = retainsEntry
            ? CodexUnifiedDiffParser.defaultMaximumRetainedUTF8Bytes
            : 0
        let lines = retainsEntry
            ? CodexUnifiedDiffParser.defaultMaximumRetainedLineCount
            : 0
        let files = retainsEntry
            ? CodexUnifiedDiffParser.defaultMaximumRetainedFileCount
            : 0
        switch source.kind {
        case .added, .deleted:
            return try CodexUnifiedDiffParser.parseContentBounded(
                source.diff,
                path: source.path,
                kind: source.kind.diffKind,
                isAddition: source.kind == .added,
                maximumRetainedUTF8Bytes: bytes,
                maximumRetainedLineCount: lines,
                maximumRetainedFileCount: files,
                checkpoint: checkpoint
            )
        case .modified, .renamed, .unknown:
            return try CodexUnifiedDiffParser.parseBounded(
                source.diff,
                fallbackPath: source.path,
                fallbackKind: source.kind.diffKind,
                maximumRetainedUTF8Bytes: bytes,
                maximumRetainedLineCount: lines,
                maximumRetainedFileCount: files,
                trimOfficialLeadingWhitespace: source.kind == .modified
                    || source.kind == .renamed,
                checkpoint: checkpoint
            )
        }
    }

    private static func prepareLegacy(
        legacyDiff: String,
        parsed: CodexParsedDiff,
        byteLimit: Int,
        checkpoint: () throws -> Void
    ) rethrows -> CodexPreparedFileChangeSetV2 {
        var entries: [CodexPreparedFileChangeV2] = []
        let entryLimit = CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        entries.reserveCapacity(min(parsed.files.count, entryLimit))
        var remainingBytes = byteLimit
        var remainingLines = CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        for (sourceIndex, file) in parsed.files.prefix(entryLimit).enumerated() {
            try checkpoint()
            let display = try boundedPatchLines(
                file: file,
                normalizedHeaderLines: [],
                suppressRecognizedFileHeaders: false,
                omittedLineCount: max(
                    0,
                    parsed.totalLineCount - parsed.retainedLineCount
                ),
                maximumRetainedUTF8Bytes: remainingBytes,
                maximumRetainedLineCount: remainingLines,
                checkpoint: checkpoint
            )
            remainingBytes -= display.retainedUTF8ByteCount
            remainingLines -= display.lines.count
            let id = "legacy:\(sourceIndex)"
            var hasher = CodexStableFingerprint()
            hasher.combine(id)
            hasher.combine(parsed.rawFingerprint)
            hasher.combine(display.fingerprint)
            let sourceRange = parsed.fileSourceRanges.indices.contains(sourceIndex)
                ? parsed.fileSourceRanges[sourceIndex]
                : legacyDiff.startIndex..<legacyDiff.endIndex
            let omittedFiles = max(0, parsed.totalFileCount - parsed.files.count)
            let truncation = parsed.isTruncated
                || display.omittedLineCount > 0
                || omittedFiles > 0
                ? CodexPreparedFileChangeTruncationV2(
                    omittedLineCount: display.omittedLineCount,
                    omittedFileCount: omittedFiles
                )
                : nil
            entries.append(.init(
                sourceIndex: sourceIndex,
                summary: .init(
                    path: file.path,
                    previousPath: nil,
                    kind: .fromDiffKind(file.kind),
                    added: file.added,
                    removed: file.removed,
                    isBinary: file.isBinary
                ),
                displayLines: display.lines,
                exactPatch: .init(source: legacyDiff, range: sourceRange),
                isMalformed: false,
                truncation: truncation,
                fingerprint: hasher.value,
                retainedUTF8ByteCount: display.retainedUTF8ByteCount,
                retainedLineCount: display.lines.count
            ))
        }
        var sourceHasher = CodexStableFingerprint()
        sourceHasher.combine("legacy")
        sourceHasher.combine(parsed.rawFingerprint)
        sourceHasher.combine(UInt64(parsed.totalFileCount))
        return .init(
            entries: entries,
            retainedUTF8ByteCount: byteLimit - remainingBytes,
            retainedLineCount:
                CodexPreparedFileChangeSetV2.maximumRetainedLineCount
                - remainingLines,
            totalAdded: parsed.totalAdded,
            totalRemoved: parsed.totalRemoved,
            sourceFingerprint: sourceHasher.value,
            omittedEntryCount: parsed.totalFileCount - entries.count
        )
    }

    private static func normalizedHeaderLines(
        for source: Source,
        parsed: CodexParsedDiff
    ) -> [String] {
        let count = parsed.totalLineCount
        let range = count == 1 ? "1" : "1,\(count)"
        switch source.kind {
        case .added:
            var lines = [
                "diff --git a/\(source.path) b/\(source.path)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(source.path)",
            ]
            if count > 0 { lines.append("@@ -0,0 +\(range) @@") }
            return lines
        case .deleted:
            var lines = [
                "diff --git a/\(source.path) b/\(source.path)",
                "deleted file mode 100644",
                "--- a/\(source.path)",
                "+++ /dev/null",
            ]
            if count > 0 { lines.append("@@ -\(range) +0,0 @@") }
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
            if source.diff.isEmpty { lines.append("similarity index 100%") }
            lines.append(parsed.retainedHeaders.renameFrom
                ?? "rename from \(previousPath)")
            lines.append(parsed.retainedHeaders.renameTo
                ?? "rename to \(source.path)")
            if !source.diff.isEmpty {
                lines.append(parsed.retainedHeaders.oldFile
                    ?? "--- a/\(previousPath)")
                lines.append(parsed.retainedHeaders.newFile
                    ?? "+++ b/\(source.path)")
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
        .init(
            path: path,
            kind: kind,
            added: exactAdded,
            removed: exactRemoved,
            hunks: files.flatMap(\.hunks),
            isBinary: containsBinaryPatch
        )
    }

    private static func boundedPatchLines(
        file: CodexDiffFile,
        normalizedHeaderLines: [String],
        suppressRecognizedFileHeaders: Bool,
        omittedLineCount: Int,
        maximumRetainedUTF8Bytes: Int,
        maximumRetainedLineCount: Int,
        checkpoint: () throws -> Void
    ) rethrows -> (
        lines: [CodexDiffLine],
        omittedLineCount: Int,
        retainedUTF8ByteCount: Int,
        fingerprint: UInt64
    ) {
        let byteLimit = max(0, maximumRetainedUTF8Bytes)
        let lineLimit = max(0, maximumRetainedLineCount)
        var retained: [CodexDiffLine] = []
        retained.reserveCapacity(min(lineLimit, 512))
        var retainedBytes = 0
        var candidateCount = 0
        var closed = false

        func offer(_ candidate: CodexDiffLine) {
            candidateCount += 1
            let bytes = candidate.text.utf8.count
            guard !closed, retained.count < lineLimit,
                  bytes <= byteLimit - retainedBytes else {
                closed = true
                return
            }
            retained.append(candidate)
            retainedBytes += bytes
        }

        offer(.init(
            kind: .context,
            text: "\(file.path) · +\(file.added) −\(file.removed)"
        ))
        for line in normalizedHeaderLines {
            offer(.init(kind: .context, text: line))
        }
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            if hunkIndex.isMultiple(of: 128) { try checkpoint() }
            let isMetadata = hunk.header.isEmpty
            if !hunk.header.isEmpty {
                offer(.init(kind: .context, text: hunk.header))
            }
            for line in hunk.lines {
                if suppressRecognizedFileHeaders, isMetadata,
                   isRecognizedFileHeaderLine(line.text) {
                    continue
                }
                offer(line)
            }
        }

        var omitted = omittedLineCount + candidateCount - retained.count
        if omitted > 0, lineLimit > 0 {
            while retained.count >= lineLimit, let removed = retained.popLast() {
                retainedBytes -= removed.text.utf8.count
                omitted += 1
            }
            while true {
                let marker = "… \(omitted) more lines"
                let bytes = marker.utf8.count
                if bytes <= byteLimit - retainedBytes {
                    retained.append(.init(kind: .context, text: marker))
                    retainedBytes += bytes
                    break
                }
                guard let removed = retained.popLast() else { break }
                retainedBytes -= removed.text.utf8.count
                omitted += 1
            }
        }
        var fingerprint = CodexStableFingerprint()
        for line in retained {
            fingerprint.combine(
                line.kind == .add
                    ? "add" : line.kind == .remove ? "remove" : "context"
            )
            try fingerprint.combine(line.text, checkpoint: checkpoint)
        }
        return (retained, omitted, retainedBytes, fingerprint.value)
    }

    private static func isRecognizedFileHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ") || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
    }
}
