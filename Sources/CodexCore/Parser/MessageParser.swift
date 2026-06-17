import Foundation

// MARK: - Message Parser (Swift Implementation)

public final class MessageParser: Sendable {
    private let inlineImageRegex = try! NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\(data:image/([^;]+);base64,([A-Za-z0-9+/=\\s]+)\\)",
        options: []
    )
    private let bareDataUriRegex = try! NSRegularExpression(
        pattern: "data:image/([^;]+);base64,([A-Za-z0-9+/=]+)",
        options: []
    )
    private let bulletRegex = try! NSRegularExpression(
        pattern: "^(?:[-*•]\\s+|\\d+\\.\\s+)",
        options: []
    )
    public init() {}

    // MARK: - Render Block Extraction

    public func extractRenderBlocks(text: String) -> [AssistantRenderBlock] {
        var blocks: [AssistantRenderBlock] = []
        var markdownBuffer = ""

        let segments = extractMessageSegments(text)
        for segment in segments {
            switch segment {
            case .text(let t):
                markdownBuffer.append(t)
            case .inlineMath(let latex):
                markdownBuffer.append("$")
                markdownBuffer.append(latex)
                markdownBuffer.append("$")
            case .displayMath(let latex):
                flushMarkdownBuffer(blocks: &blocks, buffer: &markdownBuffer)
                blocks.append(.codeBlock(language: "math", code: latex.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))))
            case .codeBlock(let language, let code):
                flushMarkdownBuffer(blocks: &blocks, buffer: &markdownBuffer)
                blocks.append(.codeBlock(language: language, code: code))
            case .inlineImage(let data, _):
                flushMarkdownBuffer(blocks: &blocks, buffer: &markdownBuffer)
                blocks.append(.inlineImage(data))
            }
        }

        flushMarkdownBuffer(blocks: &blocks, buffer: &markdownBuffer)
        return blocks
    }

    private func flushMarkdownBuffer(blocks: inout [AssistantRenderBlock], buffer: inout String) {
        if !buffer.isEmpty {
            blocks.append(.markdown(buffer))
            buffer.removeAll()
        }
    }

    // MARK: - Message Segments

    private enum MessageSegmentInternal {
        case text(String)
        case inlineImage(data: Data, mimeType: String)
        case inlineMath(latex: String)
        case displayMath(latex: String)
        case codeBlock(language: String?, code: String)
    }

    private func extractMessageSegments(_ text: String) -> [MessageSegmentInternal] {
        guard !text.isEmpty else { return [] }

        var spans: [(start: Int, end: Int, segment: MessageSegmentInternal)] = []
        let codeFences = findCodeFences(text)
        let codeFenceRanges = codeFences.map { ($0.start, $0.end) }
        let inlineCodeRanges = findInlineCodeSpans(text, excludedRanges: codeFenceRanges)
        let opaqueRanges = codeFenceRanges + inlineCodeRanges

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // Inline images
        inlineImageRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let mStart = match.range.location
            let mEnd = mStart + match.range.length

            if overlapsRange(start: mStart, end: mEnd, ranges: opaqueRanges) {
                return
            }

            let mimeType = nsText.substring(with: match.range(at: 1))
            let base64Data = nsText.substring(with: match.range(at: 2))
            if let bytes = decodeBase64Image(base64Str: base64Data) {
                spans.append((mStart, mEnd, .inlineImage(data: bytes, mimeType: mimeType)))
            }
        }

        // Bare images
        bareDataUriRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let mStart = match.range.location
            let mEnd = mStart + match.range.length

            let overlaps = overlapsRange(start: mStart, end: mEnd, ranges: opaqueRanges)
                || spans.contains(where: { mStart < $0.end && mEnd > $0.start })
            if overlaps { return }

            let mimeType = nsText.substring(with: match.range(at: 1))
            let base64Data = nsText.substring(with: match.range(at: 2))
            if let bytes = decodeBase64Image(base64Str: base64Data) {
                spans.append((mStart, mEnd, .inlineImage(data: bytes, mimeType: mimeType)))
            }
        }

        for fence in codeFences {
            spans.append((fence.start, fence.end, .codeBlock(language: fence.language, code: fence.code)))
        }

        for mathSpan in findMathSpans(text, excludedRanges: opaqueRanges) {
            let overlaps = spans.contains(where: { mathSpan.start < $0.end && mathSpan.end > $0.start })
            if overlaps { continue }
            spans.append(mathSpan)
        }

        if spans.isEmpty {
            return [.text(text)]
        }

        spans.sort(by: { $0.start < $1.start })

        // Remove overlapping spans (keep earlier ones)
        var deduped: [(start: Int, end: Int, segment: MessageSegmentInternal)] = []
        for span in spans {
            if let last = deduped.last {
                if span.start < last.end {
                    continue
                }
            }
            deduped.append(span)
        }

        var segments: [MessageSegmentInternal] = []
        var cursor = 0

        for span in deduped {
            if cursor < span.start {
                let preceding = nsText.substring(with: NSRange(location: cursor, length: span.start - cursor))
                if !preceding.isEmpty {
                    segments.append(.text(preceding))
                }
            }
            segments.append(span.segment)
            cursor = span.end
        }

        if cursor < nsText.length {
            let remaining = nsText.substring(from: cursor)
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments.isEmpty ? [.text(text)] : segments
    }

    // MARK: - Code Review Parsing

    public func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        CodeReviewPayloadParser.parse(text: text)
    }

    // MARK: - Tool Calls Parsing

    public func parseToolCalls(text: String) -> [ToolCallCardModel] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let blocks = splitH3Blocks(trimmed)
        var cards: [ToolCallCardModel] = []

        for block in blocks {
            if let card = parseSingleBlock(block) {
                cards.append(card)
            }
        }
        return cards
    }

    // MARK: - Math Spans Helper

    private func findMathSpans(
        _ text: String,
        excludedRanges: [(Int, Int)]
    ) -> [(start: Int, end: Int, segment: MessageSegmentInternal)] {
        let bytes = Array(text.utf8)
        var spans: [(start: Int, end: Int, segment: MessageSegmentInternal)] = []
        var cursor = 0

        while cursor < bytes.count {
            if let found = excludedRanges.first(where: { cursor >= $0.0 && cursor < $0.1 }) {
                cursor = found.1
                continue
            }

            if bytes[cursor] == 92 && !isEscaped(text, index: cursor) { // '\\'
                let remaining = bytes[cursor...]
                if remaining.starts(with: [92, 91]) { // "\\["
                    if let closeStart = findClosingMathDelimiter(text, start: cursor + 2, delimiter: [92, 93], allowNewlines: true) { // "\\]"
                        let startIdx = text.index(text.startIndex, offsetBy: cursor + 2)
                        let endIdx = text.index(text.startIndex, offsetBy: closeStart)
                        let latex = String(text[startIdx..<endIdx])
                        if !latex.isEmpty {
                            spans.append((cursor, closeStart + 2, .displayMath(latex: latex)))
                            cursor = closeStart + 2
                            continue
                        }
                    }
                } else if remaining.starts(with: [92, 40]) { // "\\("
                    if let closeStart = findClosingMathDelimiter(text, start: cursor + 2, delimiter: [92, 41], allowNewlines: false) { // "\\)"
                        let startIdx = text.index(text.startIndex, offsetBy: cursor + 2)
                        let endIdx = text.index(text.startIndex, offsetBy: closeStart)
                        let latex = String(text[startIdx..<endIdx])
                        if !latex.isEmpty && !latex.contains("\n") {
                            spans.append((cursor, closeStart + 2, .inlineMath(latex: latex)))
                            cursor = closeStart + 2
                            continue
                        }
                    }
                }
            }

            if bytes[cursor] == 36 && !isEscaped(text, index: cursor) { // '$'
                if cursor + 1 < bytes.count && bytes[cursor + 1] == 36 { // "$$"
                    if let closeStart = findClosingMathDelimiter(text, start: cursor + 2, delimiter: [36, 36], allowNewlines: true) {
                        let startIdx = text.index(text.startIndex, offsetBy: cursor + 2)
                        let endIdx = text.index(text.startIndex, offsetBy: closeStart)
                        let latex = String(text[startIdx..<endIdx])
                        if !latex.isEmpty {
                            spans.append((cursor, closeStart + 2, .displayMath(latex: latex)))
                            cursor = closeStart + 2
                            continue
                        }
                    }
                } else if cursor + 1 < bytes.count && !Character(UnicodeScalar(bytes[cursor + 1])).isWhitespace {
                    var search = cursor + 1
                    var closeStart: Int? = nil

                    while search < bytes.count {
                        if bytes[search] == 10 { // '\n'
                            break
                        }
                        if bytes[search] == 36 && !isEscaped(text, index: search) && (search == cursor + 1 || bytes[search - 1] != 36) {
                            let previous = bytes[search - 1]
                            let nextIsDigit = (search + 1 < bytes.count) && Character(UnicodeScalar(bytes[search + 1])).isNumber

                            if !Character(UnicodeScalar(previous)).isWhitespace && !nextIsDigit {
                                closeStart = search
                                break
                            }
                        }
                        search += 1
                    }

                    if let closeStart = closeStart {
                        let startIdx = text.index(text.startIndex, offsetBy: cursor + 1)
                        let endIdx = text.index(text.startIndex, offsetBy: closeStart)
                        let latex = String(text[startIdx..<endIdx])
                        if !latex.isEmpty {
                            spans.append((cursor, closeStart + 1, .inlineMath(latex: latex)))
                            cursor = closeStart + 1
                            continue
                        }
                    }
                }
            }
            cursor += 1
        }
        return spans
    }

    // MARK: - Private Implementations

    private struct RawSection {
        var label: String?
        var content: String
    }

    private let leadingKeySet: Set<String> = [
        "status", "tool", "duration", "path", "kind", "query", "targets", "exit code", "directory", "approval", "error", "cwd", "working directory"
    ]

    private let namedSectionSet: Set<String> = [
        "command", "arguments", "result", "output", "targets", "prompt", "action", "progress", "error"
    ]

    private func isLeadingKey(_ normalized: String) -> Bool {
        leadingKeySet.contains(normalized)
    }

    private func isNamedSection(_ normalized: String) -> Bool {
        namedSectionSet.contains(normalized)
    }

    private func normalizeToken(_ s: String) -> String {
        let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replaced = lower.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitH3Blocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var fenceChar: Character? = nil
        var fenceLen = 0
        var inFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inFence {
                if let fc = fenceChar {
                    let closeLen = trimmed.prefix(while: { $0 == fc }).count
                    if closeLen >= fenceLen && trimmed.dropFirst(closeLen).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inFence = false
                        fenceChar = nil
                    }
                }
            } else {
                let firstChar = trimmed.first
                if let fc = firstChar, fc == "`" || fc == "~" {
                    let fl = trimmed.prefix(while: { $0 == fc }).count
                    if fl >= 3 {
                        fenceChar = fc
                        fenceLen = fl
                        inFence = true
                    }
                }
            }

            if !inFence && trimmed.hasPrefix("### ") && !current.isEmpty {
                let content = current.joined(separator: "\n")
                let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty {
                    blocks.append(c)
                }
                current.removeAll()
            }
            current.append(line)
        }

        if !current.isEmpty {
            let content = current.joined(separator: "\n")
            let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty {
                blocks.append(c)
            }
        }

        return blocks
    }

    private func parseSystemEnvelope(_ text: String) -> (title: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return nil }

        guard let firstNewlineRange = trimmed.range(of: "\n") else {
            let title = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (title, "")
        }

        let title = trimmed[trimmed.startIndex..<firstNewlineRange.lowerBound]
            .dropFirst(4)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed[firstNewlineRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return title.isEmpty ? nil : (title, String(body))
    }

    private func parseKeyValueLine(_ line: String) -> (key: String, value: String)? {
        guard let separatorIndex = line.firstIndex(of: ":") else { return nil }
        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func parseSectionHeader(_ line: String) -> (key: String, value: String)? {
        guard let (key, value) = parseKeyValueLine(line) else { return nil }
        if isNamedSection(normalizeToken(key)) {
            return (key, value)
        }
        return nil
    }

    private func isClosingFence(_ line: String, marker: Character, minLength: Int) -> Bool {
        guard line.first == marker else { return false }
        let length = line.prefix(while: { $0 == marker }).count
        guard length >= minLength else { return false }
        return line.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct FenceOpening {
        let marker: Character
        let length: Int
    }

    private func openingFence(_ line: String) -> FenceOpening? {
        guard let first = line.first else { return nil }
        guard first == "`" || first == "~" else { return nil }
        let length = line.prefix(while: { $0 == first }).count
        guard length >= 3 else { return nil }
        return FenceOpening(marker: first, length: length)
    }

    private struct ParsedFence {
        let language: String
        let content: String
    }

    private func parseSingleFence(_ text: String) -> ParsedFence? {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let opening = openingFence(firstLine) else {
            return nil
        }

        var collected: [String] = []
        var closed = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isClosingFence(trimmed, marker: opening.marker, minLength: opening.length) {
                closed = true
                break
            }
            collected.append(line)
        }
        guard closed else { return nil }

        let language = String(firstLine.dropFirst(opening.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = collected.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return ParsedFence(language: language, content: content)
    }

    private func splitNamedSections(_ text: String) -> [RawSection] {
        let lines = text.components(separatedBy: "\n")
        var sections: [RawSection] = []
        var currentLabel: String? = nil
        var buffer: [String] = []
        var sawNamedSection = false

        var fenceChar: Character? = nil
        var fenceLen = 0
        var inFence = false

        func flush() {
            let content = buffer.joined(separator: "\n")
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || currentLabel != nil {
                sections.append(RawSection(label: currentLabel, content: trimmed))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inFence {
                if let fc = fenceChar {
                    let closeLen = trimmed.prefix(while: { $0 == fc }).count
                    if closeLen >= fenceLen && trimmed.dropFirst(closeLen).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inFence = false
                        fenceChar = nil
                    }
                }
            } else {
                let firstChar = trimmed.first
                if let fc = firstChar, fc == "`" || fc == "~" {
                    let fl = trimmed.prefix(while: { $0 == fc }).count
                    if fl >= 3 {
                        fenceChar = fc
                        fenceLen = fl
                        inFence = true
                    }
                }
            }

            if !inFence {
                if let (label, inlineValue) = parseSectionHeader(trimmed) {
                    sawNamedSection = true
                    flush()
                    currentLabel = label
                    if !inlineValue.isEmpty {
                        buffer.append(inlineValue)
                    }
                    continue
                }
            }

            buffer.append(line)
        }
        flush()

        if !sawNamedSection {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [RawSection(label: nil, content: trimmed)]
        }

        return sections
    }

    private func splitTopLevel(_ text: String, separator: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []

        var fenceChar: Character? = nil
        var fenceLen = 0
        var inFence = false

        func flush() {
            let content = current.joined(separator: "\n")
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inFence {
                if let fc = fenceChar {
                    let closeLen = trimmed.prefix(while: { $0 == fc }).count
                    if closeLen >= fenceLen && trimmed.dropFirst(closeLen).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inFence = false
                        fenceChar = nil
                    }
                }
            } else {
                let firstChar = trimmed.first
                if let fc = firstChar, fc == "`" || fc == "~" {
                    let fl = trimmed.prefix(while: { $0 == fc }).count
                    if fl >= 3 {
                        fenceChar = fc
                        fenceLen = fl
                        inFence = true
                    }
                }
            }

            if !inFence && trimmed == separator {
                flush()
                continue
            }
            current.append(line)
        }
        flush()

        return chunks
    }

    private func parseTargetItems(_ content: String) -> [String] {
        var items: [String] = []
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let range = NSRange(location: 0, length: line.utf16.count)
            let deBulleted = bulletRegex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")

            for candidate in deBulleted.components(separatedBy: ",") {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    items.append(normalized)
                }
            }
        }
        return items
    }

    private func parseFileChangeSections(_ remainder: String) -> (sections: [ToolCallSection], paths: [String]) {
        let chunks = splitTopLevel(remainder, separator: "---")
        var sections: [ToolCallSection] = []
        var paths: [String] = []

        for (idx, chunk) in chunks.enumerated() {
            let lines = chunk.components(separatedBy: "\n")
            var cursor = 0
            var entryMetadata: [ToolCallKeyValue] = []

            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    cursor += 1
                    break
                }
                if let (key, value) = parseKeyValueLine(trimmed) {
                    let nk = normalizeToken(key)
                    if nk == "path" || nk == "kind" {
                        if nk == "path" && !value.isEmpty {
                            paths.append(value)
                        }
                        entryMetadata.append(ToolCallKeyValue(key: key, value: value))
                        cursor += 1
                        continue
                    }
                }
                break
            }

            if !entryMetadata.isEmpty {
                sections.append(.kv(label: "Change \(idx + 1)", entries: entryMetadata))
            }

            let content = lines[cursor...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            if let fence = parseSingleFence(content) {
                let language = normalizeToken(fence.language)
                if language == "diff" {
                    sections.append(.diff(label: "Diff", content: fence.content))
                } else if language == "json" {
                    sections.append(.json(label: "Content", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    sections.append(.text(label: "Content", content: fence.content))
                } else {
                    sections.append(.code(label: "Content", language: fence.language, content: fence.content))
                }
            } else {
                sections.append(.text(label: "Content", content: content))
            }
        }

        return (sections, paths)
    }

    private func appendSection(
        raw: RawSection,
        kind: ToolCallKind,
        primary: inout [ToolCallSection],
        aux: inout [ToolCallSection]
    ) {
        let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let label = raw.label {
            let capitalized = capitalizeFirst(label)
            let nk = normalizeToken(label)
            switch nk {
            case "command":
                primary.append(makeCodeLike(label: "Command", content: content, fallbackLanguage: "bash"))
            case "arguments":
                primary.append(makeJsonLike(label: "Arguments", content: content))
            case "result":
                primary.append(makeJsonLike(label: "Result", content: content))
            case "output":
                primary.append(makeOutputLike(label: "Output", content: content))
            case "action":
                primary.append(makeJsonLike(label: "Action", content: content))
            case "prompt":
                primary.append(.text(label: "Prompt", content: content))
            case "progress":
                let items = content.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !items.isEmpty {
                    aux.append(.list(label: "Progress", items: items))
                }
            case "targets":
                let items = parseTargetItems(content)
                if !items.isEmpty {
                    aux.append(.list(label: "Targets", items: items))
                } else {
                    primary.append(.text(label: "Targets", content: content))
                }
            case "error":
                primary.append(makeOutputLike(label: "Error", content: content))
            default:
                primary.append(.text(label: capitalized, content: content))
            }
            return
        }

        // Unlabeled section
        switch kind {
        case .commandOutput:
            primary.append(makeOutputLike(label: "Output", content: content))
        case .fileDiff:
            if let fence = parseSingleFence(content) {
                if normalizeToken(fence.language) == "diff" {
                    primary.append(.diff(label: "Diff", content: fence.content))
                } else {
                    primary.append(.diff(label: "Diff", content: content))
                }
            } else {
                primary.append(.diff(label: "Diff", content: content))
            }
        case .mcpToolProgress:
            let items = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                aux.append(.list(label: "Progress", items: items))
            }
        default:
            if let fence = parseSingleFence(content) {
                let language = normalizeToken(fence.language)
                if language == "json" {
                    primary.append(.json(label: "Details", content: fence.content))
                } else if language == "diff" {
                    primary.append(.diff(label: "Diff", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    primary.append(.text(label: "Details", content: fence.content))
                } else {
                    primary.append(.code(label: "Details", language: fence.language, content: fence.content))
                }
            } else {
                primary.append(.text(label: "Details", content: content))
            }
        }
    }

    private func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    private func makeCodeLike(label: String, content: String, fallbackLanguage: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let language = fence.language.isEmpty ? fallbackLanguage : fence.language
            return .code(label: label, language: language, content: fence.content)
        }
        return .code(label: label, language: fallbackLanguage, content: content)
    }

    private func makeJsonLike(label: String, content: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let lang = normalizeToken(fence.language)
            if lang == "json" || lang.isEmpty {
                return .json(label: label, content: fence.content)
            }
            if lang == "diff" {
                return .diff(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        if looksLikeJson(content) {
            return .json(label: label, content: content)
        }
        return .text(label: label, content: content)
    }

    private func makeOutputLike(label: String, content: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let lang = normalizeToken(fence.language)
            if lang == "diff" {
                return .diff(label: label, content: fence.content)
            }
            if lang == "json" {
                return .json(label: label, content: fence.content)
            }
            if lang == "text" || lang.isEmpty {
                return .text(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        return .text(label: label, content: content)
    }

    private func looksLikeJson(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        guard "{[\"-0123456789tfn".contains(first) else { return false }

        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    private struct ParsedBody {
        let metadata: [ToolCallKeyValue]
        let primarySections: [ToolCallSection]
        let auxSections: [ToolCallSection]
        let filePaths: [String]

        func metadataValue(forKey key: String) -> String? {
            let searchKey = Self.normalizedMetadataKey(key)
            return metadata.first(where: {
                Self.normalizedMetadataKey($0.key) == searchKey
            })?.value
        }

        private static func normalizedMetadataKey(_ key: String) -> String {
            key.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func parseBody(body: String, kind: ToolCallKind) -> ParsedBody {
        let lines = body.components(separatedBy: "\n")
        var index = 0
        var metadata: [ToolCallKeyValue] = []
        var filePaths: [String] = []
        var auxSections: [ToolCallSection] = []

        // Parse leading metadata
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if metadata.isEmpty {
                    index += 1
                    continue
                }
                index += 1
                break
            }
            if parseSectionHeader(trimmed) != nil {
                break
            }
            guard let (key, value) = parseKeyValueLine(trimmed) else {
                break
            }
            let nk = normalizeToken(key)
            guard isLeadingKey(nk) else {
                break
            }

            if nk == "targets" {
                var targetContent = value
                if targetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var cursor = index + 1
                    var extraLines: [String] = []
                    while cursor < lines.count {
                        let nextTrimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                        if nextTrimmed.isEmpty || parseSectionHeader(nextTrimmed) != nil {
                            break
                        }
                        extraLines.append(nextTrimmed)
                        cursor += 1
                    }
                    if !extraLines.isEmpty {
                        targetContent = extraLines.joined(separator: "\n")
                        index = cursor - 1
                    }
                }
                let items = parseTargetItems(targetContent)
                if !items.isEmpty {
                    auxSections.append(.list(label: "Targets", items: items))
                }
            } else {
                if nk == "path" && !value.isEmpty {
                    filePaths.append(value)
                }
                metadata.append(ToolCallKeyValue(key: key, value: value))
            }
            index += 1
        }

        let remainder = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var primarySections: [ToolCallSection] = []

        if !remainder.isEmpty {
            switch kind {
            case .fileChange:
                let (secs, paths) = parseFileChangeSections(remainder)
                primarySections.append(contentsOf: secs)
                filePaths.append(contentsOf: paths)
            default:
                let rawSections = splitNamedSections(remainder)
                for raw in rawSections {
                    appendSection(raw: raw, kind: kind, primary: &primarySections, aux: &auxSections)
                }
            }
        }

        // McpToolProgress fallback
        if kind == .mcpToolProgress && auxSections.isEmpty && !remainder.isEmpty {
            let items = remainder.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                auxSections.append(.list(label: "Progress", items: items))
            }
        }

        return ParsedBody(
            metadata: metadata,
            primarySections: primarySections,
            auxSections: auxSections,
            filePaths: filePaths
        )
    }

    private func stripShellWrapper(_ command: String) -> String {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = ["/bin/zsh -lc '", "/bin/bash -lc '"]
        for wrapper in wrappers {
            if value.hasPrefix(wrapper) && value.hasSuffix("'") {
                return String(value.dropFirst(wrapper.count).dropLast())
            }
        }
        return value
    }

    private func commandSummary(_ sections: [ToolCallSection]) -> String? {
        for section in sections {
            let isCommand: Bool
            let content: String
            switch section {
            case .code(let label, _, let code):
                isCommand = normalizeToken(label) == "command"
                content = code
            case .text(let label, let text):
                isCommand = normalizeToken(label) == "command"
                content = text
            default:
                continue
            }
            guard isCommand else { continue }

            let firstLine = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            if let line = firstLine {
                return line
            }
        }
        return nil
    }

    private func collaborationTargetSummary(_ body: ParsedBody) -> String? {
        for section in body.auxSections {
            switch section {
            case .list(let label, let items):
                guard normalizeToken(label) == "targets" else { continue }
                guard let first = items.first else { return nil }
                if items.count > 1 {
                    return "\(first) +\(items.count - 1)"
                }
                return first
            default:
                continue
            }
        }
        return nil
    }

    private func basename(_ path: String) -> String {
        guard let last = path.split(separator: "/").last else { return path }
        return String(last)
    }

    private func summaryFor(
        kind: ToolCallKind,
        title: String,
        body: ParsedBody
    ) -> String {
        switch kind {
        case .commandExecution, .commandOutput:
            if let cmd = commandSummary(body.primarySections) {
                return stripShellWrapper(cmd)
            }
        case .fileChange, .fileDiff:
            if let first = body.filePaths.first {
                let base = basename(first)
                if body.filePaths.count > 1 {
                    return "\(base) +\(body.filePaths.count - 1) files"
                }
                return base.isEmpty ? first : base
            }
        case .mcpToolCall, .mcpToolProgress:
            if let tool = body.metadataValue(forKey: "tool"), !tool.isEmpty {
                return tool
            }
        case .webSearch:
            if let query = body.metadataValue(forKey: "query"), !query.isEmpty {
                return query
            }
        case .imageView:
            if let path = body.metadataValue(forKey: "path"), !path.isEmpty {
                let base = basename(path)
                return base.isEmpty ? path : base
            }
        case .collaboration:
            if let ts = collaborationTargetSummary(body), !ts.isEmpty {
                return ts
            }
            if let tool = body.metadataValue(forKey: "tool"), !tool.isEmpty {
                return tool
            }
        default:
            break
        }
        return title
    }

    private func parseDuration(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if s.hasSuffix("ms") {
            let msText = s.dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ms = Double(msText) {
                return formatDuration(ms: Int(ms))
            }
        }

        if s.hasSuffix("s") && !s.hasSuffix("minutes") && !s.hasSuffix("minute") {
            let secText = s.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if let sec = Double(secText) {
                return formatDuration(ms: Int(sec * 1000))
            }
        }

        if s.hasSuffix("minutes") || s.hasSuffix("minute") {
            let minText = s.replacingOccurrences(of: "minutes", with: "").replacingOccurrences(of: "minute", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let mins = Double(minText) {
                return formatDuration(ms: Int(mins * 60 * 1000))
            }
        }

        if let mIdx = s.firstIndex(of: "m") {
            let before = s[..<mIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.suffix(from: mIdx).hasPrefix("ms") == false {
                if let mins = Double(before) {
                    var totalMs = mins * 60 * 1000
                    let after = s[s.index(after: mIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.hasSuffix("s") {
                        let secText = after.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                        if let sec = Double(secText) {
                            totalMs += sec * 1000
                        }
                    }
                    return formatDuration(ms: Int(totalMs))
                }
            }
        }

        if let sec = Double(s) {
            return formatDuration(ms: Int(sec * 1000))
        }

        return s
    }

    private func formatDuration(ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 1.0 {
            return "\(ms)ms"
        } else if seconds < 60.0 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let remainingSeconds = Int(seconds) % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    private func parseTarget(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("]") {
            if let bracket = s.lastIndex(of: "[") {
                let nickname = s[..<bracket].trimmingCharacters(in: .whitespacesAndNewlines)
                let role = s[s.index(after: bracket)...].dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                if !nickname.isEmpty && !role.isEmpty {
                    return s
                }
            }
        }
        return s
    }

    private func normalizeStatus(_ raw: String) -> ToolCallStatus {
        let n = normalizeToken(raw)
        switch n {
        case "inprogress", "in progress", "running", "pending", "started":
            return .inProgress
        case "completed", "complete", "success", "ok", "done":
            return .completed
        case "failed", "failure", "error", "denied", "cancelled", "aborted":
            return .failed
        default:
            return .unknown
        }
    }

    private func inferredStatus(kind: ToolCallKind, raw: String?) -> ToolCallStatus {
        let s = normalizeStatus(raw ?? "")
        if s != .unknown {
            return s
        }
        if kind == .webSearch {
            return .completed
        }
        return .unknown
    }

    private func parseSingleBlock(_ text: String) -> ToolCallCardModel? {
        guard let (title, body) = parseSystemEnvelope(text) else { return nil }
        guard let kind = ToolCallKind.from(title: title) else { return nil }

        let parsed = parseBody(body: body, kind: kind)
        if parsed.metadata.isEmpty && parsed.primarySections.isEmpty && parsed.auxSections.isEmpty {
            return nil
        }

        let status = inferredStatus(kind: kind, raw: parsed.metadataValue(forKey: "status"))
        let duration = parsed.metadataValue(forKey: "duration").flatMap(parseDuration)
        let summary = summaryFor(kind: kind, title: title, body: parsed)

        var allSections: [ToolCallSection] = []
        if !parsed.metadata.isEmpty {
            allSections.append(.kv(label: "Metadata", entries: parsed.metadata))
        }
        allSections.append(contentsOf: parsed.primarySections)
        allSections.append(contentsOf: parsed.auxSections)

        let normalizedSections = normalizedSections(kind: kind, sections: allSections)
        let commandContext = synthesizedCommandContext(kind: kind, sections: allSections)

        return ToolCallCardModel(
            kind: kind,
            title: title,
            summary: summary,
            status: status,
            duration: duration,
            sections: normalizedSections,
            commandContext: commandContext
        )
    }

    private func normalizedSections(kind: ToolCallKind, sections: [ToolCallSection]) -> [ToolCallSection] {
        var normalized = sections

        if kind == .fileChange || kind == .fileDiff {
            let diffIndices = normalized.enumerated().compactMap { index, section -> Int? in
                if case .diff = section { return index }
                return nil
            }

            if !diffIndices.isEmpty {
                normalized.removeAll { section in
                    if case .list(let label, _) = section {
                        return normalizeToken(label) == "files"
                    }
                    return false
                }
            }

            if kind == .fileChange,
               diffIndices.count == 1,
               let diffIndex = normalized.enumerated().first(where: { _, section in
                   if case .diff = section { return true }
                   return false
               })?.offset,
               case .diff(_, let content) = normalized[diffIndex] {
                normalized[diffIndex] = .diff(label: "", content: content)
            }
        }

        guard kind.isCommandLike else { return normalized }
        return normalized.filter { section in
            let label = normalizedLabel(for: section)
            return label != "command" && label != "directory" && label != "cwd" && label != "working directory"
        }
    }

    private func synthesizedCommandContext(
        kind: ToolCallKind,
        sections: [ToolCallSection]
    ) -> ToolCallCommandContext? {
        guard kind.isCommandLike else { return nil }

        let command = (
            sectionText(named: ["command"], in: sections)
            ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = sectionText(named: ["directory", "cwd", "working directory"], in: sections)

        guard !command.isEmpty else {
            return nil
        }
        return ToolCallCommandContext(
            command: command,
            directory: directory?.isEmpty == true ? nil : directory
        )
    }

    private func sectionText(named names: Set<String>, in sections: [ToolCallSection]) -> String? {
        for section in sections {
            switch section {
            case .kv(_, let entries):
                for entry in entries {
                    guard names.contains(normalizeToken(entry.key)) else { continue }
                    let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            case .text(_, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .code(_, _, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            default:
                break
            }
        }
        return nil
    }

    private func normalizedLabel(for section: ToolCallSection) -> String {
        switch section {
        case .kv(let label, _),
             .code(let label, _, _),
             .json(let label, _),
             .diff(let label, _),
             .text(let label, _),
             .list(let label, _),
             .progress(let label, _):
            return normalizeToken(label)
        }
    }

    private func findClosingMathDelimiter(_ text: String, start: Int, delimiter: [UInt8], allowNewlines: Bool) -> Int? {
        let bytes = Array(text.utf8)
        var cursor = start

        while cursor + delimiter.count <= bytes.count {
            if !allowNewlines && bytes[cursor] == 10 {
                return nil
            }

            if bytes[cursor..<(cursor + delimiter.count)] == delimiter[...] && !isEscaped(text, index: cursor) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private func overlapsRange(start: Int, end: Int, ranges: [(Int, Int)]) -> Bool {
        ranges.contains(where: { start < $0.1 && end > $0.0 })
    }

    private func isEscaped(_ text: String, index: Int) -> Bool {
        if index == 0 { return false }
        let bytes = Array(text.utf8)
        var slashCount = 0
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            if bytes[cursor] == 92 {
                slashCount += 1
            } else {
                break
            }
        }
        return slashCount % 2 == 1
    }

    private func findCodeFences(_ text: String) -> [(start: Int, end: Int, language: String?, code: String)] {
        var results: [(start: Int, end: Int, language: String?, code: String)] = []
        var fenceChar: Character? = nil
        var fenceLen = 0
        var fenceStart = 0
        var fenceLanguage = ""
        var codeLines: [String] = []
        var inFence = false

        let linesWithOffsets = lineByteOffsets(text)
        for (lineStart, line) in linesWithOffsets {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inFence {
                if let fc = fenceChar {
                    let closeLen = trimmed.prefix(while: { $0 == fc }).count
                    if closeLen >= fenceLen && trimmed.dropFirst(closeLen).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let lineEnd = lineStart + line.utf16.count
                        let code = codeLines.joined(separator: "\n")
                        let language = fenceLanguage.isEmpty ? nil : fenceLanguage
                        results.append((fenceStart, lineEnd, language, code))
                        inFence = false
                        fenceChar = nil
                        codeLines.removeAll()
                        continue
                    }
                }
                codeLines.append(line)
            } else {
                let firstChar = trimmed.first
                if let fc = firstChar, fc == "`" || fc == "~" {
                    let fl = trimmed.prefix(while: { $0 == fc }).count
                    if fl >= 3 {
                        fenceChar = fc
                        fenceLen = fl
                        fenceStart = lineStart
                        fenceLanguage = String(trimmed.dropFirst(fl)).trimmingCharacters(in: .whitespacesAndNewlines)
                        inFence = true
                        codeLines.removeAll()
                        continue
                    }
                }
            }
        }
        return results
    }

    private func lineByteOffsets(_ text: String) -> [(offset: Int, line: String)] {
        let lines = text.components(separatedBy: "\n")
        var result: [(offset: Int, line: String)] = []
        var offset = 0
        for line in lines {
            result.append((offset, line))
            offset += line.utf16.count + 1
        }
        return result
    }

    private func findInlineCodeSpans(_ text: String, excludedRanges: [(Int, Int)]) -> [(Int, Int)] {
        let bytes = Array(text.utf8)
        var spans: [(Int, Int)] = []
        var cursor = 0

        while cursor < bytes.count {
            if let found = excludedRanges.first(where: { cursor >= $0.0 && cursor < $0.1 }) {
                cursor = found.1
                continue
            }

            if bytes[cursor] != 96 {
                cursor += 1
                continue
            }

            let openerLen = bytes[cursor...].prefix(while: { $0 == 96 }).count
            var search = cursor + openerLen
            var closingEnd: Int? = nil

            while search < bytes.count {
                if let found = excludedRanges.first(where: { search >= $0.0 && search < $0.1 }) {
                    search = found.1
                    continue
                }

                if bytes[search] == 96 {
                    let runLen = bytes[search...].prefix(while: { $0 == 96 }).count
                    if runLen == openerLen {
                        closingEnd = search + runLen
                        break
                    }
                    search += runLen
                } else {
                    search += 1
                }
            }

            if let end = closingEnd {
                spans.append((cursor, end))
                cursor = end
            } else {
                cursor += openerLen
            }
        }

        return spans
    }

    private func decodeBase64Image(base64Str: String) -> Data? {
        let cleaned = base64Str.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        return Data(base64Encoded: cleaned)
    }

    public func containsMath(_ text: String) -> Bool {
        let segments = extractMessageSegments(text)
        return segments.contains { segment in
            switch segment {
            case .inlineMath, .displayMath:
                return true
            default:
                return false
            }
        }
    }
}
