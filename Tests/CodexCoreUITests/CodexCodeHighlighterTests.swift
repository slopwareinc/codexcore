import AppKit
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexCodeHighlighterTests {
    private let highlighter = CodexRegexCodeHighlighter()
    private let theme = CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)

    @Test func commentDelimitersInsideStringsDoNotHideFollowingCode() throws {
        let code = #"let url = "https://example.com"; let count = 42 // "ignored""#
        let result = try #require(highlighter.highlight(code, language: "swift", theme: theme))
        expectColor(theme.codeString, for: "https://example.com", in: result)
        expectColor(theme.codeKeyword, for: "let count", in: result)
        expectColor(theme.codeNumber, for: "42", in: result)
        expectColor(theme.codeComment, for: "ignored", in: result)
    }

    @Test func quotedHashAndBlockCommentMarkersRemainStrings() throws {
        let python = try #require(highlighter.highlight(##"url = "#tag"; count = 42 # comment"##, language: "py", theme: theme))
        expectColor(theme.codeString, for: "#tag", in: python)
        expectColor(theme.codeNumber, for: "42", in: python)
        expectColor(theme.codeComment, for: "comment", in: python)
        let swift = try #require(highlighter.highlight(#"let text = "/* not a comment */"; return 7"#, language: "swift", theme: theme))
        expectColor(theme.codeString, for: "not a comment", in: swift)
        expectColor(theme.codeKeyword, for: "return", in: swift)
    }

    @Test func languageAliasesAndDiffColorsRemainSupported() throws {
        for (alias, language) in [("js", "javascript"), ("tsx", "typescript"), ("py", "python"), ("zsh", "bash"), ("patch", "diff")] {
            #expect(highlighter.highlight("return 42", language: alias, theme: theme)?.isEqual(to:
                try #require(highlighter.highlight("return 42", language: language, theme: theme))) == true)
        }
        #expect(highlighter.highlight("text", language: "unknown", theme: theme) == nil)
        let diff = try #require(highlighter.highlight("+added\n-removed\n@@ header", language: "diff", theme: theme))
        expectColor(theme.success, for: "+added", in: diff)
        expectColor(theme.danger, for: "-removed", in: diff)
        expectColor(theme.codeComment, for: "@@", in: diff)
    }

    private func expectColor(_ color: NSColor, for substring: String, in result: NSAttributedString) {
        let index = (result.string as NSString).range(of: substring).location
        #expect(index != NSNotFound)
        if index != NSNotFound {
            #expect((result.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor) == color)
        }
    }
}
