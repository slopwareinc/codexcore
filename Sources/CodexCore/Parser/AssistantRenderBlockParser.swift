import Foundation

final class AssistantRenderBlockParser {
    private static let inlineImageRegex = makeRegex(
        pattern: "!\\[[^\\]]*\\]\\(data:image/([^;]+);base64,([A-Za-z0-9+/=\\s]+)\\)"
    )
    private static let bareDataUriRegex = makeRegex(
        pattern: "data:image/([^;]+);base64,([A-Za-z0-9+/=]+)"
    )

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
        Self.inlineImageRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
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
        Self.bareDataUriRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
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

            if bytes[cursor] == 92 && !isEscaped(bytes, index: cursor) { // '\\'
                let remaining = bytes[cursor...]
                if remaining.starts(with: [92, 91]) { // "\\["
                    if let closeStart = findClosingMathDelimiter(bytes, start: cursor + 2, delimiter: [92, 93], allowNewlines: true) { // "\\]"
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
                    if let closeStart = findClosingMathDelimiter(bytes, start: cursor + 2, delimiter: [92, 41], allowNewlines: false) { // "\\)"
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

            if bytes[cursor] == 36 && !isEscaped(bytes, index: cursor) { // '$'
                if cursor + 1 < bytes.count && bytes[cursor + 1] == 36 { // "$$"
                    if let closeStart = findClosingMathDelimiter(bytes, start: cursor + 2, delimiter: [36, 36], allowNewlines: true) {
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
                        if bytes[search] == 36 && !isEscaped(bytes, index: search) && (search == cursor + 1 || bytes[search - 1] != 36) {
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

    private func findClosingMathDelimiter(_ bytes: [UInt8], start: Int, delimiter: [UInt8], allowNewlines: Bool) -> Int? {
        var cursor = start

        while cursor + delimiter.count <= bytes.count {
            if !allowNewlines && bytes[cursor] == 10 {
                return nil
            }

            if bytes[cursor..<(cursor + delimiter.count)] == delimiter[...] && !isEscaped(bytes, index: cursor) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private func overlapsRange(start: Int, end: Int, ranges: [(Int, Int)]) -> Bool {
        ranges.contains(where: { start < $0.1 && end > $0.0 })
    }

    private func isEscaped(_ bytes: [UInt8], index: Int) -> Bool {
        if index == 0 { return false }
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

}
private func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        preconditionFailure("Invalid regex pattern `\(pattern)`: \(error)")
    }
}
