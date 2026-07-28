import CodexCore
import Foundation

struct CodexDiffFile: Sendable, Equatable {
    var path: String
    var kind: String
    var added: Int
    var removed: Int
    var hunks: [CodexDiffHunk]
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
    var totalLineCount: Int
    var retainedLineCount: Int
    var retainedUTF8ByteCount: Int

    var isTruncated: Bool { retainedLineCount < totalLineCount }
}

/// A logical, exact normalized patch. The enum keeps the wire `String` as
/// copy-on-write storage and only materializes synthetic add/delete headers
/// when an explicit consumer asks for the complete patch.
enum CodexNormalizedFilePatchV2: Sendable {
    case added(path: String, content: String)
    case deleted(path: String, content: String)
    case update(sourcePath: String, destinationPath: String, diff: String, hasFileHeader: Bool)
    case rename(sourcePath: String, destinationPath: String, diff: String)
    case unknown(path: String, diff: String)

    func materialized() -> String {
        switch self {
        case .added(let path, let content):
            return Self.contentPatch(path: path, content: content, isAddition: true)
        case .deleted(let path, let content):
            return Self.contentPatch(path: path, content: content, isAddition: false)
        case .update(let source, let destination, let diff, let hasFileHeader):
            guard !hasFileHeader else { return diff }
            let header = [
                "diff --git a/\(source) b/\(destination)",
                "--- a/\(source)",
                "+++ b/\(destination)",
            ].joined(separator: "\n")
            return diff.isEmpty ? header : "\(header)\n\(diff)"
        case .rename(let source, let destination, let diff):
            guard !diff.isEmpty else {
                return [
                    "diff --git a/\(source) b/\(destination)",
                    "similarity index 100%",
                    "rename from \(source)",
                    "rename to \(destination)",
                ].joined(separator: "\n")
            }
            if diff.hasPrefix("diff --git ") { return diff }
            return [
                "diff --git a/\(source) b/\(destination)",
                "rename from \(source)",
                "rename to \(destination)",
                diff,
            ].joined(separator: "\n")
        case .unknown(_, let diff):
            return diff
        }
    }

    var syntheticHeaderLines: [String] {
        switch self {
        case .added(let path, _):
            [
                "diff --git a/\(path) b/\(path)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(path)",
            ]
        case .deleted(let path, _):
            [
                "diff --git a/\(path) b/\(path)",
                "deleted file mode 100644",
                "--- a/\(path)",
                "+++ /dev/null",
            ]
        case .update(let source, let destination, _, let hasFileHeader):
            hasFileHeader ? [] : [
                "diff --git a/\(source) b/\(destination)",
                "--- a/\(source)",
                "+++ b/\(destination)",
            ]
        case .rename(let source, let destination, let diff):
            if diff.hasPrefix("diff --git ") {
                []
            } else if diff.isEmpty {
                [
                    "diff --git a/\(source) b/\(destination)",
                    "similarity index 100%",
                    "rename from \(source)",
                    "rename to \(destination)",
                ]
            } else {
                [
                    "diff --git a/\(source) b/\(destination)",
                    "rename from \(source)",
                    "rename to \(destination)",
                ]
            }
        case .unknown:
            []
        }
    }

    private static func contentPatch(path: String, content: String, isAddition: Bool) -> String {
        let contentLines = CodexUnifiedDiffParser.contentLines(content)
        let count = contentLines.count
        let range = count == 1 ? "1" : "1,\(count)"
        var lines = [
            "diff --git a/\(path) b/\(path)",
            isAddition ? "new file mode 100644" : "deleted file mode 100644",
            isAddition ? "--- /dev/null" : "--- a/\(path)",
            isAddition ? "+++ b/\(path)" : "+++ /dev/null",
        ]
        if count > 0 {
            lines.append(isAddition ? "@@ -0,0 +\(range) @@" : "@@ -\(range) +0,0 @@")
        }
        let prefix = isAddition ? "+" : "-"
        lines.append(contentsOf: contentLines.map { prefix + String($0) })
        return lines.joined(separator: "\n")
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
    var normalizedPatch: CodexNormalizedFilePatchV2
    var wireValue: CodexJSONValue?
    var isBinary: Bool
    var isMalformed: Bool
    var isTruncated: Bool
    var omittedLineCount: Int
    var fingerprint: UInt64
    var retainedUTF8ByteCount: Int
}

/// Immutable analysis shared by incremental projections. Raw patches remain in
/// `CodexFileChangeV2`; this object retains only byte-bounded display data.
final class CodexPreparedFileChangeSetV2: @unchecked Sendable {
    static let maximumRetainedUTF8Bytes = 256 * 1_024

    let entries: [CodexPreparedFileChangeV2]
    let retainedUTF8ByteCount: Int
    let fingerprint: UInt64
    let totalAdded: Int
    let totalRemoved: Int

    init(
        entries: [CodexPreparedFileChangeV2],
        retainedUTF8ByteCount: Int,
        fingerprint: UInt64
    ) {
        self.entries = entries
        self.retainedUTF8ByteCount = retainedUTF8ByteCount
        self.fingerprint = fingerprint
        self.totalAdded = entries.reduce(0) { $0 + $1.added }
        self.totalRemoved = entries.reduce(0) { $0 + $1.removed }
    }

    static let empty = CodexPreparedFileChangeSetV2(
        entries: [],
        retainedUTF8ByteCount: 0,
        fingerprint: 0
    )
}

struct CodexFileChangePreparationKey: Sendable, Equatable {
    var itemKey: ItemKey?
    var sourceRevision: StateRevision?
    var contentFingerprint: UInt64
}

struct CodexFileChangeDiffPreparer: Sendable {
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
        let sources: [(id: String, path: String, previousPath: String?, kind: CodexFileChangeKindV2, diff: String, isMalformed: Bool, wireValue: CodexJSONValue?)]
        if changes.isEmpty {
            guard let legacyDiff, !legacyDiff.isEmpty else { return .empty }
            let parsed = CodexUnifiedDiffParser.parseBounded(
                legacyDiff,
                maximumRetainedUTF8Bytes: maximumRetainedUTF8Bytes / 2
            )
            let legacySources = parsed.files.enumerated().map { index, file in
                (
                    id: "legacy:\(index)",
                    path: file.path,
                    previousPath: Optional<String>.none,
                    kind: CodexFileChangeKindV2.fromDiffKind(file.kind),
                    diff: legacyDiff,
                    isMalformed: false,
                    wireValue: nil
                )
            }
            return prepareLegacy(
                sources: legacySources,
                parsed: parsed,
                maximumRetainedUTF8Bytes: maximumRetainedUTF8Bytes
            )
        }
        sources = changes.map {
            (
                $0.id,
                $0.displayPath,
                $0.destinationPath == nil ? nil : $0.path,
                $0.kind,
                $0.diff,
                $0.isMalformed,
                $0.wireValue
            )
        }

        let parserBudget = maximumRetainedUTF8Bytes / 2
        var remainingParserBudget = parserBudget
        var drafts: [(source: (id: String, path: String, previousPath: String?, kind: CodexFileChangeKindV2, diff: String, isMalformed: Bool, wireValue: CodexJSONValue?), parsed: CodexParsedDiff, normalized: CodexNormalizedFilePatchV2)] = []
        drafts.reserveCapacity(sources.count)
        for source in sources {
            let normalized = normalizedPatch(for: source)
            let parsed: CodexParsedDiff
            switch source.kind {
            case .added:
                parsed = parseContent(
                    source.diff,
                    path: source.path,
                    kind: "added",
                    isAddition: true,
                    maximumRetainedUTF8Bytes: remainingParserBudget
                )
            case .deleted:
                parsed = parseContent(
                    source.diff,
                    path: source.path,
                    kind: "deleted",
                    isAddition: false,
                    maximumRetainedUTF8Bytes: remainingParserBudget
                )
            case .modified, .renamed, .unknown:
                parsed = CodexUnifiedDiffParser.parseBounded(
                    source.diff,
                    fallbackPath: source.path,
                    fallbackKind: source.kind.diffKind,
                    maximumRetainedUTF8Bytes: remainingParserBudget
                )
            }
            remainingParserBudget = max(0, remainingParserBudget - parsed.retainedUTF8ByteCount)
            drafts.append((source, parsed, normalized))
        }

        var retained = drafts.reduce(0) { $0 + $1.parsed.retainedUTF8ByteCount }
        var entries: [CodexPreparedFileChangeV2] = []
        entries.reserveCapacity(drafts.count)
        var setHasher = CodexStableFingerprint()
        for draft in drafts {
            let consolidated = consolidate(
                draft.parsed.files,
                path: draft.source.path,
                kind: draft.source.kind.diffKind
            )
            let displayBudget = max(0, (maximumRetainedUTF8Bytes - retained) / 2)
            let display = boundedPatchText(
                file: consolidated,
                normalizedPatch: draft.normalized,
                omittedLineCount: max(0, draft.parsed.totalLineCount - draft.parsed.retainedLineCount),
                maximumUTF8Bytes: displayBudget
            )
            let displayBytes = display.text.utf8.count
                + display.lines.reduce(0) { $0 + $1.text.utf8.count }
            retained += displayBytes
            var entryHasher = CodexStableFingerprint()
            entryHasher.combine(draft.source.id)
            entryHasher.combine(draft.source.path)
            entryHasher.combine(draft.source.previousPath ?? "")
            entryHasher.combine(draft.source.kind.stableValue)
            entryHasher.combine(draft.source.diff)
            entryHasher.combine(draft.source.isMalformed ? "malformed" : "valid")
            let entryFingerprint = entryHasher.value
            setHasher.combine(entryFingerprint)
            let isBinary = draft.source.diff.contains("GIT binary patch")
                || draft.source.diff.contains("Binary files ")
            entries.append(.init(
                changeID: draft.source.id,
                path: draft.source.path,
                previousPath: draft.source.previousPath,
                kind: draft.source.kind,
                added: consolidated.added,
                removed: consolidated.removed,
                file: consolidated,
                displayPatch: display.text,
                displayLines: display.lines,
                normalizedPatch: draft.normalized,
                wireValue: draft.source.wireValue,
                isBinary: isBinary,
                isMalformed: draft.source.isMalformed,
                isTruncated: draft.parsed.isTruncated || display.isTruncated,
                omittedLineCount: display.omittedLineCount,
                fingerprint: entryFingerprint,
                retainedUTF8ByteCount: draft.parsed.retainedUTF8ByteCount + displayBytes
            ))
        }
        return .init(
            entries: entries,
            retainedUTF8ByteCount: min(retained, maximumRetainedUTF8Bytes),
            fingerprint: setHasher.value
        )
    }

    private static func prepareLegacy(
        sources: [(id: String, path: String, previousPath: String?, kind: CodexFileChangeKindV2, diff: String, isMalformed: Bool, wireValue: CodexJSONValue?)],
        parsed: CodexParsedDiff,
        maximumRetainedUTF8Bytes: Int
    ) -> CodexPreparedFileChangeSetV2 {
        var retained = parsed.retainedUTF8ByteCount
        var entries: [CodexPreparedFileChangeV2] = []
        var setHasher = CodexStableFingerprint()
        for (index, source) in sources.enumerated() {
            guard parsed.files.indices.contains(index) else { continue }
            let file = parsed.files[index]
            let display = boundedPatchText(
                file: file,
                normalizedPatch: .unknown(path: source.path, diff: source.diff),
                omittedLineCount: max(0, parsed.totalLineCount - parsed.retainedLineCount),
                maximumUTF8Bytes: max(0, (maximumRetainedUTF8Bytes - retained) / 2)
            )
            let displayBytes = display.text.utf8.count
                + display.lines.reduce(0) { $0 + $1.text.utf8.count }
            retained += displayBytes
            var hasher = CodexStableFingerprint()
            hasher.combine(source.id)
            hasher.combine(source.diff)
            let fingerprint = hasher.value
            setHasher.combine(fingerprint)
            entries.append(.init(
                changeID: source.id,
                path: source.path,
                previousPath: nil,
                kind: source.kind,
                added: file.added,
                removed: file.removed,
                file: file,
                displayPatch: display.text,
                displayLines: display.lines,
                normalizedPatch: .unknown(path: source.path, diff: source.diff),
                wireValue: source.wireValue,
                isBinary: source.diff.contains("GIT binary patch") || source.diff.contains("Binary files "),
                isMalformed: source.isMalformed,
                isTruncated: parsed.isTruncated || display.isTruncated,
                omittedLineCount: display.omittedLineCount,
                fingerprint: fingerprint,
                retainedUTF8ByteCount: file.retainedUTF8ByteCount + displayBytes
            ))
        }
        return .init(
            entries: entries,
            retainedUTF8ByteCount: min(retained, maximumRetainedUTF8Bytes),
            fingerprint: setHasher.value
        )
    }

    private static func normalizedPatch(
        for source: (id: String, path: String, previousPath: String?, kind: CodexFileChangeKindV2, diff: String, isMalformed: Bool, wireValue: CodexJSONValue?)
    ) -> CodexNormalizedFilePatchV2 {
        switch source.kind {
        case .added:
            return .added(path: source.path, content: source.diff)
        case .deleted:
            return .deleted(path: source.path, content: source.diff)
        case .modified:
            return .update(
                sourcePath: source.path,
                destinationPath: source.path,
                diff: source.diff,
                hasFileHeader: source.diff.hasPrefix("diff --git ")
            )
        case .renamed:
            return .rename(
                sourcePath: source.previousPath ?? source.path,
                destinationPath: source.path,
                diff: source.diff
            )
        case .unknown:
            return .unknown(path: source.path, diff: source.diff)
        }
    }

    private static func parseContent(
        _ content: String,
        path: String,
        kind: String,
        isAddition: Bool,
        maximumRetainedUTF8Bytes: Int
    ) -> CodexParsedDiff {
        let rawLines = CodexUnifiedDiffParser.contentLines(content)
        var retainedLines: [CodexDiffLine] = []
        var retainedBytes = 0
        var didExhaustRetention = false
        retainedLines.reserveCapacity(min(rawLines.count, 512))
        let prefix = isAddition ? "+" : "-"
        for rawLine in rawLines {
            let text = prefix + String(rawLine)
            let bytes = text.utf8.count
            guard !didExhaustRetention,
                  retainedBytes + bytes <= maximumRetainedUTF8Bytes else {
                didExhaustRetention = true
                continue
            }
            retainedLines.append(.init(kind: isAddition ? .add : .remove, text: text))
            retainedBytes += bytes
        }
        let count = rawLines.count
        let range = count == 1 ? "1" : "1,\(count)"
        let header = isAddition ? "@@ -0,0 +\(range) @@" : "@@ -\(range) +0,0 @@"
        let file = CodexDiffFile(
            path: path,
            kind: kind,
            added: isAddition ? count : 0,
            removed: isAddition ? 0 : count,
            hunks: [.init(header: count == 0 ? "" : header, lines: retainedLines)]
        )
        return .init(
            files: [file],
            totalLineCount: count,
            retainedLineCount: retainedLines.count,
            retainedUTF8ByteCount: retainedBytes
        )
    }

    private static func consolidate(
        _ files: [CodexDiffFile],
        path: String,
        kind: String
    ) -> CodexDiffFile {
        guard !files.isEmpty else {
            return .init(path: path, kind: kind, added: 0, removed: 0, hunks: [])
        }
        return .init(
            path: path,
            kind: kind,
            added: files.reduce(0) { $0 + $1.added },
            removed: files.reduce(0) { $0 + $1.removed },
            hunks: files.flatMap(\.hunks)
        )
    }

    private static func boundedPatchText(
        file: CodexDiffFile,
        normalizedPatch: CodexNormalizedFilePatchV2,
        omittedLineCount: Int,
        maximumUTF8Bytes: Int
    ) -> (text: String, lines: [CodexDiffLine], isTruncated: Bool, omittedLineCount: Int) {
        guard maximumUTF8Bytes > 0 else {
            return ("", [], true, max(1, omittedLineCount))
        }
        var candidates: [CodexDiffLine] = [
            .init(kind: .context, text: "\(file.path) · +\(file.added) −\(file.removed)")
        ]
        for line in normalizedPatch.syntheticHeaderLines {
            candidates.append(.init(kind: .context, text: line))
        }
        for hunk in file.hunks {
            if !hunk.header.isEmpty {
                candidates.append(.init(kind: .context, text: hunk.header))
            }
            candidates.append(contentsOf: hunk.lines)
        }

        var retained: [CodexDiffLine] = []
        retained.reserveCapacity(candidates.count)
        var retainedBytes = 0
        for candidate in candidates {
            let separatorBytes = retained.isEmpty ? 0 : 1
            guard retainedBytes + separatorBytes + candidate.text.utf8.count <= maximumUTF8Bytes else {
                break
            }
            retained.append(candidate)
            retainedBytes += separatorBytes + candidate.text.utf8.count
        }

        var totalOmitted = omittedLineCount + candidates.count - retained.count
        if totalOmitted > 0 {
            while true {
                let marker = "… \(totalOmitted) more lines"
                let separatorBytes = retained.isEmpty ? 0 : 1
                if retainedBytes + separatorBytes + marker.utf8.count <= maximumUTF8Bytes {
                    retained.append(.init(kind: .context, text: marker))
                    break
                }
                guard let removed = retained.popLast() else { break }
                retainedBytes -= removed.text.utf8.count + (retained.isEmpty ? 0 : 1)
                totalOmitted += 1
            }
        }
        return (
            retained.map(\.text).joined(separator: "\n"),
            retained,
            totalOmitted > 0,
            totalOmitted
        )
    }
}

enum CodexUnifiedDiffParser {
    static let defaultMaximumRetainedUTF8Bytes = 128 * 1_024

    static func parse(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil
    ) -> [CodexDiffFile] {
        parseBounded(
            diff,
            fallbackPath: fallbackPath,
            fallbackKind: fallbackKind,
            maximumRetainedUTF8Bytes: defaultMaximumRetainedUTF8Bytes
        ).files
    }

    static func parseBounded(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil,
        maximumRetainedUTF8Bytes: Int
    ) -> CodexParsedDiff {
        guard !diff.isEmpty else {
            return .init(
                files: [],
                totalLineCount: 0,
                retainedLineCount: 0,
                retainedUTF8ByteCount: 0
            )
        }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var files: [CodexDiffFile] = []
        var path = fallbackPath
        var kind = fallbackKind ?? "modified"
        var hunks: [CodexDiffHunk] = []
        var headerLines: [CodexDiffLine] = []
        var currentHeader: String?
        var currentLines: [CodexDiffLine] = []
        var added = 0
        var removed = 0
        var sawFile = false
        var retainedBytes = 0
        var retainedLineCount = 0
        var didExhaustRetention = false

        func retain(_ line: Substring, kind: CodexDiffLine.Kind) -> CodexDiffLine? {
            let byteCount = line.utf8.count
            guard !didExhaustRetention,
                  retainedBytes + byteCount <= maximumRetainedUTF8Bytes else {
                didExhaustRetention = true
                return nil
            }
            retainedBytes += byteCount
            retainedLineCount += 1
            return .init(kind: kind, text: String(line))
        }
        func retain(_ line: String, kind: CodexDiffLine.Kind) -> CodexDiffLine? {
            retain(line[...], kind: kind)
        }
        func flushHunk() {
            if let currentHeader {
                hunks.append(.init(header: currentHeader, lines: currentLines))
            } else if !headerLines.isEmpty {
                hunks.append(.init(header: "", lines: headerLines))
            }
            currentHeader = nil
            currentLines = []
            headerLines = []
        }
        func flushFile() {
            flushHunk()
            guard sawFile || !hunks.isEmpty else { return }
            files.append(.init(path: path, kind: kind, added: added, removed: removed, hunks: hunks))
            hunks = []
            added = 0
            removed = 0
            kind = fallbackKind ?? "modified"
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                sawFile = true
                let pieces = line.split(separator: " ")
                if pieces.count >= 4 { path = cleanPath(String(pieces[3])) }
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
            } else if line.hasPrefix("@@") {
                flushHunk()
                if !didExhaustRetention,
                   retainedBytes + line.utf8.count <= maximumRetainedUTF8Bytes {
                    currentHeader = String(line)
                    retainedBytes += line.utf8.count
                    retainedLineCount += 1
                } else {
                    didExhaustRetention = true
                    // Preserve hunk state even when the header itself is outside
                    // the display budget; source lines still need exact stats.
                    currentHeader = ""
                }
            } else if currentHeader != nil {
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
                if let retained = retain(line, kind: lineKind) { currentLines.append(retained) }
            } else if line.hasPrefix("new file mode") {
                kind = "added"
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
            } else if line.hasPrefix("deleted file mode") {
                kind = "deleted"
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
            } else if line.hasPrefix("rename from ") {
                kind = "renamed"
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
            } else if line.hasPrefix("--- ") {
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
            } else if line.hasPrefix("+++ ") {
                let candidate = cleanPath(String(line.dropFirst(4)))
                if candidate != "/dev/null" { path = candidate }
                if let retained = retain(line, kind: .context) { headerLines.append(retained) }
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
                if let retained = retain(line, kind: lineKind) { headerLines.append(retained) }
            }
        }
        flushFile()
        if files.isEmpty {
            let fallbackLines = lines.compactMap { retain($0, kind: .context) }
            files = [.init(
                path: fallbackPath,
                kind: fallbackKind ?? "unknown",
                added: 0,
                removed: 0,
                hunks: [.init(header: "", lines: fallbackLines)]
            )]
        }
        return .init(
            files: files,
            totalLineCount: lines.count,
            retainedLineCount: retainedLineCount,
            retainedUTF8ByteCount: retainedBytes
        )
    }

    static func contentLines(_ content: String) -> [Substring] {
        guard !content.isEmpty else { return [] }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if content.hasSuffix("\n"), lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func cleanPath(_ value: String) -> String {
        let path = value.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? value
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }
}

struct CodexStableFingerprint: Sendable {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        combineSeparator()
    }

    mutating func combine(_ number: UInt64) {
        var littleEndian = number.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
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
        path.utf8.count
            + kind.utf8.count
            + hunks.reduce(0) { partial, hunk in
                partial
                    + hunk.header.utf8.count
                    + hunk.lines.reduce(0) { $0 + $1.text.utf8.count }
            }
    }
}
