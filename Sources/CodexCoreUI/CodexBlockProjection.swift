import Foundation
import SwiftUI

// MARK: - Block projection model

/// One rendered block of assistant content.
///
/// `id` is stable across streaming deltas as long as the block's content
/// hasn't changed, so SwiftUI's `ForEach` can skip rebuilding rows that
/// are already on screen. The tail block of a streaming message has the
/// same `id` as the previous projection's tail — only its `content`
/// changes — so SwiftUI updates a single row instead of rebuilding the
/// whole `LazyVStack`.
public enum CodexBlock: Identifiable, Equatable, Sendable {
    case prose(id: String, text: String, attributed: AttributedString)
    case code(id: String, language: String?, code: String, complete: Bool)
    case table(id: String, model: CodexTableModel)
    case heading(id: String, level: Int, text: String, attributed: AttributedString)
    case list(id: String, ordered: Bool, items: [CodexListItem])
    case htmlFallback(id: String, text: String)

    public var id: String {
        switch self {
        case .prose(let id, _, _),
             .code(let id, _, _, _),
             .table(let id, _),
             .heading(let id, _, _, _),
             .list(let id, _, _),
             .htmlFallback(let id, _):
            return id
        }
    }

    /// A short content hash used as the cache key for `AttributedString`
    /// and `CodexTableModel`. We avoid `String.hashValue` because it is
    /// randomized per process; SHA-256 truncation gives a stable digest.
    var contentDigest: String {
        switch self {
        case .prose(_, let text, _),
             .htmlFallback(_, let text):
            return CodexBlockDigest.digest(text)
        case .code(_, let language, let code, _):
            return CodexBlockDigest.digest("\(language ?? "")\u{0}\(code)")
        case .table(_, let model):
            return model.digest
        case .heading(_, let level, let text, _):
            return CodexBlockDigest.digest("\(level)\u{0}\(text)")
        case .list(_, let ordered, let items):
            return CodexBlockDigest.digest("\(ordered)\u{0}\(items.map(\.text).joined(separator: "\u{0}"))")
        }
    }
}
public struct CodexListItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let depth: Int
    public let attributed: AttributedString

    public init(id: String, text: String, depth: Int = 0) {
        self.id = id
        self.text = text
        self.depth = depth
        self.attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    public init(id: String, text: String, depth: Int, attributed: AttributedString) {
        self.id = id
        self.text = text
        self.depth = depth
        self.attributed = attributed
    }
}

public struct CodexTableModel: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public enum Alignment: String, Sendable { case leading, center, trailing }
        public let header: String
        public let alignment: Alignment
        public init(header: String, alignment: Alignment) {
            self.header = header
            self.alignment = alignment
        }
    }

    public let columns: [Column]
    public let rows: [[String]]
    public let attributedRows: [[AttributedString]]
    public let digest: String

    public init(columns: [Column], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
        self.digest = CodexBlockDigest.digest(
            columns.map { "\($0.header)|\($0.alignment.rawValue)" }.joined(separator: "\n")
            + "\n---\n"
            + rows.map { $0.joined(separator: "|") }.joined(separator: "\n")
        )
        self.attributedRows = rows.map { row in
            row.map { cell in
                (try? AttributedString(markdown: cell)) ?? AttributedString(cell)
            }
        }
    }
}

// MARK: - Stable digest

enum CodexBlockDigest {
    /// Stable, process-independent short hash. We do not need
    /// cryptographic strength — only collision resistance across a
    /// single transcript's worth of blocks.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 36)
    }
}

// MARK: - Block projector

/// Splits streaming markdown text into a stable list of `CodexBlock`s.
///
/// The projector is the SwiftUI analog of opencode's
/// `markdown-stream.ts:project()`. It walks the text once, classifies
/// each region (prose, fenced code, table, heading, list), and returns
/// a flat block array. The last block is treated as the "live tail":
/// on subsequent deltas it is re-parsed while every block before it is
/// reused by id, so SwiftUI's `ForEach` skips rebuilding completed
/// rows during streaming.
public enum CodexBlockProjector {
    /// Project `text` into blocks. When `streaming` is true and a
    /// `previous` projection is supplied, the projector reuses the
    /// previous block ids for every block that has not changed and
    /// only re-parses the tail.
    public static func project(
        _ text: String,
        previous: [CodexBlock]? = nil,
        streaming: Bool = false,
        cacheNamespace: String
    ) -> [CodexBlock] {
        let regions = segment(text)
        if regions.isEmpty {
            return []
        }

        // Fast path: when the new text extends the previous text
        // (typical streaming case) and the previous tail was a
        // non-fenced prose region, reuse every previous block as-is
        // and only re-project the tail. This mirrors opencode's
        // `project()` shortcut.
        if streaming, let previous, !previous.isEmpty, text.count > 2 {
            if let reused = reusePrevious(previous: previous, text: text, cacheNamespace: cacheNamespace) {
                return reused
            }
        }

        return regions.enumerated().map { index, region in
            buildBlock(
                region: region,
                index: index,
                cacheNamespace: cacheNamespace,
                isTail: streaming && index == regions.count - 1
            )
        }
    }

    // MARK: Region splitting

    enum Region: Equatable {
        case prose(text: String)
        case code(language: String?, body: String, complete: Bool)
        case table(text: String)
        case heading(level: Int, text: String)
        case list(ordered: Bool, items: [CodexListItem])
    }

    /// Split raw markdown into top-level regions. This is a deliberately
    /// lightweight line-based lexer — we only need block-level
    /// classification; inline formatting is handled later by
    /// `AttributedString(markdown:)` per block.
    static func segment(_ raw: String) -> [Region] {
        var regions: [Region] = []
        let lines = raw.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank lines are region boundaries; collapse runs.
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code block: ``` or ~~~
            if let fence = matchFence(trimmed) {
                let (body, complete, consumed) = consumeFence(
                    lines: lines,
                    startIndex: index + 1,
                    fenceChar: fence.char,
                    fenceLength: fence.length
                )
                regions.append(.code(
                    language: fence.language,
                    body: body,
                    complete: complete
                ))
                index += consumed + 1
                continue
            }

            // ATX heading: # .. ######
            if let heading = matchHeading(trimmed) {
                regions.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // GFM table: a run of lines starting with `|` and containing
            // a delimiter row (|---|---|) on the second line.
            if isTableStart(lines: lines, startIndex: index) {
                let (tableText, consumed) = consumeTable(lines: lines, startIndex: index)
                regions.append(.table(text: tableText))
                index += consumed
                continue
            }

            // List: a run of lines starting with -/+/* (unordered) or
            // digits followed by . or ) (ordered).
            if let listStart = matchListMarker(trimmed) {
                let (items, consumed) = consumeList(
                    lines: lines,
                    startIndex: index,
                    ordered: listStart.ordered
                )
                if !items.isEmpty {
                    regions.append(.list(ordered: listStart.ordered, items: items))
                    index += consumed
                    continue
                }
            }

            // Default: prose paragraph. Consume until blank line, fence,
            // heading, table, or list start.
            let (prose, consumed) = consumeProse(lines: lines, startIndex: index)
            regions.append(.prose(text: prose))
            index += consumed
        }

        return regions
    }

    // MARK: Block construction

    static func buildBlock(
        region: Region,
        index: Int,
        cacheNamespace: String,
        isTail: Bool
    ) -> CodexBlock {
        let baseID = "\(cacheNamespace):block:\(index)"
        switch region {
        case .prose(let text):
            let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
            return .prose(id: baseID, text: text, attributed: attributed)
        case .code(let language, let body, let complete):
            // The tail of a streaming code fence is incomplete; tag it
            // so the renderer can choose to keep it open and append.
            return .code(id: baseID, language: language, code: body, complete: complete && !isTail ? true : complete)
        case .table(let text):
            if let model = CodexGFMTableParser.parse(text) {
                return .table(id: baseID, model: model)
            }
            // Fall back to prose if the table didn't actually parse.
            let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
            return .prose(id: baseID, text: text, attributed: attributed)
        case .heading(let level, let text):
            let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
            return .heading(id: baseID, level: level, text: text, attributed: attributed)
        case .list(let ordered, let items):
            return .list(id: baseID, ordered: ordered, items: items)
        }
    }

    // MARK: Streaming reuse

    /// When the new text is an extension of the previous text and the
    /// previous tail was a prose region (the common streaming case),
    /// reuse every previous block except the tail and re-project only
    /// the tail. This is the SwiftUI analog of opencode's
    /// `markdown-stream.ts:project()` shortcut that avoids re-lexing
    /// the entire message per token.
    static func reusePrevious(
        previous: [CodexBlock],
        text: String,
        cacheNamespace: String
    ) -> [CodexBlock]? {
        // Only reuse when the new text starts with the previous text
        // (typical append-only streaming). Any structural change
        // (edit, fork, history restore) bails to the full projector.
        let previousText = previousText(from: previous)
        guard let previousText, text.hasPrefix(previousText) else { return nil }

        // Reuse all blocks except the tail.
        let reused = Array(previous.dropLast())
        let tailStart = previousText.count
        let tailText = String(text.dropFirst(tailStart))
        let combinedTail = previousTailText(from: previous) + tailText

        // Re-segment only the tail region. If the tail is still a
        // simple prose continuation (no new fence / heading / table /
        // list boundary), produce a single prose block with the same
        // id as the previous tail so SwiftUI updates it in place.
        let tailRegions = segment(combinedTail)
        if tailRegions.count == 1, case .prose(let tailProse) = tailRegions[0] {
            let tailID = previous.last?.id ?? "\(cacheNamespace):block:0"
            let attributed = (try? AttributedString(markdown: tailProse)) ?? AttributedString(tailProse)
            return reused + [.prose(id: tailID, text: tailProse, attributed: attributed)]
        }

        // The tail crossed a structural boundary (e.g. user started
        // typing a ``` fence). Re-project the combined tail with fresh
        // ids continuing from the reused block count.
        let tailBlocks = tailRegions.enumerated().map { offset, region in
            buildBlock(
                region: region,
                index: reused.count + offset,
                cacheNamespace: cacheNamespace,
                isTail: true
            )
        }
        return reused + tailBlocks
    }

    /// Best-effort reconstruction of the source text a projection was
    /// built from. Used only for the streaming reuse fast path.
    static func previousText(from blocks: [CodexBlock]) -> String? {
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .prose(_, let text, _):
                parts.append(text)
            case .heading(_, _, let text, _):
                parts.append(text)
            case .code(_, let language, let code, _):
                let fence = "```" + (language ?? "")
                parts.append("\(fence)\n\(code)\n```")
            case .table(_, let model):
                parts.append(model.renderMarkdown())
            case .list(_, let ordered, let items):
                parts.append(items.enumerated().map { offset, item in
                    let marker = ordered ? "\(offset + 1). " : "- "
                    return String(repeating: "  ", count: item.depth) + marker + item.text
                }.joined(separator: "\n"))
            case .htmlFallback(_, let text):
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func previousTailText(from blocks: [CodexBlock]) -> String {
        guard let last = blocks.last else { return "" }
        switch last {
        case .prose(_, let text, _),
             .htmlFallback(_, let text):
            return text
        case .heading(_, _, let text, _):
            return String(repeating: "#", count: 1) + " " + text
        case .code:
            return ""
        case .table:
            return ""
        case .list:
            return ""
        }
    }

    // MARK: Lexers

    struct Fence { let char: Character; let length: Int; let language: String? }

    static func matchFence(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let rest = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        let language = rest.isEmpty ? nil : rest.split(separator: " ").first.map(String.init)
        return Fence(char: first, length: run.count, language: language)
    }

    static func consumeFence(lines: [String], startIndex: Int, fenceChar: Character, fenceLength: Int) -> (body: String, complete: Bool, consumed: Int) {
        var body: [String] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isClosingFence(trimmed, char: fenceChar, minLength: fenceLength) {
                return (body.joined(separator: "\n"), true, index - startIndex + 1)
            }
            body.append(line)
            index += 1
        }
        // Ran off the end without a closing fence — still streaming.
        return (body.joined(separator: "\n"), false, index - startIndex)
    }

    static func isClosingFence(_ trimmed: String, char: Character, minLength: Int) -> Bool {
        guard trimmed.first == char else { return false }
        let run = trimmed.prefix(while: { $0 == char })
        return run.count >= minLength && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    struct Heading { let level: Int; let text: String }

    static func matchHeading(_ trimmed: String) -> Heading? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count >= 1, hashes.count <= 6 else { return nil }
        let after = trimmed.dropFirst(hashes.count)
        guard after.first == " " || after.first == "\t" else { return nil }
        let text = after.trimmingCharacters(in: .whitespaces)
        return Heading(level: hashes.count, text: text)
    }

    static func isTableStart(lines: [String], startIndex: Int) -> Bool {
        guard startIndex + 1 < lines.count else { return false }
        let firstTrimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let secondTrimmed = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed.hasPrefix("|") || firstTrimmed.hasSuffix("|") else { return false }
        // Delimiter row must be only |, -, :, and whitespace.
        return secondTrimmed.contains("-")
            && secondTrimmed.allSatisfy { char in
                char == "|" || char == "-" || char == ":" || char == " " || char == "\t"
            }
    }

    static func consumeTable(lines: [String], startIndex: Int) -> (text: String, consumed: Int) {
        var index = startIndex
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !trimmed.contains("|") { break }
            // Stop if a new structural region starts mid-table (defensive).
            if index > startIndex, matchFence(trimmed) != nil { break }
            if index > startIndex, matchHeading(trimmed) != nil { break }
            index += 1
        }
        let consumed = max(1, index - startIndex)
        return (lines[startIndex..<startIndex + consumed].joined(separator: "\n"), consumed)
    }

    struct ListMarker { let ordered: Bool }

    static func matchListMarker(_ trimmed: String) -> ListMarker? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("* ") {
            return ListMarker(ordered: false)
        }
        // Ordered: "1. " or "1) " — digit run then a single . or )
        if let firstChar = trimmed.first, firstChar.isNumber {
            let digits = trimmed.prefix(while: { $0.isNumber })
            let after = trimmed.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return ListMarker(ordered: true)
            }
        }
        return nil
    }

    static func consumeList(lines: [String], startIndex: Int, ordered: Bool) -> (items: [CodexListItem], consumed: Int) {
        var items: [CodexListItem] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            // Indentation: nested list items get a depth.
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let depth = leading / 2
            if let marker = matchListMarker(trimmed) {
                let text = trimmed
                    .drop(while: { $0 != " " })
                    .drop(while: { $0 == " " })
                    .trimmingCharacters(in: .whitespaces)
                items.append(CodexListItem(
                    id: "list-\(startIndex)-\(index)",
                    text: text,
                    depth: depth
                ))
                index += 1
                _ = marker
                continue
            }
            // Non-list line ends the region.
            break
        }
        return (items, max(1, index - startIndex))
    }

    static func consumeProse(lines: [String], startIndex: Int) -> (text: String, consumed: Int) {
        var collected: [String] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if matchFence(trimmed) != nil { break }
            if matchHeading(trimmed) != nil { break }
            if isTableStart(lines: lines, startIndex: index) { break }
            if matchListMarker(trimmed) != nil { break }
            collected.append(line)
            index += 1
        }
        return (collected.joined(separator: "\n"), max(1, index - startIndex))
    }
}

// MARK: - Table model helpers

extension CodexTableModel {
    func renderMarkdown() -> String {
        let header = "|" + columns.map { $0.header }.joined(separator: "|") + "|"
        let align = "|" + columns.map { c in
            switch c.alignment {
            case .leading: return ":---"
            case .center: return ":---:"
            case .trailing: return "---:"
            }
        }.joined(separator: "|") + "|"
        let body = rows.map { row in
            "|" + row.joined(separator: "|") + "|"
        }.joined(separator: "\n")
        return header + "\n" + align + "\n" + body
    }
}

// MARK: - Performance Optimizations (Skip AttributedString comparison in Equatable)

extension CodexBlock {
    public static func == (lhs: CodexBlock, rhs: CodexBlock) -> Bool {
        switch (lhs, rhs) {
        case (.prose(let lid, let ltext, _), .prose(let rid, let rtext, _)):
            return lid == rid && ltext == rtext
        case (.code(let lid, let llang, let lcode, let lcomp), .code(let rid, let rlang, let rcode, let rcomp)):
            return lid == rid && llang == rlang && lcode == rcode && lcomp == rcomp
        case (.table(let lid, let lmodel), .table(let rid, let rmodel)):
            return lid == rid && lmodel == rmodel
        case (.heading(let lid, let llevel, let ltext, _), .heading(let rid, let rlevel, let rtext, _)):
            return lid == rid && llevel == rlevel && ltext == rtext
        case (.list(let lid, let lordered, let litems), .list(let rid, let rordered, let ritems)):
            return lid == rid && lordered == rordered && litems == ritems
        case (.htmlFallback(let lid, let ltext), .htmlFallback(let rid, let rtext)):
            return lid == rid && ltext == rtext
        default:
            return false
        }
    }
}

extension CodexListItem {
    public static func == (lhs: CodexListItem, rhs: CodexListItem) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.depth == rhs.depth
    }
}

extension CodexTableModel {
    public static func == (lhs: CodexTableModel, rhs: CodexTableModel) -> Bool {
        lhs.digest == rhs.digest
    }
}
