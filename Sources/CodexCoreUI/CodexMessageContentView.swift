import SwiftUI

/// Shared Markdown renderer for V2 assistant prose and final answers.
public struct CodexAssistantContentView: View {
    @Environment(\.codexAgentTheme) private var theme
    private let text: String

    public init(text: String, isStreaming _: Bool, cacheNamespace _: String) {
        self.text = text
    }

    public var body: some View {
        Text(markdown)
            .font(theme.fonts.chat)
            .foregroundStyle(theme.colors.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
