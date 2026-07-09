import Foundation
import SwiftUI
import CodexCore

/// Lean tool-call row matching the official Codex activity style:
/// one muted summary line, expand only for payload detail.
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
            Button {
                guard hasExpandableDetail else { return }
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(headerTitle)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subtitle = headerSubtitle {
                        Text(subtitle)
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if hasExpandableDetail {
                        Image(systemName: "chevron.right")
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary.opacity(0.7))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasExpandableDetail)

            if expanded, hasExpandableDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if !toolCall.arguments.isEmpty {
                        leanDetail(label: "args", text: toolCall.arguments)
                    }
                    if !toolCall.progress.isEmpty {
                        leanDetail(label: "progress", text: toolCall.progress.joined(separator: "\n"))
                    }
                    if !toolCall.result.isEmpty {
                        leanDetail(label: "result", text: toolCall.result)
                    }
                    if let error = toolCall.error, !error.isEmpty {
                        leanDetail(label: "error", text: error, isError: true)
                    }
                    if !toolCall.copyText.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            CodexCopyButton(copied: $copied, copyText: toolCall.copyText)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .accessibilityLabel(headerTitle)
    }

    private var headerTitle: String {
        // Tool name only — no "Ran"/"Running" title chrome.
        let name = toolCall.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return toolCall.isStreaming ? "tool" : "tool" }
        return name
    }

    private var headerSubtitle: String? {
        if toolCall.isStreaming { return "…" }
        if toolCall.error != nil { return "failed" }
        if let duration = formattedDuration { return duration }
        return nil
    }

    private var hasExpandableDetail: Bool {
        !toolCall.arguments.isEmpty
            || !toolCall.progress.isEmpty
            || !toolCall.result.isEmpty
            || !(toolCall.error ?? "").isEmpty
    }

    private func leanDetail(label: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(theme.fonts.micro)
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.textTertiary)
            Text(text)
                .font(theme.fonts.code)
                .foregroundStyle(isError ? theme.colors.danger : theme.colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var formattedDuration: String? {
        guard let duration = toolCall.durationMilliseconds else { return nil }
        if duration < 1000 { return "\(duration)ms" }
        let seconds = Double(duration) / 1000
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds.rounded()))s"
    }
}
