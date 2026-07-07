import SwiftUI

public struct CodexGitReviewPanel: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var session: CodexGitReviewSession
    @State private var isSplitDiff = true
    @State private var areFilesVisible = true

    public init(session: CodexGitReviewSession) {
        self._session = State(initialValue: session)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            fileList
            commitBox
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        let branchPicker = session.snapshot.branchPicker
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(branchPicker.options, id: \.branchName) { option in
                        Button(action: {}) {
                            if option.isCurrent {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                        .disabled(true)
                    }

                    Divider()

                    Button("Create or checkout branch", action: {})
                        .disabled(!branchPicker.canCreateOrCheckout)
                } label: {
                    Label(branchPicker.currentTitle, systemImage: "arrow.triangle.branch")
                        .font(theme.fonts.body.weight(.semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .help(branchPicker.createOrCheckoutDisabledReason ?? "Branch checkout is not wired in this build")
            }

            Text(session.commitStats.summary)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                reviewButton("Review options", systemImage: "slider.horizontal.3")
                reviewButton("Jump to file", systemImage: "arrow.down.doc")
            }
            HStack(spacing: 8) {
                Toggle(isOn: $isSplitDiff) {
                    Text("Split diff")
                        .font(theme.fonts.caption)
                }
                .toggleStyle(.switch)

                Toggle(isOn: $areFilesVisible) {
                    Text("Show files")
                        .font(theme.fonts.caption)
                }
                .toggleStyle(.switch)
            }
            .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)

            if !areFilesVisible {
                Text("Files hidden")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.vertical, 8)
            } else if let empty = session.fileList.emptyState {
                VStack(alignment: .leading, spacing: 4) {
                    Text(empty.title)
                        .font(theme.fonts.chat.weight(.semibold))
                        .foregroundStyle(empty.isMismatch ? theme.colors.warning : theme.colors.textSecondary)
                    Text(empty.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.fileList.files, id: \.path) { file in
                        fileRow(file)
                    }
                }
            }
        }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit or push")
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)

            TextField("Commit message", text: Binding(
                get: { session.commitDraft.message },
                set: { session.setCommitMessage($0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(theme.fonts.chat)
            .lineLimit(2...4)
            .padding(9)
            .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Toggle(isOn: Binding(
                get: { session.commitDraft.includeUnstaged },
                set: { session.setIncludeUnstaged($0) }
            )) {
                Text("Include unstaged")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            .toggleStyle(.switch)

            actionButton("Commit", enabled: session.actionState.isCommitEnabled, reason: session.actionState.commitDisabledReason)
            actionButton("Commit and push", enabled: session.actionState.isCommitAndPushEnabled, reason: session.actionState.commitAndPushDisabledReason)
            actionButton("Push", enabled: session.actionState.isPushEnabled, reason: session.actionState.pushDisabledReason)
            actionButton("Create PR", enabled: session.actionState.isCreatePullRequestEnabled, reason: session.actionState.createPullRequestDisabledReason)
        }
    }

    private func fileRow(_ file: CodexGitReviewFileChange) -> some View {
        HStack(spacing: 8) {
            Text(file.status.title)
                .font(theme.fonts.micro.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(file.path)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            CodexDiffCounter(added: file.addedLines, removed: file.removedLines)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.textDimOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
    }

    private func reviewButton(_ title: String, systemImage: String) -> some View {
        Button(action: {}) {
            Label(title, systemImage: systemImage)
                .font(theme.fonts.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(true)
        .help("\(title) is not wired in this build")
    }

    private func actionButton(_ title: String, enabled: Bool, reason: String?) -> some View {
        Button(action: {}) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(true)
        .help(reason ?? "\(title) is not wired in this build")
        .opacity(enabled ? 1 : 0.72)
    }
}
