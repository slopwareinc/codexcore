import SwiftUI

/// Live-turn activity lines — text only, no bordered card chrome.
public struct CodexOperationSummaryCard: View {
    @Environment(\.codexAgentTheme) private var theme

    private let rows: [CodexLiveTurnOperationRow]

    public init(rows: [CodexLiveTurnOperationRow]) {
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                Text(row.title)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        .accessibilityLabel(rows.map(\.title).joined(separator: ", "))
    }
}
