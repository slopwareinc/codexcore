import SwiftUI

public struct CodexSettingsAboutRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let metadata: CodexAboutMetadata

    public init(metadata: CodexAboutMetadata) {
        self.metadata = metadata
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: CodexAppRoute.settingsAbout.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("About Codex")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(metadata.appName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.colors.textSecondary)
                Text(metadata.versionLine)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                Text(metadata.copyright)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(14)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Text("Detailed Settings/Profile tabs were not reachable in current-app evidence, so this route is limited to About and app boundary information.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)

            if let serverName = metadata.serverName {
                Text(serverName)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
    }
}
