import SwiftUI

public struct CodexMCPStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    public let servers: [CodexMCPServerStatus]
    public let isLoading: Bool
    public let errorMessage: String?
    public let onClose: () -> Void
    public let onRefresh: () -> Void

    public init(
        servers: [CodexMCPServerStatus],
        isLoading: Bool,
        errorMessage: String?,
        onClose: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.servers = servers
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onClose = onClose
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("MCP servers")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if isLoading {
                HStack(spacing: 8) {
                    CodexSpinner(size: .small)
                    Text("Loading")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            } else if let error = errorMessage {
                Text(error)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            } else if servers.isEmpty {
                Text("No MCP servers")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(servers) { server in
                        MCPServerStatusRow(server: server)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 330)
        }
        .padding(18)
        .frame(width: 560, height: 460)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .sheet
        )
    }
}

private struct MCPServerStatusRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let server: CodexMCPServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                Text(server.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let version = server.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                    Text(version)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(server.authStatusLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(server.startupStatus ?? "ready")
                    .font(theme.fonts.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Text(server.inventorySummary)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                if let error = server.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    Text(error)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.danger)
                        .lineLimit(1)
                }
            }

            if !previewEntries.isEmpty {
                Text(previewEntries.joined(separator: " · "))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            } else if let detail = server.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private var statusImage: String {
        switch server.startupStatus {
        case "failed":
            return "exclamationmark.triangle.fill"
        case "starting":
            return "clock"
        case "cancelled":
            return "minus.circle"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch server.startupStatus {
        case "failed":
            return theme.colors.danger
        case "starting":
            return theme.colors.textSecondary
        case "cancelled":
            return theme.colors.textTertiary
        default:
            return theme.colors.success
        }
    }

    private var previewEntries: [String] {
        Array((server.tools + server.resources + server.resourceTemplates).prefix(4).map(\.displayName))
    }
}
