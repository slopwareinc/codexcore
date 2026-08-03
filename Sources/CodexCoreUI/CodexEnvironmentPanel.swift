import SwiftUI

public struct CodexProjectEnvironmentPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    @State private var session: CodexProjectEnvironmentPanelSession
    @State private var repositorySnapshot: CodexProjectEnvironmentRepositorySnapshot?
    @State private var isBusy = false
    private let threadTitle: String
    private let provider: any CodexProjectEnvironmentProviding
    private let onCompletion: @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void

    public init(
        environment: CodexProjectEnvironmentState,
        threadTitle: String,
        provider: any CodexProjectEnvironmentProviding = CodexUnsupportedProjectEnvironmentProvider(),
        onCompletion: @escaping @MainActor @Sendable (CodexWorktreeHandoffCompletion) -> Void = { _ in }
    ) {
        self._session = State(initialValue: CodexProjectEnvironmentPanelSession(environment: environment))
        self.threadTitle = threadTitle
        self.provider = provider
        self.onCompletion = onCompletion
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            environmentMenu
            branchMenu

            Button {
                prepareHandoff()
            } label: {
                Label("Create environment", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(EnvironmentRowButtonStyle(theme: theme))
            .disabled(isBusy)
            .help("Create a branch in a new Git worktree")
            .accessibilityHint("Opens the worktree handoff form")

            if let usage = session.environment.usageRemainingLabel?.nilIfBlank {
                Label(usage, systemImage: "gauge.with.dots.needle.33percent")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 8)
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating environment")
            }

            if let resultCard = session.resultCard {
                resultCardView(resultCard)
            } else if let activity = session.lastActivity {
                activityView(activity)
            }
        }
        .task { await refreshRepository() }
        .sheet(isPresented: Binding(
            get: { session.modal != nil },
            set: { if !$0 { session.modal = nil } }
        )) {
            if session.modal != nil {
                handoffSheet
            }
        }
    }

    private var environmentMenu: some View {
        Menu {
            Section("Continue in") {
                Button { select(.local) } label: {
                    Label("Work locally", systemImage: "laptopcomputer")
                }
                Button { select(.worktree) } label: {
                    Label("Worktree", systemImage: "square.stack.3d.up")
                }
                Button { select(.cloud) } label: {
                    Label("Cloud", systemImage: "cloud")
                }
            }
            if let usage = session.environment.usageRemainingLabel?.nilIfBlank {
                Section("Usage remaining") { Text(usage) }
            }
        } label: {
            Label(
                session.environment.selection.title,
                systemImage: session.environment.selection == .worktree
                    ? "square.stack.3d.up" : "laptopcomputer"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(EnvironmentRowButtonStyle(theme: theme))
        .help("Select where to run the task")
        .accessibilityLabel("Environment, \(session.environment.selection.title)")
    }

    private var branchMenu: some View {
        Menu {
            if let repositorySnapshot {
                Section("Branches") {
                    ForEach(repositorySnapshot.branches, id: \.self) { branch in
                        Button {
                            Task { await checkout(branch) }
                        } label: {
                            if branch == repositorySnapshot.branchName {
                                Label(branch, systemImage: "checkmark")
                            } else {
                                Text(branch)
                            }
                        }
                        .disabled(branch == repositorySnapshot.branchName || repositorySnapshot.dirtyFileCount > 0)
                    }
                }
                if repositorySnapshot.dirtyFileCount > 0 {
                    Text("Uncommitted: \(repositorySnapshot.dirtyFileCount) files")
                }
                Divider()
                Button("Create and checkout new branch…") { prepareHandoff() }
            } else {
                Text("No branches available")
            }
        } label: {
            Label(
                repositorySnapshot?.branchName ?? session.environment.branchName ?? "No branch",
                systemImage: "arrow.triangle.branch"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(EnvironmentRowButtonStyle(theme: theme))
        .disabled(isBusy || repositorySnapshot == nil)
        .help(repositorySnapshot?.dirtyFileCount ?? 0 > 0
            ? "Commit or hand off uncommitted changes before switching branches"
            : "Switch branch")
        .accessibilityLabel("Branch, \(repositorySnapshot?.branchName ?? "unavailable")")
    }

    private var handoffSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hand off chat to worktree")
                .font(theme.fonts.sheetTitle)
            Text("Create and check out a branch in a new worktree to continue working in parallel.")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textSecondary)

            TextField("Branch name", text: modalBinding(\.branchName))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Branch name")
            TextField("Worktree path", text: modalBinding(\.targetPath))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Worktree path")

            if let error = session.modal?.validationErrors.first {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { session.modal = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Hand off") { Task { await performHandoff() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.modal?.isValid != true || isBusy)
            }
        }
        .padding(theme.spacing.sheetPadding)
        .frame(width: 520)
    }

    private func modalBinding(_ keyPath: WritableKeyPath<CodexWorktreeHandoffModalState, String>) -> Binding<String> {
        Binding(
            get: { session.modal?[keyPath: keyPath] ?? "" },
            set: { session.modal?[keyPath: keyPath] = $0 }
        )
    }

    private func select(_ selection: CodexProjectEnvironmentSelection) {
        switch selection {
        case .local:
            session.environment.selection = .local
            session.lastActivity = nil
            session.resultCard = nil
        case .worktree:
            prepareHandoff()
        case .cloud:
            session.lastActivity = CodexActivity(
                kind: .notice,
                title: "Cloud environment unavailable",
                detail: "This local host has no cloud environment provider configured."
            )
            session.resultCard = nil
        }
    }

    private func prepareHandoff() {
        session.prepareModal(threadTitle: threadTitle)
    }

    @MainActor
    private func refreshRepository() async {
        do {
            repositorySnapshot = try await provider.repositorySnapshot()
            session.environment.branchName = repositorySnapshot?.branchName
        } catch {
            repositorySnapshot = nil
            session.lastActivity = CodexActivity(kind: .notice, title: "Repository unavailable", detail: error.localizedDescription)
        }
    }

    @MainActor
    private func checkout(_ branch: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            repositorySnapshot = try await provider.checkoutBranch(branch)
            session.environment.branchName = repositorySnapshot?.branchName
            session.lastActivity = CodexActivity(kind: .notice, title: "Branch switched", detail: branch)
        } catch {
            session.lastActivity = CodexActivity(kind: .notice, title: "Branch switch failed", detail: error.localizedDescription)
        }
    }

    @MainActor
    private func performHandoff() async {
        guard let modal = session.modal else { return }
        isBusy = true
        let completion = await CodexWorktreeHandoffSession.perform(
            modal: modal,
            environment: session.environment,
            provider: provider
        )
        isBusy = false
        session.apply(completion)
        if completion.resultCard != nil {
            session.modal = nil
        }
        onCompletion(completion)
    }

    private func resultCardView(_ resultCard: CodexWorktreeHandoffResultCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(resultCard.title, systemImage: "checkmark.circle.fill")
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.success)
            Text("You are now working on \(resultCard.branchName) in a new worktree.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(3)
            if !resultCard.pathOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(resultCard.pathOutcomes, id: \.path) { outcome in
                        Text("\(outcome.status.title) · \(outcome.path)")
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small))
        .accessibilityElement(children: .combine)
    }

    private func activityView(_ activity: CodexActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(activity.title).font(theme.fonts.caption.weight(.semibold))
            if !activity.detail.isEmpty {
                Text(activity.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct EnvironmentRowButtonStyle: ButtonStyle {
    let theme: CodexAgentTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.fonts.chat)
            .foregroundStyle(theme.colors.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                configuration.isPressed ? theme.colors.surfaceElevated : Color.clear,
                in: RoundedRectangle(cornerRadius: theme.radii.small)
            )
            .contentShape(Rectangle())
    }
}
