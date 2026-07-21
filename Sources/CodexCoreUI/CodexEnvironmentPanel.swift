import SwiftUI

public struct CodexProjectEnvironmentPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    @State private var session: CodexProjectEnvironmentPanelSession
    public init(
        environment: CodexProjectEnvironmentState,
        threadTitle: String,
        performHandoff: @escaping @Sendable (CodexWorktreeHandoffModalState, CodexProjectEnvironmentState) async -> CodexWorktreeHandoffCompletion = { modal, environment in
            await CodexWorktreeHandoffSession.perform(
                modal: modal,
                environment: environment,
                provider: CodexUnsupportedWorktreeHandoffProvider()
            )
        },
        onCompletion: @escaping @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void = { _ in }
    ) {
        self._session = State(initialValue: CodexProjectEnvironmentPanelSession(environment: environment))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(session.rows, id: \.title) { row in
                    environmentRow(row)
                }
            }

            if let resultCard = session.resultCard {
                resultCardView(resultCard)
            } else if let activity = session.lastActivity {
                activityView(activity)
            }
        }
    }

    private func environmentRow(_ row: CodexProjectEnvironmentPanelRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.title)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 44, alignment: .leading)
            Text(row.value)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultCardView(_ resultCard: CodexWorktreeHandoffResultCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resultCard.title)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text(resultCard.detail)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private func activityView(_ activity: CodexActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(activity.title)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
