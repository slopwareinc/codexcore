import SwiftUI

/// Compact live-turn operation summary rows for command/read/edit/test activity.
public struct CodexOperationSummaryCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let rows: [CodexLiveTurnOperationRow]

    public init(rows: [CodexLiveTurnOperationRow]) {
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: row.title))
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(width: 16, height: 16)

                    Text(row.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary.opacity(0.72))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.colors.surfaceElevated.opacity(0.18))
                if row.id != rows.last?.id {
                    Rectangle()
                        .fill(theme.colors.border.opacity(0.58))
                        .frame(height: 1)
                        .padding(.leading, 34)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border.opacity(0.72), lineWidth: 1)
        )
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .accessibilityLabel(rows.map(\.title).joined(separator: ", "))
    }

    private func icon(for title: String) -> String {
        let normalized = title.lowercased()
        if normalized.hasPrefix("read ") { return "doc.text.magnifyingglass" }
        if normalized.hasPrefix("edited ") || normalized.hasPrefix("created ") { return "square.and.pencil" }
        if normalized.hasPrefix("listed ") { return "folder" }
        if normalized.contains("test") { return "checkmark.circle" }
        return "terminal"
    }
}
