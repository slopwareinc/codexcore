import SwiftUI
import CodexCore

/// A compact card for app-server notices, warnings, model routing, and auto-review lifecycle.
public struct CodexNoticeCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let notice: CodexChatMessage.Notice

    @State private var expanded = false
    @State private var copied = false

    public init(notice: CodexChatMessage.Notice) {
        self.notice = notice
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $expanded,
            background: theme.colors.surface.opacity(0.72),
            border: color.opacity(0.42),
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button {
                guard isExpandable else { return }
                toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName)
                        .font(theme.fonts.chat)
                        .foregroundStyle(color)
                        .frame(width: 16, height: 18)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.title)
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                        Text(notice.detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: isExpanded)
                    }

                    Spacer(minLength: 8)

                    CodexNoticeStatusChip(notice: notice)

                    Image(systemName: "chevron.down")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .opacity(isExpandable ? 1 : 0.25)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(notice.metadata.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)

            if !notice.copyText.isEmpty {
                HStack {
                    Text(notice.kind)
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    CodexCopyButton(copied: $copied) { copyToPasteboard(notice.copyText) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.colors.surfaceElevated.opacity(0.45))
            }
        }
    }

    private var isExpandable: Bool {
        !notice.metadata.isEmpty || !notice.copyText.isEmpty
    }

    private var iconName: String {
        switch notice.severity {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch notice.severity {
        case .info: return theme.colors.accent
        case .success: return theme.colors.success
        case .warning: return theme.colors.warning
        case .danger: return theme.colors.danger
        }
    }
}

private struct CodexNoticeStatusChip: View {
    @Environment(\.codexAgentTheme) private var theme

    let notice: CodexChatMessage.Notice

    var body: some View {
        CodexStatusChip(color: color, label: notice.statusLabel, isStreaming: notice.isStreaming)
    }

    private var color: Color {
        if notice.isStreaming { return theme.colors.running }
        switch notice.severity {
        case .info: return theme.colors.accent
        case .success: return theme.colors.success
        case .warning: return theme.colors.warning
        case .danger: return theme.colors.danger
        }
    }
}

