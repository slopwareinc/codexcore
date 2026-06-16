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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { details }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.codeFaint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toolCall.displayName)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.colors.codeText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(toolCall.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.colors.codeFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                CodexToolCallStatusChip(toolCall: toolCall)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.codeFaint)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.codeHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
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
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.colors.codeFaint)
                    }
                    Spacer()
                    CodexCopyButton(copied: $copied) { copyToPasteboard(toolCall.copyText) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.colors.codeHeader)
            }
        }
    }

    private func detailBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeFaint)
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
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
        HStack(spacing: 5) {
            if toolCall.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.colors.running)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
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

