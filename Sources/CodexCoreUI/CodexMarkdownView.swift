import SwiftUI
@preconcurrency import MarkdownUI

public struct CodexMarkdownView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        Markdown(markdown)
            .markdownTheme(CodexMarkdownTheme.make(theme))
            .textSelection(.enabled)
    }
}

private enum CodexMarkdownTheme {
    static func make(_ theme: CodexAgentTheme) -> Theme {
        Theme.basic
            .text {
                FontFamily(.system())
                FontSize(14)
                BackgroundColor(nil)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(theme.colors.codeText)
                BackgroundColor(theme.colors.accentSoft.opacity(0.72))
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(theme.colors.accent)
            }
    }
}
