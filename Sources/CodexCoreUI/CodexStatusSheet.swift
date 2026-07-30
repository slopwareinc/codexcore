import SwiftUI

public struct CodexStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    public let model: CodexStatusPanelModel
    public let onClose: () -> Void

    public init(model: CodexStatusPanelModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
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
    }
}
