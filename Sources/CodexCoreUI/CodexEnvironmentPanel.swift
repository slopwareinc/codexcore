import SwiftUI

public struct CodexProjectEnvironmentPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    @State private var session: CodexProjectEnvironmentPanelSession
    @State private var isPresentingHandoff = false
    @State private var isPerformingHandoff = false

    private let threadTitle: String
    private let performHandoff: @Sendable (CodexWorktreeHandoffModalState, CodexProjectEnvironmentState) async -> CodexWorktreeHandoffCompletion

    public init(
        environment: CodexProjectEnvironmentState,
        threadTitle: String,
        performHandoff: @escaping @Sendable (CodexWorktreeHandoffModalState, CodexProjectEnvironmentState) async -> CodexWorktreeHandoffCompletion = { modal, environment in
            await CodexWorktreeHandoffSession.perform(
                modal: modal,
                environment: environment,
                provider: CodexUnsupportedWorktreeHandoffProvider()
            )
        }
    ) {
        self._session = State(initialValue: CodexProjectEnvironmentPanelSession(environment: environment))
        self.threadTitle = threadTitle
        self.performHandoff = performHandoff
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Environment", selection: $session.environment.selection) {
                ForEach(CodexProjectEnvironmentSelection.allCases, id: \.self) { selection in
                    Text(selection.title).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Environment")

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

            Button(action: presentHandoff) {
                Label("Create environment", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Create a worktree environment")
        }
        .sheet(isPresented: $isPresentingHandoff) {
            if session.modal != nil {
                CodexWorktreeHandoffSheet(
                    modal: modalBinding,
                    isPerforming: isPerformingHandoff,
                    onCancel: { isPresentingHandoff = false },
                    onHandOff: performCurrentHandoff
                )
                .environment(\.codexAgentTheme, theme)
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

    private var modalBinding: Binding<CodexWorktreeHandoffModalState> {
        Binding(
            get: {
                session.modal ?? CodexWorktreeHandoffModalState(
                    threadTitle: threadTitle,
                    sourcePath: session.environment.workspacePath,
                    targetPath: CodexProjectEnvironmentPanelSession.defaultTargetPath(
                        sourcePath: session.environment.workspacePath,
                        threadTitle: threadTitle
                    )
                )
            },
            set: { session.modal = $0 }
        )
    }

    private func presentHandoff() {
        session.prepareModal(threadTitle: threadTitle)
        isPresentingHandoff = true
    }

    private func performCurrentHandoff() {
        guard let modal = session.modal, modal.isValid, !isPerformingHandoff else { return }
        isPerformingHandoff = true
        Task {
            let completion = await performHandoff(modal, session.environment)
            await MainActor.run {
                session.apply(completion)
                isPerformingHandoff = false
                isPresentingHandoff = false
            }
        }
    }
}

private struct CodexWorktreeHandoffSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var modal: CodexWorktreeHandoffModalState
    let isPerforming: Bool
    let onCancel: () -> Void
    let onHandOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Worktree handoff")
                .font(theme.fonts.body.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                field("Title", text: $modal.title)
                field("Branch", text: $modal.branchName)
                field("Source", text: $modal.sourcePath)
                field("Path", text: $modal.targetPath)
            }

            if !modal.validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(modal.validationErrors, id: \.self) { error in
                        Text(error.message)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.danger)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isPerforming ? "Handing off..." : "Hand off", action: onHandOff)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!modal.isValid || isPerforming)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(theme.colors.surface)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(theme.fonts.chat)
        }
    }
}
