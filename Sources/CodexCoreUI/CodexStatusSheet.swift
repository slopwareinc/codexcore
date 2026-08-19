import SwiftUI

public struct CodexStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    public let model: CodexStatusPanelModel
    public let onClose: () -> Void
    public let onRefreshThreadUsage: (() -> Void)?

    public init(
        model: CodexStatusPanelModel,
        onClose: @escaping () -> Void,
        onRefreshThreadUsage: (() -> Void)? = nil
    ) {
        self.model = model
        self.onClose = onClose
        self.onRefreshThreadUsage = onRefreshThreadUsage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(theme.fonts.panelTitle)
                    .foregroundStyle(theme.colors.textSecondary)
                Text("Status")
                    .font(theme.fonts.sheetTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            LabeledContent("Chat ID", value: model.sessionID)
            LabeledContent("Connection", value: model.connectionLabel)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.contextUsedLabel)
                    Spacer()
                    Text(model.contextLeftLabel)
                }
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)

                ProgressView(value: model.contextFraction)
                    .tint(theme.colors.accent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Estimated thread usage")
                        .font(theme.fonts.label)
                    Spacer()
                    Button {
                        onRefreshThreadUsage?()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoadingThreadUsage || onRefreshThreadUsage == nil)
                    .help("Refresh thread usage")
                }
                if let usage = model.threadUsage {
                    HStack {
                        Text(usage.creditsLabel)
                        Spacer()
                        if let usdLabel = usage.usdLabel { Text(usdLabel) }
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    ForEach(usage.groups) { group in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title).font(theme.fonts.caption)
                                if !group.detail.isEmpty {
                                    Text(group.detail)
                                        .font(theme.fonts.micro)
                                        .foregroundStyle(theme.colors.textTertiary)
                                }
                            }
                            Spacer()
                            Text(group.credits)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textSecondary)
                        }
                    }
                } else if let error = model.threadUsageError {
                    Text(error)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                } else {
                    Text(model.isLoadingThreadUsage ? "Loading estimate…" : "Estimate unavailable for this workspace")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(11)
            .background(
                theme.colors.surfaceElevated.opacity(0.78),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(model.rateLimitRows) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(row.title)
                                .font(theme.fonts.label)
                                .foregroundStyle(theme.colors.textPrimary)
                            Spacer()
                            Text(row.usedLabel)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textSecondary)
                        }
                        ProgressView(value: row.fraction)
                            .tint(theme.colors.accent)
                        Text(row.resetLabel)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                    .padding(11)
                    .background(
                        theme.colors.surfaceElevated.opacity(0.78),
                        in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                            .stroke(theme.colors.border, lineWidth: 1)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 500)
        .task { onRefreshThreadUsage?() }
    }
}
