import SwiftUI
import CodexCore
import CodexCoreUI

struct PluginsSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("Plugins")
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

            HStack(spacing: 10) {
                Text("\(model.plugins.filter(\.installed).count) installed")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Text("\(model.plugins.count) total")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                if model.isLoadingPlugins {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = model.pluginErrorMessage {
                Text(error)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            } else if model.plugins.isEmpty, !model.isLoadingPlugins {
                Text("No plugins")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            if !model.pluginLoadErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.pluginLoadErrors, id: \.self) { error in
                        Text(error)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.warning)
                            .lineLimit(2)
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.plugins) { plugin in
                        PluginCatalogRow(plugin: plugin)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 340)
        }
        .padding(18)
        .frame(width: 580, height: 480)
        .background(theme.colors.surface)
    }
}

private struct PluginCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let plugin: CodexPluginSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: plugin.installed ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textTertiary)
                    .frame(width: 18)
                Text(plugin.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let version = plugin.localVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                    Text(version)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(plugin.statusLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textSecondary)
                    .lineLimit(1)
            }

            Text(plugin.detail)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(plugin.marketplaceDisplayName)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                Text(plugin.sourceLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                if let developer = plugin.developerName?.trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
                    Text(developer)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if !plugin.capabilities.isEmpty {
                Text(plugin.capabilities.prefix(4).joined(separator: " · "))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

