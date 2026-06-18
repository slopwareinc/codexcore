import SwiftUI
import CodexCore

public struct CodexToolCallCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let toolCall: CodexChatMessage.ToolCall

    @State private var expanded = false
    @State private var copied = false

    public init(toolCall: CodexChatMessage.ToolCall) {
        self.toolCall = toolCall
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.codeBackground,
            border: theme.colors.border,
            headerBackground: theme.colors.codeHeader,
            headerPadding: theme.spacing.cardHeaderPadding,
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, _ in
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.codeFaint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toolCall.displayName)
                        .font(theme.fonts.code.weight(.medium))
                        .foregroundStyle(theme.colors.codeText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(toolCall.summary)
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.codeFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                CodexToolCallStatusChip(toolCall: toolCall)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
        } body: {
            VStack(alignment: .leading, spacing: 10) {
                if !toolCall.arguments.isEmpty {
                    detailBlock(title: "Arguments", text: toolCall.arguments)
                }
                if !toolCall.progress.isEmpty {
                    detailBlock(title: "Progress", text: toolCall.progress.joined(separator: "\n"))
                }
                if !toolCall.result.isEmpty {
                    detailBlock(title: "Result", text: toolCall.result)
                }
                if let error = toolCall.error, !error.isEmpty {
                    detailBlock(title: "Error", text: error, isError: true)
                }
                if toolCall.copyText.isEmpty {
                    Text(toolCall.isStreaming ? "Waiting for tool output..." : "No output")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(12)

            if !toolCall.copyText.isEmpty {
                HStack {
                    if let duration = toolCall.durationMilliseconds {
                        Text("\(duration) ms")
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.codeFaint)
                    }
                    Spacer()
                    CodexCopyButton(copied: $copied) { copyToPasteboard(toolCall.copyText) }
                }
                .padding(theme.spacing.cardFooterPadding)
                .background(theme.colors.codeHeader)
            }
        }
    }

    private func detailBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(theme.fonts.micro)
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeFaint)
            Text(text)
                .font(theme.fonts.code)
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexToolCallStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let toolCall: CodexChatMessage.ToolCall

    var body: some View {
        CodexStatusChip(color: color, label: label, isStreaming: toolCall.isStreaming)
    }

    private var label: String {
        if toolCall.isStreaming { return "running" }
        if toolCall.error != nil { return "failed" }
        return toolCall.status.isEmpty ? "done" : toolCall.status
    }

    private var color: Color {
        if toolCall.isStreaming { return theme.colors.running }
        if toolCall.error != nil || toolCall.status.localizedCaseInsensitiveContains("fail") { return theme.colors.danger }
        return theme.colors.success
    }
}
