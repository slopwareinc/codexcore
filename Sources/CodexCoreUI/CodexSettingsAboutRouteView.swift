import SwiftUI

public struct CodexSettingsAboutRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let metadata: CodexAboutMetadata
    @Binding private var sidebarFontSize: Double
    private let sidebarFontSizeRange: ClosedRange<Double>

    public init(
        metadata: CodexAboutMetadata,
        sidebarFontSize: Binding<Double> = .constant(CodexAgentTheme.Fonts.SidebarTypography.defaultBaseTextSize),
        sidebarFontSizeRange: ClosedRange<Double> = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    ) {
        self.metadata = metadata
        self._sidebarFontSize = sidebarFontSize
        self.sidebarFontSizeRange = sidebarFontSizeRange
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)

                CodexSidebarFontSizeControl(
                    fontSize: $sidebarFontSize,
                    range: sidebarFontSizeRange
                )
            }
            .padding(14)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

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

public struct CodexSidebarFontSizeControl: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var fontSize: Double
    private let range: ClosedRange<Double>

    public init(
        fontSize: Binding<Double>,
        range: ClosedRange<Double> = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    ) {
        self._fontSize = fontSize
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sidebar font")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("\(Int(fontSize.rounded())) px")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            Slider(value: $fontSize, in: range, step: 1)
                .frame(width: 180)
        }
    }
}
