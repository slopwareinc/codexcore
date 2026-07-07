import SwiftUI

/// Aggregate file-change card matching the current app's edited-files summary while preserving per-file diff cards below it.
public struct CodexAggregateFileChangeCard: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.codexFileChangeUndo) private var undoHandler
    @Environment(\.codexFileChangeReview) private var reviewHandler

    private let changes: [CodexChatMessage.FileChange]
    @State private var showsAllRows = false

    public init(changes: [CodexChatMessage.FileChange]) {
        self.changes = changes
    }

    public var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.codeFaint)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        if let primaryPath = summary.primaryPath {
                            HStack(spacing: 8) {
                                Text(primaryPath)
                                    .font(theme.fonts.code)
                                    .foregroundStyle(theme.colors.codeText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if let primaryType = summary.primaryType {
                                    Text(primaryType)
                                        .font(theme.fonts.micro)
                                        .foregroundStyle(theme.colors.codeFaint)
                                        .lineLimit(1)
                                }

                                Text("Open in")
                                    .font(theme.fonts.micro)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.colors.surfaceElevated.opacity(0.45), in: Capsule())
                            }
                        }

                        HStack(spacing: 8) {
                            Text(summary.title)
                                .font(theme.fonts.label)
                                .foregroundStyle(theme.colors.textSecondary)
                            Text(summary.addedLabel)
                                .foregroundStyle(theme.colors.success)
                            Text(summary.removedLabel)
                                .foregroundStyle(theme.colors.danger)
                        }
                        .font(theme.fonts.caption)
                    }

                    Spacer(minLength: 12)

                    actionRow(for: summary)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(summary.visibleFileRows) { row in
                        HStack(spacing: 8) {
                            Text(row.path)
                                .font(theme.fonts.code)
                                .foregroundStyle(theme.colors.codeText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            CodexDiffCounter(added: row.addedLineCount, removed: row.removedLineCount)
                        }
                    }

                    if let hiddenRowsTitle = summary.hiddenRowsTitle {
                        Button {
                            withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                                showsAllRows.toggle()
                            }
                        } label: {
                            Text(hiddenRowsTitle)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 28)
            }
            .padding(12)
            .background(theme.colors.codeBackground, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
            .accessibilityLabel(accessibilityLabel(for: summary))
        }
    }

    private var summary: CodexLiveTurnChangeCardSummary? {
        CodexLiveTurnModel.changeCardSummary(
            for: changes,
            visibleRowLimit: showsAllRows ? Int.max : 3
        )
    }

    @ViewBuilder
    private func actionRow(for summary: CodexLiveTurnChangeCardSummary) -> some View {
        HStack(spacing: 8) {
            ForEach(summary.actionTitles, id: \.self) { title in
                Button {
                    performAction(title)
                } label: {
                    Label(title, systemImage: icon(for: title))
                        .font(theme.fonts.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(actionEnabled(title) ? theme.colors.textSecondary : theme.colors.textTertiary)
                .disabled(!actionEnabled(title))
                .help(actionHelp(title))
            }
        }
    }

    private func actionEnabled(_ title: String) -> Bool {
        guard changes.count == 1, let change = changes.first else { return false }
        switch title {
        case "Undo":
            return undoHandler != nil && change.path != nil
        case "Review":
            return reviewHandler != nil
        default:
            return false
        }
    }

    private func performAction(_ title: String) {
        guard changes.count == 1, let change = changes.first else { return }
        switch title {
        case "Undo":
            undoHandler?(change)
        case "Review":
            reviewHandler?(change)
        default:
            break
        }
    }

    private func actionHelp(_ title: String) -> String {
        if changes.count == 1 { return title }
        return "\(title) is available on individual file rows"
    }

    private func icon(for title: String) -> String {
        switch title {
        case "Undo":
            return "arrow.uturn.backward"
        case "Review":
            return "eye"
        default:
            return "circle"
        }
    }

    private func accessibilityLabel(for summary: CodexLiveTurnChangeCardSummary) -> String {
        ([summary.primaryPath, summary.title, summary.addedLabel, summary.removedLabel] + summary.actionTitles)
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
