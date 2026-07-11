import SwiftUI

/// Renders assistant prose through the cached block renderer: markdown, code
/// fences, lists, tables, and streaming-tail projection all stay in one path.
public struct CodexAssistantContentView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let blocks: [CodexBlock]

    public init(text: String, isStreaming: Bool, cacheNamespace: String, previous: [CodexBlock]? = nil) {
        self.blocks = CodexBlockProjector.project(
            text,
            previous: previous,
            streaming: isStreaming,
            cacheNamespace: cacheNamespace
        )
    }

    public init(projectedBlocks: [CodexBlock], cacheNamespace _: String) {
        self.blocks = projectedBlocks
    }

    public var projectedBlocks: [CodexBlock] { blocks }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.rowGap) {
            ForEach(blocks) { block in
                CodexBlockView(block: block)
                    .equatable()
                    .id(block.id)
            }
        }
    }
}

public struct CodexCodeBlock: View {
    @Environment(\.codexAgentTheme) private var theme

    private let language: String?
    private let code: String
    @State private var copied = false

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.codeFaint)
                Text(displayLanguage)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.codeFaint)
                Spacer()
                CodexCopyButton(copied: $copied, copyText: code)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.colors.codeHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(theme.fonts.code)
                    .foregroundStyle(theme.colors.codeText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        }
    }

    private var displayLanguage: String {
        language?.isEmpty == false ? language! : "code"
    }
}

public struct CodexCopyButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexClipboardService) private var clipboardService

    @Binding private var copied: Bool
    private let copyText: String

    public init(copied: Binding<Bool>, copyText: String) {
        self._copied = copied
        self.copyText = copyText
    }

    public var body: some View {
        Button {
            clipboardService.copy(copyText)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(theme.fonts.caption)
                Text(copied ? "Copied" : "Copy")
                    .font(theme.fonts.caption)
            }
            .foregroundStyle(copied ? theme.colors.success : theme.colors.codeFaint)
        }
        .buttonStyle(.plain)
    }
}
