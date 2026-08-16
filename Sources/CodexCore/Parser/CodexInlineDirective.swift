import Foundation

public struct CodexInlineDirective: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var range: Range<String.Index>

    public init(name: String, attributes: [String: String], range: Range<String.Index>) {
        self.name = name
        self.attributes = attributes
        self.range = range
    }
}

public enum CodexInlineDirectiveParser {
    private static let expression: NSRegularExpression = {
        // NSRegularExpression is immutable and safe to share across calls.
        // Directive parsing runs once per transcript line, so compiling this
        // pattern on every call needlessly adds work to every projection.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^\s*::([a-zA-Z0-9-]+)\{(.*)\}\s*$"#)
    }()

    public static func parse(line: String) -> CodexInlineDirective? {
        // Most transcript lines are ordinary prose. Avoid entering the regex
        // engine when the first non-whitespace character is not a directive.
        guard let firstNonWhitespace = line.firstIndex(where: { !$0.isWhitespace }),
              line[firstNonWhitespace...].hasPrefix("::"),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.range.location != NSNotFound,
              let nameRange = Range(match.range(at: 1), in: line),
              let bodyRange = Range(match.range(at: 2), in: line) else { return nil }
        return CodexInlineDirective(
            name: String(line[nameRange]),
            attributes: parseAttributes(String(line[bodyRange])),
            range: line.startIndex..<line.endIndex
        )
    }

    public static func split(text: String) -> [(text: String, directive: CodexInlineDirective?)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [(text: String, directive: CodexInlineDirective?)] = []
        var plain = ""
        for (index, substring) in lines.enumerated() {
            let line = String(substring)
            let hasNewline = index < lines.count - 1
            if let directive = parse(line: line) {
                if !plain.isEmpty {
                    result.append((plain, nil))
                    plain = ""
                }
                result.append((line, directive))
            } else {
                plain += line
                if hasNewline { plain += "\n" }
            }
        }
        if !plain.isEmpty { result.append((plain, nil)) }
        return result
    }

    private static func parseAttributes(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = body.startIndex
        func skipWhitespace() {
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
        }
        while index < body.endIndex {
            skipWhitespace()
            let keyStart = index
            while index < body.endIndex, (body[index].isLetter || body[index].isNumber) {
                index = body.index(after: index)
            }
            guard keyStart < index else { break }
            let key = String(body[keyStart..<index])
            skipWhitespace()
            guard index < body.endIndex, body[index] == "=" else { break }
            index = body.index(after: index)
            skipWhitespace()
            var value = ""
            if index < body.endIndex, body[index] == "\"" {
                index = body.index(after: index)
                while index < body.endIndex {
                    let character = body[index]
                    index = body.index(after: index)
                    if character == "\"" { break }
                    if character == "\\", index < body.endIndex {
                        let escaped = body[index]
                        if escaped == "\"" || escaped == "\\" {
                            value.append(escaped)
                            index = body.index(after: index)
                            continue
                        }
                    }
                    value.append(character)
                }
            } else {
                let valueStart = index
                while index < body.endIndex, !body[index].isWhitespace {
                    index = body.index(after: index)
                }
                value = String(body[valueStart..<index])
            }
            result[key] = value
        }
        return result
    }
}
