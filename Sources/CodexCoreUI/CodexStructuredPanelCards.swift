import SwiftUI

public struct CodexStatusPanelCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let model: CodexStatusPanelModel
    private let onClose: (() -> Void)?

    public init(model: CodexStatusPanelModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        structuredPanel(title: "Status", systemImage: "waveform.path.ecg", onClose: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                infoGrid

                VStack(alignment: .leading, spacing: 8) {
                    panelLabel("Context")
                    progressRow(
                        title: model.contextUsedLabel,
                        detail: model.contextLeftLabel,
                        fraction: model.contextFraction,
                        color: theme.colors.accent
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    panelLabel("Rate limits")
                    ForEach(model.rateLimitRows) { row in
                        progressRow(
                            title: row.title,
                            detail: "\(row.usedLabel) - \(row.resetLabel)",
                            fraction: row.fraction,
                            color: theme.colors.running
                        )
                    }
                }
            }
        }
    }

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            metadataRow("Session", model.sessionID)
            metadataRow("Connection", model.connectionLabel)
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func panelLabel(_ title: String) -> some View {
        Text(title)
            .font(theme.fonts.caption.weight(.semibold))
            .foregroundStyle(theme.colors.textSecondary)
    }

    private func progressRow(title: String, detail: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            GeometryReader { proxy in
                let width = max(0, proxy.size.width * fraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.colors.surfaceSunken.opacity(theme.effects.glassOpacity))
                    Capsule()
                        .fill(color.opacity(0.72))
                        .frame(width: width)
                }
            }
            .frame(height: 6)
        }
    }
}

public struct CodexMCPStatusPanelCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let model: CodexMCPStatusPanelModel
    private let onClose: (() -> Void)?
    private let onOpenDetails: (() -> Void)?

    public init(
        model: CodexMCPStatusPanelModel,
        onClose: (() -> Void)? = nil,
        onOpenDetails: (() -> Void)? = nil
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenDetails = onOpenDetails
    }

    public var body: some View {
        structuredPanel(title: model.title, systemImage: "server.rack", onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)

                if model.rows.isEmpty {
                    Text("No server rows")
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rows) { row in
                            serverRow(row)
                        }
                    }
                }

                if let onOpenDetails {
                    Button(action: onOpenDetails) {
                        Label("Open MCP details", systemImage: "arrow.up.right.square")
                            .font(theme.fonts.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.accent)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func serverRow(_ row: CodexMCPStatusPanelServerRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(row.displayName)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusPill(row.enabledLabel)
            }
            HStack(spacing: 8) {
                Text(row.authLabel)
                Text(row.startupLabel)
                Text(row.inventorySummary)
            }
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.textFaintOpacity), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private func statusPill(_ title: String) -> some View {
        Text(title)
            .font(theme.fonts.micro.weight(.semibold))
            .foregroundStyle(title == "Enabled" ? theme.colors.success : theme.colors.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.colors.surfaceSunken.opacity(theme.effects.glassOpacity), in: Capsule())
    }
}

@MainActor
private func structuredPanel<Content: View>(
    title: String,
    systemImage: String,
    onClose: (() -> Void)?,
    @ViewBuilder content: () -> Content
) -> some View {
    StructuredPanelShell(title: title, systemImage: systemImage, onClose: onClose, content: content())
}

private struct StructuredPanelShell<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let systemImage: String
    let onClose: (() -> Void)?
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 18)
                Text(title)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 8)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(theme.fonts.caption.weight(.bold))
                            .foregroundStyle(theme.colors.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }

            content
        }
        .padding(13)
        .background(theme.colors.surface.opacity(theme.effects.glassOpacity), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
    }
}
