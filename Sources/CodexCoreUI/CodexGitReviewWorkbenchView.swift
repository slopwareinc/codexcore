import SwiftUI
import CodexCore

struct CodexGitReviewWorkbenchHost: View {
    @State private var workbench: CodexGitReviewWorkbench
    let onStartReview: (CodexReviewTarget) -> Void

    init(
        workspaceURL: URL,
        lastTurnSession: CodexGitReviewSession?,
        onStartReview: @escaping (CodexReviewTarget) -> Void
    ) {
        _workbench = State(initialValue: CodexGitReviewWorkbench(
            workspaceURL: workspaceURL,
            lastTurnSession: lastTurnSession
        ))
        self.onStartReview = onStartReview
    }

    var body: some View {
        CodexGitReviewWorkbenchView(
            workbench: workbench,
            onStartReview: onStartReview
        )
    }
}

public struct CodexGitReviewWorkbenchView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable private var workbench: CodexGitReviewWorkbench
    @State private var showsCommit = false
    @State private var showsBranch = false
    @State private var showsPullRequest = false
    @State private var showsAIReview = false
    @State private var confirmsRevert = false
    @State private var reviewTargetChoice = ReviewTargetChoice.uncommitted
    @State private var reviewTargetValue = ""
    private let onStartReview: (CodexReviewTarget) -> Void

    public init(
        workbench: CodexGitReviewWorkbench,
        onStartReview: @escaping (CodexReviewTarget) -> Void = { _ in }
    ) {
        self.workbench = workbench
        self.onStartReview = onStartReview
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(theme.colors.border)
                statusArea
                if proxy.size.width >= 520 {
                    HSplitView {
                        fileNavigator
                            .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
                        diffPane
                            .frame(minWidth: 300)
                    }
                } else {
                    compactFileNavigator
                    Divider().overlay(theme.colors.border)
                    diffPane
                }
            }
        }
        .background(theme.colors.canvas)
        .onMoveCommand(perform: moveSelection)
        .alert("Revert tracked changes?", isPresented: $confirmsRevert) {
            Button("Cancel", role: .cancel) {}
            Button("Revert", role: .destructive) {
                workbench.revertSelectedTrackedFile()
            }
        } message: {
            Text("This restores the selected tracked file from Git. Untracked files are never deleted by Review.")
        }
        .popover(isPresented: $showsCommit) { commitPopover }
        .popover(isPresented: $showsBranch) { branchPopover }
        .popover(isPresented: $showsPullRequest) { pullRequestPopover }
        .popover(isPresented: $showsAIReview) { aiReviewPopover }
        .task {
            if workbench.source != .lastTurn {
                workbench.refresh()
            }
        }
        .onDisappear {
            workbench.cancelAll()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Review source", selection: Binding(
                get: { workbench.source },
                set: { workbench.selectSource($0) }
            )) {
                ForEach(CodexGitReviewSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("codex.review.source")

            if let stats = workbench.snapshot?.diffStats {
                Text("\(stats.changedFiles)")
                    .foregroundStyle(theme.colors.textSecondary)
                Text("+\(stats.addedLines)")
                    .foregroundStyle(theme.colors.success)
                Text("-\(stats.removedLines)")
                    .foregroundStyle(theme.colors.danger)
            }

            Spacer(minLength: 4)

            if workbench.source != .lastTurn {
                Button {
                    workbench.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(workbench.loadState == .loading)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Refresh review (⇧⌘R)")
                .accessibilityLabel("Refresh review")
            }

            Button {
                reviewTargetChoice = workbench.source == .branch ? .baseBranch : .uncommitted
                reviewTargetValue = workbench.source == .branch
                    ? (workbench.snapshot?.upstreamBranchName ?? "main")
                    : ""
                showsAIReview = true
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .help("Start AI code review…")
            .accessibilityLabel("Start AI code review")

            Menu {
                Button("Commit…") { showsCommit = true }
                    .disabled(workbench.source == .lastTurn)
                Button("Branch…") { showsBranch = true }
                    .disabled(workbench.source == .lastTurn)
                Button("Push") { workbench.push() }
                    .disabled(
                        workbench.source == .lastTurn
                            || workbench.actionState?.isPushEnabled != true
                    )
                Divider()
                Button("Create draft PR…") { showsPullRequest = true }
                    .disabled(
                        workbench.source == .lastTurn
                            || workbench.actionState?.isCreatePullRequestEnabled != true
                    )
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .help("Git actions")
            .accessibilityLabel("Git actions")
        }
        .font(theme.fonts.caption)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var statusArea: some View {
        switch workbench.loadState {
        case .loading:
            progressRow(title: "Refreshing repository…", cancellable: false)
        case .failed(let message):
            loadErrorRow(message)
        case .idle, .ready:
            EmptyView()
        }

        if let operationTitle = workbench.operationTitle {
            progressRow(title: operationTitle, cancellable: true)
        } else if let error = workbench.operationError {
            noticeRow(error, systemImage: "xmark.octagon", isError: true)
        } else if let message = workbench.operationMessage {
            noticeRow(message, systemImage: "checkmark.circle", isError: false)
        }
    }

    private func loadErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Retry") {
                workbench.refresh()
            }
            .buttonStyle(.borderless)
        }
        .font(theme.fonts.caption)
        .foregroundStyle(theme.colors.danger)
        .padding(10)
        .background(theme.colors.danger.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private func progressRow(title: String, cancellable: Bool) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title)
            Spacer()
            if cancellable {
                Button("Cancel") { workbench.cancelOperation() }
                    .buttonStyle(.plain)
            }
        }
        .font(theme.fonts.caption)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(theme.colors.accentSoft)
        .accessibilityElement(children: .combine)
    }

    private func noticeRow(
        _ message: String,
        systemImage: String,
        isError: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                workbench.dismissOperationMessage()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(theme.fonts.caption)
        .foregroundStyle(isError ? theme.colors.danger : theme.colors.textSecondary)
        .padding(10)
        .background(
            (isError ? theme.colors.danger : theme.colors.success).opacity(0.08)
        )
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(theme.colors.border)
            if workbench.files.isEmpty {
                emptyFiles
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(workbench.files) { file in
                            fileRow(file)
                        }
                    }
                    .padding(6)
                }
                .accessibilityIdentifier("codex.review.file-list")
            }
            Divider().overlay(theme.colors.border)
            HStack {
                Text("\(workbench.viewedCount)/\(workbench.snapshot?.files.count ?? 0) viewed")
                Spacer()
                Text("↑↓ navigate")
            }
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            .padding(8)
        }
        .background(theme.colors.surface.opacity(0.55))
    }

    private var compactFileNavigator: some View {
        VStack(spacing: 6) {
            searchField
            if !workbench.files.isEmpty {
                Picker("Changed file", selection: Binding(
                    get: { workbench.selectedFileID ?? workbench.files.first?.id ?? "" },
                    set: { workbench.selectFile(id: $0) }
                )) {
                    ForEach(workbench.files) { file in
                        Text(file.path).tag(file.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("codex.review.compact-file-picker")
            }
        }
        .padding(8)
        .background(theme.colors.surface.opacity(0.55))
    }

    private var searchField: some View {
        TextField("Filter changed files", text: $workbench.filter)
            .textFieldStyle(.roundedBorder)
            .font(theme.fonts.caption)
            .padding(8)
            .onMoveCommand(perform: moveSelection)
            .onKeyPress(.upArrow) {
                workbench.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                workbench.moveSelection(1)
                return .handled
            }
            .accessibilityIdentifier("codex.review.file-filter")
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: workbench.moveSelection(-1)
        case .down: workbench.moveSelection(1)
        default: break
        }
    }

    private var emptyFiles: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
            Text(workbench.filter.isEmpty
                 ? workbench.source.emptyTitle
                 : "No files match “\(workbench.filter)”")
                .font(theme.fonts.caption.weight(.semibold))
                .multilineTextAlignment(.center)
            if workbench.source != .branch {
                Button("View branch changes") {
                    workbench.selectSource(.branch)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .foregroundStyle(theme.colors.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func fileRow(_ file: CodexGitReviewFileChange) -> some View {
        let selected = workbench.selectedFileID == file.id
        return HStack(spacing: 7) {
            Button {
                workbench.toggleViewed(file.id)
            } label: {
                Image(systemName: workbench.viewedFileIDs.contains(file.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        workbench.viewedFileIDs.contains(file.id)
                            ? theme.colors.success : theme.colors.textTertiary
                    )
            }
            .buttonStyle(.plain)
            .help(workbench.viewedFileIDs.contains(file.id) ? "Mark unviewed" : "Mark viewed")

            Button {
                workbench.selectFile(id: file.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(theme.colors.textPrimary)
                    HStack(spacing: 5) {
                        Text(file.status.title)
                        if file.stagingState == .partiallyStaged {
                            Text("Partial")
                        } else if file.stagingState == .staged {
                            Text("Staged")
                        }
                        Spacer()
                        Text("+\(file.addedLines)")
                            .foregroundStyle(theme.colors.success)
                        Text("-\(file.removedLines)")
                            .foregroundStyle(theme.colors.danger)
                    }
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            selected ? theme.colors.accentSoft : .clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            selectedFileHeader
            Divider().overlay(theme.colors.border)
            switch workbench.patchState {
            case .idle:
                if workbench.files.isEmpty {
                    emptyDiff(
                        title: workbench.source.emptyTitle,
                        detail: workbench.emptyDetail
                    )
                } else {
                    emptyDiff(
                        title: "Select a file",
                        detail: "Choose a changed file to inspect its patch."
                    )
                }
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading bounded patch…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(theme.colors.textSecondary)
            case .failed(let message):
                emptyDiff(title: "Diff unavailable", detail: message)
            case .ready(let patch):
                CodexUnifiedReviewDiff(
                    patch: patch.displayText,
                    isTruncated: patch.isTruncated
                )
            }
        }
    }

    @ViewBuilder
    private var selectedFileHeader: some View {
        if let file = workbench.selectedFile {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .font(theme.fonts.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let previousPath = file.previousPath {
                        Text("renamed from \(previousPath)")
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if workbench.canMutateSelectedFile {
                    if file.stagingState.hasUnstagedChanges {
                        Button(file.stagingState == .partiallyStaged ? "Stage all" : "Stage") {
                            workbench.stageSelected()
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    if file.stagingState.hasStagedChanges {
                        Button(file.stagingState == .partiallyStaged ? "Unstage all" : "Unstage") {
                            workbench.unstageSelected()
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    if file.status != .untracked {
                        Button {
                            confirmsRevert = true
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Revert tracked changes…")
                        .accessibilityLabel("Revert tracked changes")
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
        } else {
            Text("No file selected")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func emptyDiff(title: String, detail: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "doc.text.magnifyingglass",
            description: Text(detail)
        )
    }

    private var commitPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit changes")
                .font(theme.fonts.body.weight(.semibold))
            TextField("Commit message", text: $workbench.commitMessage)
                .textFieldStyle(.roundedBorder)
            Toggle("Include unstaged changes", isOn: $workbench.includeUnstaged)
            HStack {
                Button("Cancel") { showsCommit = false }
                Spacer()
                Button("Commit and push") {
                    showsCommit = false
                    workbench.commitAndPush()
                }
                .disabled(workbench.actionState?.isCommitAndPushEnabled != true)
                Button("Commit") {
                    showsCommit = false
                    workbench.commit()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(workbench.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var branchPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Branches")
                .font(theme.fonts.body.weight(.semibold))
            ForEach(workbench.snapshot?.branchPicker.options ?? [], id: \.branchName) { option in
                Button {
                    showsBranch = false
                    workbench.checkoutBranch(option.branchName)
                } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if option.isCurrent { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .disabled(option.isCurrent || !(workbench.snapshot?.branchPicker.canCreateOrCheckout ?? false))
            }
            Divider()
            TextField("New branch name", text: $workbench.branchName)
                .textFieldStyle(.roundedBorder)
            Button("Create and switch") {
                showsBranch = false
                workbench.createBranch()
            }
            .disabled(
                workbench.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(workbench.snapshot?.branchPicker.canCreateOrCheckout ?? false)
            )
            if let reason = workbench.snapshot?.branchPicker.createOrCheckoutDisabledReason {
                Text(reason)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.warning)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var pullRequestPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create draft pull request")
                .font(theme.fonts.body.weight(.semibold))
            TextField("Title", text: $workbench.pullRequestTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $workbench.pullRequestBody)
                .font(theme.fonts.chat)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.colors.border))
            Text("Draft is the safe default. Review never merges automatically.")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
            HStack {
                Button("Cancel") { showsPullRequest = false }
                Spacer()
                Button("Create draft") {
                    showsPullRequest = false
                    workbench.createDraftPullRequest()
                }
                .disabled(workbench.pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var aiReviewPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI code review")
                .font(theme.fonts.body.weight(.semibold))
            Picker("Target", selection: $reviewTargetChoice) {
                ForEach(ReviewTargetChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            if reviewTargetChoice != .uncommitted {
                TextField(reviewTargetChoice.placeholder, text: $reviewTargetValue)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Findings appear as structured review cards in the conversation.")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)

            HStack {
                Button("Cancel") { showsAIReview = false }
                Spacer()
                Button("Start review") {
                    let target = reviewTargetChoice.target(value: reviewTargetValue)
                    showsAIReview = false
                    onStartReview(target)
                }
                .disabled(
                    reviewTargetChoice != .uncommitted
                        && reviewTargetValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private enum ReviewTargetChoice: String, CaseIterable, Identifiable {
    case uncommitted
    case baseBranch
    case commit
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommitted: "Uncommitted changes"
        case .baseBranch: "Compare with base branch"
        case .commit: "Specific commit"
        case .custom: "Custom instructions"
        }
    }

    var placeholder: String {
        switch self {
        case .uncommitted: ""
        case .baseBranch: "Base branch, e.g. main"
        case .commit: "Commit SHA"
        case .custom: "Review instructions"
        }
    }

    func target(value: String) -> CodexReviewTarget {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch self {
        case .uncommitted: .uncommittedChanges
        case .baseBranch: .baseBranch(value)
        case .commit: .commit(sha: value)
        case .custom: .custom(value)
        }
    }
}

private struct CodexUnifiedReviewDiff: View {
    @Environment(\.codexAgentTheme) private var theme

    struct Row: Identifiable {
        enum Kind { case header, context, add, remove }
        let id: Int
        let oldLine: Int?
        let newLine: Int?
        let text: String
        let kind: Kind
    }

    let patch: String
    let isTruncated: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text(row.oldLine.map(String.init) ?? "")
                            .frame(width: 42, alignment: .trailing)
                        Text(row.newLine.map(String.init) ?? "")
                            .frame(width: 42, alignment: .trailing)
                        Text(verbatim: row.text)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                    }
                    .font(theme.fonts.code)
                    .foregroundStyle(foreground(row.kind))
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(row.kind))
                    .accessibilityLabel(accessibilityLabel(row))
                }
                if isTruncated {
                    Label("Preview bounded at 256 KiB; narrow the source or file to continue.", systemImage: "ellipsis.rectangle")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.warning)
                        .padding(12)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(theme.colors.codeBackground)
        .accessibilityIdentifier("codex.review.unified-diff")
    }

    private var rows: [Row] {
        var result: [Row] = []
        result.reserveCapacity(min(2_048, patch.count / 20))
        var oldLine = 0
        var newLine = 0
        for (index, line) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if text.hasPrefix("@@") {
                let starts = Self.hunkStarts(text)
                oldLine = starts.old
                newLine = starts.new
                result.append(.init(id: index, oldLine: nil, newLine: nil, text: text, kind: .header))
            } else if text.hasPrefix("+"), !text.hasPrefix("+++") {
                result.append(.init(id: index, oldLine: nil, newLine: newLine, text: text, kind: .add))
                newLine += 1
            } else if text.hasPrefix("-"), !text.hasPrefix("---") {
                result.append(.init(id: index, oldLine: oldLine, newLine: nil, text: text, kind: .remove))
                oldLine += 1
            } else {
                let isFileHeader = text.hasPrefix("diff --git") || text.hasPrefix("---") || text.hasPrefix("+++")
                result.append(.init(
                    id: index,
                    oldLine: isFileHeader ? nil : oldLine,
                    newLine: isFileHeader ? nil : newLine,
                    text: text,
                    kind: isFileHeader ? .header : .context
                ))
                if !isFileHeader {
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        return result
    }

    private static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        let fields = header.split(separator: " ")
        func start(prefix: Character) -> Int {
            guard let value = fields.first(where: { $0.first == prefix }) else { return 0 }
            return Int(value.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(prefix: "-"), start(prefix: "+"))
    }

    private func foreground(_ kind: Row.Kind) -> Color {
        switch kind {
        case .header: theme.colors.accent
        case .context: theme.colors.codeText
        case .add: theme.colors.success
        case .remove: theme.colors.danger
        }
    }

    private func background(_ kind: Row.Kind) -> Color {
        switch kind {
        case .header: theme.colors.accentSoft.opacity(0.55)
        case .context: .clear
        case .add: theme.colors.success.opacity(0.10)
        case .remove: theme.colors.danger.opacity(0.10)
        }
    }

    private func accessibilityLabel(_ row: Row) -> String {
        let line = row.newLine ?? row.oldLine
        let prefix: String = switch row.kind {
        case .header: "Diff header"
        case .context: "Context"
        case .add: "Added"
        case .remove: "Removed"
        }
        return line.map { "\(prefix), line \($0), \(row.text)" } ?? "\(prefix), \(row.text)"
    }
}
