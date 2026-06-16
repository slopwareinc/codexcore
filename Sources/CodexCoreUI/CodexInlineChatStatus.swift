import SwiftUI

struct CodexInlineChatStatus: View {
    @Environment(\.codexAgentTheme) private var theme

    let activity: CodexActivity?
    let onInterrupt: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)

            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(theme.colors.textPrimary)
                if let detail {
                    Text(detail)
                        .foregroundStyle(theme.colors.textTertiary)
                }
                CodexStreamingDots()
            }
            .font(theme.fonts.chat.weight(.medium))
            .lineLimit(1)

            Spacer(minLength: 12)

            InlineStatusIconButton(systemImage: "pencil", help: "Edit objective") {}
                .disabled(true)
            InlineStatusIconButton(systemImage: "pause.circle", help: "Pause", action: onInterrupt)
            InlineStatusIconButton(systemImage: "trash", help: "Clear") {}
                .disabled(true)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(theme.colors.surface.opacity(0.88))
        .overlay(Rectangle().stroke(theme.colors.border, lineWidth: 1))
        .accessibilityLabel(activity?.title ?? "Codex is working")
    }

    private var title: String {
        activity?.title ?? "Codex is working"
    }

    private var detail: String? {
        guard let activity else { return nil }
        let value = activity.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct InlineStatusIconButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
