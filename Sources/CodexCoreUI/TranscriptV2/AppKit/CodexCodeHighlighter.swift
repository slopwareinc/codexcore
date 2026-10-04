import AppKit
import Foundation

protocol CodexCodeHighlighter: Sendable {
    func highlight(
        _ code: String,
        language: String?,
        theme: CodexTranscriptAppKitTheme
    ) -> NSAttributedString?
}

struct CodexRegexCodeHighlighter: CodexCodeHighlighter {
    func highlight(
        _ code: String,
        language: String?,
        theme: CodexTranscriptAppKitTheme
    ) -> NSAttributedString? {
        let language = normalized(language)
        guard language == "diff" || Self.rules[language] != nil else { return nil }

        let result = NSMutableAttributedString(string: code, attributes: [
            .font: theme.codeFont,
            .foregroundColor: theme.codeText,
            .paragraphStyle: paragraphStyle(theme)
        ])
        if language == "diff" {
            applyDiffColors(to: result, theme: theme)
            return result
        }

        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        var protected = IndexSet()
        guard let rules = Self.rules[language] else { return nil }
        // Scan comments and strings together so delimiters inside either stay opaque.
        rules.tokens.enumerateMatches(in: code, range: fullRange) { match, _, _ in
            guard let match else { return }
            let color = match.range(at: 1).location != NSNotFound ? theme.codeComment : theme.codeString
            result.addAttribute(.foregroundColor, value: color, range: match.range)
            protected.insert(integersIn: match.range.location..<NSMaxRange(match.range))
        }
        apply(expression: Self.numberExpression, color: theme.codeNumber, to: result, range: fullRange, protected: protected)
        if let keywords = rules.keywords {
            apply(expression: keywords, color: theme.codeKeyword, to: result, range: fullRange, protected: protected)
        }
        return result
    }

    private struct Rules: Sendable {
        let tokens: NSRegularExpression
        let keywords: NSRegularExpression?
    }

    private static let numberExpression = compile(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#)
    private static let rules: [String: Rules] = {
        var rules: [String: Rules] = [:]
        for language in ["swift", "javascript", "python", "json", "bash"] {
            let keywordExpression = keywords(for: language).map { keywords in
                compile("\\b(?:\(keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))\\b")
            }
            rules[language] = Rules(
                tokens: compile("(\(commentPattern(for: language)))|(\(stringPattern(for: language)))"),
                keywords: keywordExpression
            )
        }
        rules["typescript"] = rules["javascript"]
        return rules
    }()

    private static func compile(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("Invalid syntax highlighting pattern: \(error)") }
    }

    private func normalized(_ language: String?) -> String {
        switch language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "js", "jsx", "javascript": "javascript"
        case "ts", "tsx", "typescript": "typescript"
        case "py", "python": "python"
        case "sh", "shell", "zsh", "bash": "bash"
        case "patch", "diff": "diff"
        case "swift": "swift"
        case "json": "json"
        default: language?.lowercased() ?? ""
        }
    }

    private static func commentPattern(for language: String) -> String {
        switch language {
        case "python", "bash": return #"(?m:#.*$)"#
        case "json": return #"(?!)"#
        default: return #"(?s:/\*.*?\*/)|(?m://.*$)"#
        }
    }

    private static func stringPattern(for language: String) -> String {
        language == "bash"
            ? #"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\""#
            : #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    }

    private static func keywords(for language: String) -> [String]? {
        switch language {
        case "swift": return ["actor", "async", "await", "case", "class", "enum", "extension", "func", "guard", "if", "import", "let", "nil", "protocol", "return", "self", "struct", "switch", "throw", "throws", "true", "false", "var", "while"]
        case "javascript", "typescript": return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "interface", "let", "new", "null", "return", "switch", "throw", "true", "try", "type", "undefined", "var", "while"]
        case "python": return ["and", "as", "async", "await", "break", "class", "continue", "def", "elif", "else", "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case "json": return ["true", "false", "null"]
        case "bash": return ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "until", "while"]
        default: return nil
        }
    }

    private func apply(
        expression: NSRegularExpression,
        color: NSColor,
        to result: NSMutableAttributedString,
        range: NSRange,
        protected: IndexSet
    ) {
        expression.enumerateMatches(in: result.string, range: range) { match, _, _ in
            guard let match,
                  !protected.intersects(integersIn: match.range.location..<NSMaxRange(match.range)) else { return }
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func applyDiffColors(to result: NSMutableAttributedString, theme: CodexTranscriptAppKitTheme) {
        let source = result.string as NSString
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let prefix = source.substring(with: NSRange(location: range.location, length: 1))
            let color: NSColor? = switch prefix {
            case "+": theme.success
            case "-": theme.danger
            case "@": theme.codeComment
            default: nil
            }
            if let color { result.addAttribute(.foregroundColor, value: color, range: range) }
        }
    }

    private func paragraphStyle(_ theme: CodexTranscriptAppKitTheme) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return style
    }
}
