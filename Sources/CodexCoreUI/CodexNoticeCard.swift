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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { details }
        }
        .background(theme.colors.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(color.opacity(0.42), lineWidth: 1)
        )
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        Button {
            guard isExpandable else { return }
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
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
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: expanded)
                }

                Spacer(minLength: 8)

                CodexNoticeStatusChip(notice: notice)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.textTertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .opacity(isExpandable ? 1 : 0.25)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.colors.border).frame(height: 1)
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
                        .font(.system(size: 10.5, design: .monospaced))
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
        HStack(spacing: 5) {
            if notice.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(notice.statusLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
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

