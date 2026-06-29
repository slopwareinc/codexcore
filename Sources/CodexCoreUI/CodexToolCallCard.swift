import Foundation
import SwiftUI
import CodexCore

public struct CodexToolCallCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let toolCall: CodexChatMessage.ToolCall

    @State private var expanded = false
    @State private var copied = false
    @State private var wrapsOutput = false

    public init(toolCall: CodexChatMessage.ToolCall) {
        self.toolCall = toolCall
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.surface.opacity(theme.effects.glassOpacity),
            border: theme.colors.border.opacity(0.74),
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button {
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolCall.isStreaming ? "play.circle" : "checkmark.circle")
                        .font(theme.fonts.caption)
                        .foregroundStyle(statusColor)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolCall.displayName)
                            .font(theme.fonts.code)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(headerSummary)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    Text(timingLabel)
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.colors.surfaceElevated.opacity(0.28))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                if !toolCall.arguments.isEmpty {
                    detailBlock(title: "arguments", text: toolCall.arguments)
                }
                if !toolCall.progress.isEmpty {
                    detailBlock(title: "progress", text: toolCall.progress.joined(separator: "\n"))
                }
                if !toolCall.result.isEmpty {
                    detailBlock(title: "result", text: toolCall.result)
                }
                if let error = toolCall.error, !error.isEmpty {
                    detailBlock(title: "error", text: error, isError: true)
                }
                if toolCall.copyText.isEmpty {
                    Text(toolCall.isStreaming ? "Waiting for tool output..." : "No output")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.colors.codeBackground)
                }
            }
            .padding(8)
            .background(theme.colors.codeBackground)

            if !toolCall.copyText.isEmpty {
                HStack(spacing: 10) {
                    Text(statusText)
                        .font(theme.fonts.micro)
                        .foregroundStyle(statusColor)
                    Spacer()
                    Button {
                        wrapsOutput.toggle()
                    } label: {
                        Image(systemName: wrapsOutput ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.codeFaint)
                    }
                    .buttonStyle(.plain)
                    .help(wrapsOutput ? "Disable wrapping" : "Wrap output")
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
            HStack {
                Text(title)
                    .font(theme.fonts.micro)
                    .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.colors.codeHeader)

            outputText(text, isError: isError)
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                .stroke(theme.colors.border.opacity(0.72), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func outputText(_ text: String, isError: Bool) -> some View {
        if wrapsOutput {
            Text(text)
                .font(theme.fonts.code)
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(theme.fonts.code)
                    .foregroundStyle(isError ? theme.colors.danger : theme.colors.codeText)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    private var headerSummary: String {
        if toolCall.isStreaming { return "Running \(toolCall.displayName)" }
        if toolCall.error != nil { return "Tool call failed" }
        return "Ran \(toolCall.displayName)"
    }

    private var timingLabel: String {
        if let duration = formattedDuration {
            return toolCall.isStreaming ? "Running for \(duration)" : "Ran for \(duration)"
        }
        return toolCall.isStreaming ? "Running" : "Ran"
    }

    private var statusText: String {
        if toolCall.isStreaming { return "running" }
        if toolCall.error != nil { return "failed" }
        return toolCall.status.isEmpty ? "done" : toolCall.status
    }

    private var statusColor: Color {
        if toolCall.isStreaming { return theme.colors.running }
        if toolCall.error != nil || toolCall.status.localizedCaseInsensitiveContains("fail") { return theme.colors.danger }
        return theme.colors.success
    }

    private var formattedDuration: String? {
        guard let duration = toolCall.durationMilliseconds else { return nil }
        if duration < 1000 { return "\(duration)ms" }
        let seconds = Double(duration) / 1000
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds.rounded()))s"
    }
}
