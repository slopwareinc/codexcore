import SwiftUI

/// Native SwiftUI table renderer built on `Grid` / `GridRow`.
///
/// Tables in chat are simple — alignment, a header row, and inline
/// formatting (bold, code) in cells. `Grid` lays them out natively,
/// so they scroll at the same speed as prose and never cost a
/// markdown walk.
@MainActor
public struct CodexTableBlockView: View, Equatable {
    @Environment(\.codexAgentTheme) private var theme

    public let model: CodexTableModel

    public init(model: CodexTableModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { _, column in
                        Text(verbatim: column.header)
                            .font(theme.fonts.label)
                            .foregroundStyle(theme.colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(for: column.alignment))
                            .gridColumnAlignment(horizontalAlignment(for: column.alignment))
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(model.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { cellIndex, cell in
                            cellView(cell, rowIndex: rowIndex, cellIndex: cellIndex, alignment: model.columns[safe: cellIndex]?.alignment ?? .leading)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.colors.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func cellView(_ cell: String, rowIndex: Int, cellIndex: Int, alignment: CodexTableModel.Column.Alignment) -> some View {
        let cellAttributed = model.attributedRows[safe: rowIndex]?[safe: cellIndex] ?? AttributedString(cell)
        Text(CodexProseCache.styledAttributedString(for: cellAttributed, digest: "\(model.digest):\(rowIndex):\(cellIndex)", baseFont: theme.fonts.chat, baseNSFont: theme.fonts.chatNSFont, theme: theme))
            .foregroundStyle(theme.colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: frameAlignment(for: alignment))
            .gridColumnAlignment(horizontalAlignment(for: alignment))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func frameAlignment(for alignment: CodexTableModel.Column.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func horizontalAlignment(for alignment: CodexTableModel.Column.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    nonisolated public static func == (lhs: CodexTableBlockView, rhs: CodexTableBlockView) -> Bool {
        lhs.model.digest == rhs.model.digest
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

