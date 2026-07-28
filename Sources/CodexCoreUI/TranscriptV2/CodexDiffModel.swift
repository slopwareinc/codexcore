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

enum CodexUnifiedDiffParser {
    static func parse(
        _ diff: String,
        fallbackPath: String = "patch",
        fallbackKind: String? = nil
    ) -> [CodexDiffFile] {
        guard !diff.isEmpty else { return [] }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
            hunks = []; added = 0; removed = 0; kind = fallbackKind ?? "modified"
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                sawFile = true
                let pieces = line.split(separator: " ")
                if pieces.count >= 4 { path = Self.cleanPath(String(pieces[3])) }
                headerLines.append(.init(kind: .context, text: line))
            } else if line.hasPrefix("new file mode") {
                kind = "added"; headerLines.append(.init(kind: .context, text: line))
            } else if line.hasPrefix("deleted file mode") {
                kind = "deleted"; headerLines.append(.init(kind: .context, text: line))
            } else if line.hasPrefix("rename from ") {
                kind = "renamed"; headerLines.append(.init(kind: .context, text: line))
            } else if line.hasPrefix("+++ ") {
                let candidate = Self.cleanPath(String(line.dropFirst(4)))
                if candidate != "/dev/null" { path = candidate }
                headerLines.append(.init(kind: .context, text: line))
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHeader = line
            } else {
                let parsed: CodexDiffLine
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    parsed = .init(kind: .add, text: line); added += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    parsed = .init(kind: .remove, text: line); removed += 1
                } else {
                    parsed = .init(kind: .context, text: line)
                }
                if currentHeader == nil { headerLines.append(parsed) } else { currentLines.append(parsed) }
            }
        }
        flushFile()
        if files.isEmpty {
            let fallback = lines.map { CodexDiffLine(kind: .context, text: $0) }
            return [.init(
                path: fallbackPath,
                kind: fallbackKind ?? "unknown",
                added: 0,
                removed: 0,
                hunks: [.init(header: "", lines: fallback)]
            )]
        }
        return files
    }

    private static func cleanPath(_ value: String) -> String {
        let path = value.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? value
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
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
}
