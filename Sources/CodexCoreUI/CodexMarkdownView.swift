import SwiftUI
@preconcurrency import MarkdownUI

public struct CodexMarkdownView: View {
    private let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        Markdown(markdown)
            .markdownTheme(CodexMarkdownTheme.make())
            .textSelection(.enabled)
    }
}

private enum CodexMarkdownTheme {
    static func make() -> Theme {
        Theme.basic
            .text {
                FontFamily(.system())
                FontSize(14)
                BackgroundColor(nil)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(Color.codexInlineCodeBackground)
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(Color.codexLink)
            }
    }
}

private extension Color {
    static let codexLink = Color(
        light: Color(rgba: 0x534FE3FF),
        dark: Color(rgba: 0x7C84FFFF)
    )
    static let codexInlineCodeBackground = Color(
        light: Color(rgba: 0xEDEFF3FF),
        dark: Color(rgba: 0x232746FF)
    )
}
