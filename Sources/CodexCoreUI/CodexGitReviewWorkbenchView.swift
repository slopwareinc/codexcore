import SwiftUI
import CodexCore
import AppKit

struct CodexGitReviewWorkbenchHost: View {
    @State private var workbench: CodexGitReviewWorkbench
    let onStartReview: (CodexReviewTarget) -> Void
    let selectedFilePath: String?
    let onSelectedFilePathChange: (String?) -> Void

    init(
        workspaceURL: URL,
        lastTurnSession: CodexGitReviewSession?,
        selectedFilePath: String? = nil,
        onSelectedFilePathChange: @escaping (String?) -> Void = { _ in },
        onStartReview: @escaping (CodexReviewTarget) -> Void
    ) {
        _workbench = State(initialValue: CodexGitReviewWorkbench(
            workspaceURL: workspaceURL,
            lastTurnSession: lastTurnSession
        ))
        self.selectedFilePath = selectedFilePath
        self.onSelectedFilePathChange = onSelectedFilePathChange
        self.onStartReview = onStartReview
    }

    var body: some View {
        CodexGitReviewWorkbenchView(
            workbench: workbench,
            onStartReview: onStartReview
        )
        .task(id: selectedFilePath) {
            if let selectedFilePath {
                workbench.selectFile(path: selectedFilePath)
            }
        }
        .onChange(of: workbench.selectedFileID) { _, _ in
            onSelectedFilePathChange(workbench.selectedFile?.path)
        }
    }
}

public struct CodexGitReviewWorkbenchView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable private var workbench: CodexGitReviewWorkbench
    @State private var showsCommit = false
    @State private var showsBranch = false
    @State private var showsPullRequest = false
    @State private var showsPullRequestDetails = false
    @State private var showsAIReview = false
    @State private var showsComparison = false
    @State private var revertScope: RevertScope?
    @State private var reviewTargetChoice = ReviewTargetChoice.uncommitted
    @State private var reviewTargetValue = ""
    @State private var wrapsDiffLines = false
    @State private var collapsedDirectoryIDs: Set<String> = []
    @State private var requestedNavigatorWidth: CGFloat = 280
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
                branchBar
                Divider().overlay(theme.colors.border)
                statusArea
                if proxy.size.width >= 560 {
                    // The file tree sits on the trailing edge, next to the
                    // window's other inspectors, so the diff keeps the eye's
                    // starting position.
                    HStack(spacing: 0) {
                        diffPane
                            .frame(maxWidth: .infinity)
                        splitHandle(availableWidth: proxy.size.width)
                        fileNavigator
                            .frame(width: navigatorWidth(availableWidth: proxy.size.width))
                    }
                } else {
                    compactFileNavigator
                    Divider().overlay(theme.colors.border)
                    diffPane
                }
                if workbench.canUseGitActions,
                   workbench.snapshot?.files.isEmpty == false {
                    Divider().overlay(theme.colors.border)
                    bulkActionBar
                }
            }
        }
        .background(theme.colors.canvas)
        .onMoveCommand(perform: moveSelection)
        .alert("Revert tracked changes?", isPresented: Binding(
            get: { revertScope != nil },
            set: { if !$0 { revertScope = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Revert", role: .destructive) {
                if revertScope == .all {
                    workbench.revertAllTrackedFiles()
                } else {
                    workbench.revertSelectedTrackedFile()
                }
                revertScope = nil
            }
        } message: {
            Text(revertScope == .all
                 ? "This restores every tracked file shown in this review source from Git. Untracked files are never deleted by Review."
                 : "This restores the selected tracked file from Git. Untracked files are never deleted by Review.")
        }
        .popover(isPresented: $showsCommit) { commitPopover }
        .popover(isPresented: $showsBranch) { branchPopover }
        .popover(isPresented: $showsPullRequest) { pullRequestPopover }
        .popover(isPresented: $showsPullRequestDetails) { pullRequestDetailsPopover }
        .popover(isPresented: $showsAIReview) { aiReviewPopover }
        .popover(isPresented: $showsComparison) { comparisonPopover }
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
        HStack(spacing: 10) {
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
            .fixedSize()
            .accessibilityIdentifier("codex.review.source")

            if let stats = workbench.snapshot?.diffStats, stats.changedFiles > 0 {
                CodexReviewDiffStat(
                    added: stats.addedLines,
                    removed: stats.removedLines
                )
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            if workbench.source != .lastTurn {
                toolbarIcon(
                    "arrow.clockwise",
                    help: "Refresh review (⇧⌘R)",
                    label: "Refresh review",
                    isDisabled: workbench.loadState == .loading
                ) {
                    workbench.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            toolbarIcon(
                "sparkles",
                help: "Start AI code review…",
                label: "Start AI code review"
            ) {
                reviewTargetChoice = workbench.source == .branch ? .baseBranch : .uncommitted
                reviewTargetValue = workbench.source == .branch
                    ? (workbench.snapshot?.upstreamBranchName ?? "main")
                    : ""
                showsAIReview = true
            }

            Menu {
                Toggle("Wrap lines", isOn: $wrapsDiffLines)
                Button("Copy selected patch") {
                    if case .ready(let patch) = workbench.patchState {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(patch.fullText, forType: .string)
                    }
                }
                .disabled(workbench.selectedPatch == nil)
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diff options")
            .accessibilityLabel("Diff options")

            Menu {
                Button("Commit…") { showsCommit = true }
                    .disabled(!workbench.canUseGitActions)
                Button("Branch…") { showsBranch = true }
                    .disabled(!workbench.canUseGitActions)
                Button("Push") { workbench.push() }
                    .disabled(
                        !workbench.canUseGitActions
                            || workbench.actionState?.isPushEnabled != true
                    )
                Divider()
                Button("Pull request details…") {
                    showsPullRequestDetails = true
                    workbench.loadPullRequest()
                }
                .disabled(
                    !workbench.canUseGitActions
                        || workbench.snapshot?.hasRemoteBranch != true
                )
                Button("Create draft PR…") { showsPullRequest = true }
                    .disabled(
                        !workbench.canUseGitActions
                            || workbench.actionState?.isCreatePullRequestEnabled != true
                    )
            } label: {
                Label("Commit or push", systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(!workbench.canUseGitActions)
            .help("Git actions")
            .accessibilityLabel("Git actions")
        }
        .font(theme.fonts.caption)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// The comparison line: what this review is diffing, and against what.
    @ViewBuilder
    private var branchBar: some View {
        if let snapshot = workbench.snapshot {
            HStack(spacing: 6) {
                Text(snapshot.branchName)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                if let comparisonLabel = workbench.comparisonLabel {
                    Image(systemName: "arrow.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                    Button {
                        showsComparison = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(comparisonLabel).lineLimit(1)
                            Image(systemName: "chevron.down").font(theme.fonts.micro)
                        }
                        .foregroundStyle(theme.colors.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(workbench.source == .branch ? "Choose base branch" : "Choose commit")
                    .accessibilityIdentifier("codex.review.comparison")
                } else if let upstream = snapshot.upstreamBranchName {
                    Image(systemName: "arrow.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                    Text(upstream)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let count = workbench.snapshot?.files.count, count > 0 {
                    Text("\(count) file\(count == 1 ? "" : "s")")
                        .foregroundStyle(theme.colors.textTertiary)
                        .monospacedDigit()
                }
            }
            .font(theme.fonts.micro)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func navigatorWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(200, requestedNavigatorWidth), max(200, availableWidth - 340))
    }

    private func splitHandle(availableWidth: CGFloat) -> some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                requestedNavigatorWidth = min(
                                    420,
                                    max(
                                        200,
                                        navigatorWidth(availableWidth: availableWidth)
                                            - value.translation.width
                                    )
                                )
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
            .accessibilityHidden(true)
    }

    private func toolbarIcon(
        _ systemImage: String,
        help: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(label)
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
            if let url = workbench.operationURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderless)
            }
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
                    LazyVStack(spacing: 1) {
                        ForEach(visibleTreeRows, id: \.node.id) { entry in
                            treeRow(entry.node, depth: entry.depth)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier("codex.review.file-list")
            }
            boundedChangesNotice
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
                        Text(CodexReviewPath.fileName(file.path)).tag(file.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("codex.review.compact-file-picker")
            }
            boundedChangesNotice
        }
        .padding(8)
        .background(theme.colors.surface.opacity(0.55))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Filter files", text: $workbench.filter)
                .textFieldStyle(.plain)
        }
            .font(theme.fonts.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                theme.colors.surfaceSunken,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
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

    @ViewBuilder
    private var boundedChangesNotice: some View {
        if (workbench.snapshot?.ignoredChangeCount ?? 0) > 0 {
            Label(
                "Additional untracked files are hidden to keep Review responsive.",
                systemImage: "exclamationmark.triangle"
            )
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("codex.review.bounded-changes-notice")
        }
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
            if workbench.source != .branch && workbench.source != .committed {
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

    /// Rows currently on screen: the tree, flattened, minus collapsed subtrees.
    private var visibleTreeRows: [(node: CodexReviewFileTreeNode, depth: Int)] {
        CodexReviewFileTreeNode.flatten(
            CodexReviewFileTreeNode.build(workbench.files),
            collapsedIDs: collapsedDirectoryIDs
        )
    }

    @ViewBuilder
    private func treeRow(_ node: CodexReviewFileTreeNode, depth: Int) -> some View {
        switch node.kind {
        case .directory(let children):
            directoryRow(node, children: children, depth: depth)
        case .file(let file):
            fileRow(file, name: node.name, depth: depth)
        }
    }

    private func directoryRow(
        _ node: CodexReviewFileTreeNode,
        children: [CodexReviewFileTreeNode],
        depth: Int
    ) -> some View {
        let collapsed = collapsedDirectoryIDs.contains(node.id)
        return Button {
            if collapsed {
                collapsedDirectoryIDs.remove(node.id)
            } else {
                collapsedDirectoryIDs.insert(node.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if collapsed {
                    Text("\(node.fileCount)")
                        .font(theme.fonts.micro)
                        .monospacedDigit()
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textSecondary)
            .padding(.leading, CGFloat(depth) * 12 + 6)
            .padding(.trailing, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.name) folder, \(node.fileCount) changed files")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }

    private func fileRow(
        _ file: CodexGitReviewFileChange,
        name: String,
        depth: Int
    ) -> some View {
        let selected = workbench.selectedFileID == file.id
        let viewed = workbench.viewedFileIDs.contains(file.id)
        return HStack(spacing: 6) {
            Button {
                workbench.selectFile(id: file.id)
            } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(
                            selected ? theme.colors.textPrimary : theme.colors.textSecondary
                        )
                    if file.stagingState == .partiallyStaged {
                        stagingTag("Partial")
                    } else if file.stagingState == .staged {
                        stagingTag("Staged")
                    }
                    Spacer(minLength: 4)
                    CodexReviewDiffStat(
                        added: file.addedLines,
                        removed: file.removedLines
                    )
                    .font(theme.fonts.micro)
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.path)

            Button {
                workbench.toggleViewed(file.id)
            } label: {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        viewed ? theme.colors.success : CodexReviewStatusBadge.color(
                            file.status,
                            theme: theme
                        )
                    )
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewed ? "Mark unviewed" : "Mark viewed")
        }
        .font(theme.fonts.micro)
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(
            selected ? theme.colors.accentSoft : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .opacity(viewed && !selected ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(file.path), \(file.status.title), \(file.addedLines) additions, \(file.removedLines) removals"
        )
    }

    private func stagingTag(_ title: String) -> some View {
        Text(title)
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                theme.colors.accentSoft,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
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
                VStack(spacing: 10) {
                    emptyDiff(title: "Diff unavailable", detail: message)
                    Button("Retry") { workbench.retrySelectedPatch() }
                        .buttonStyle(.bordered)
                }
            case .ready(let patch):
                if workbench.selectedFile?.isBinary == true {
                    emptyDiff(
                        title: "Binary file not shown",
                        detail: "Open the file to review the binary change."
                    )
                } else if patch.displayText.isEmpty,
                          workbench.selectedFile?.status == .renamed {
                    emptyDiff(
                        title: "File renamed without changes",
                        detail: "The file contents are unchanged."
                    )
                } else if patch.displayText.isEmpty {
                    emptyDiff(
                        title: "No diff content",
                        detail: "Git reported this file without a textual patch."
                    )
                } else {
                    CodexUnifiedReviewDiff(
                        patch: patch.displayText,
                        isTruncated: patch.isTruncated,
                        wrapsLines: wrapsDiffLines
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var selectedFileHeader: some View {
        if let file = workbench.selectedFile {
            HStack(spacing: 10) {
                CodexReviewStatusBadge(status: file.status)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(CodexReviewPath.fileName(file.path))
                            .font(theme.fonts.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        CodexReviewDiffStat(
                            added: file.addedLines,
                            removed: file.removedLines
                        )
                        .font(theme.fonts.micro)
                    }
                    Group {
                        if let previousPath = file.previousPath {
                            Text("renamed from \(previousPath)")
                        } else if let directory = CodexReviewPath.directory(file.path) {
                            Text(directory)
                        }
                    }
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.path)
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
                            revertScope = .selected
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
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(theme.colors.surface.opacity(0.35))
        } else {
            Text("No file selected")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 14)
                .background(theme.colors.surface.opacity(0.35))
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
                Button("Commit") {
                    showsCommit = false
                    workbench.commit()
                }
                .disabled(workbench.actionState?.isCommitEnabled != true)
                Button("Commit and push") {
                    showsCommit = false
                    workbench.commitAndPush()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(workbench.actionState?.isCommitAndPushEnabled != true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            let files = workbench.snapshot?.files ?? []
            if files.contains(where: { $0.stagingState.hasUnstagedChanges }) {
                Button("Stage all") { workbench.stageAll() }
                    .buttonStyle(.bordered)
            }
            if files.contains(where: { $0.stagingState.hasStagedChanges }) {
                Button("Unstage all") { workbench.unstageAll() }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            if files.contains(where: { $0.status != .untracked }) {
                Button("Revert all", role: .destructive) {
                    revertScope = .all
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Revert all tracked changes")
            }
        }
        .font(theme.fonts.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(theme.colors.surface.opacity(0.72))
    }

    @ViewBuilder
    private var comparisonPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workbench.source == .branch {
                Text("Compare branch")
                    .font(theme.fonts.body.weight(.semibold))
                Text("Choose the base branch. Review compares its merge base with the current HEAD.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(
                    workbench.snapshot?.branchPicker.options.filter { !$0.isCurrent } ?? [],
                    id: \.branchName
                ) { option in
                    Button {
                        showsComparison = false
                        workbench.selectBaseBranch(option.branchName)
                    } label: {
                        HStack {
                            Text(option.branchName)
                            Spacer()
                            if option.branchName == workbench.baseBranch {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Review commit")
                    .font(theme.fonts.body.weight(.semibold))
                if let commits = workbench.snapshot?.commitOptions, !commits.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(commits) { commit in
                                Button {
                                    workbench.commitRef = commit.sha
                                    showsComparison = false
                                    workbench.applyCommitRef()
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(commit.shortSHA)
                                            .font(theme.fonts.code)
                                            .foregroundStyle(theme.colors.textTertiary)
                                        Text(commit.subject)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                    Divider()
                }
                TextField("Commit SHA or ref", text: $workbench.commitRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        showsComparison = false
                        workbench.applyCommitRef()
                    }
                HStack {
                    Button("Cancel") { showsComparison = false }
                    Spacer()
                    Button("Apply") {
                        showsComparison = false
                        workbench.applyCommitRef()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(workbench.commitRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
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

    @ViewBuilder
    private var pullRequestDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch workbench.pullRequestState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading pull request…")
                }
            case .notFound:
                Text("No pull request")
                    .font(theme.fonts.body.weight(.semibold))
                Text("The current branch does not have an open pull request.")
                    .foregroundStyle(theme.colors.textSecondary)
            case .failed(let message):
                Text("Pull request unavailable")
                    .font(theme.fonts.body.weight(.semibold))
                Text(message)
                    .foregroundStyle(theme.colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { workbench.loadPullRequest() }
                    .buttonStyle(.bordered)
            case .ready(let details):
                HStack(alignment: .firstTextBaseline) {
                    Text("#\(details.number) \(details.title)")
                        .font(theme.fonts.body.weight(.semibold))
                    Spacer()
                    Text(details.isDraft ? "Draft" : details.state.capitalized)
                        .font(theme.fonts.micro.weight(.semibold))
                        .foregroundStyle(details.isDraft ? theme.colors.warning : theme.colors.success)
                }
                Text("\(details.headBranch) → \(details.baseBranch)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                if let decision = details.reviewDecision {
                    Label(decision.replacingOccurrences(of: "_", with: " ").capitalized,
                          systemImage: "person.2")
                }
                if !details.reviewers.isEmpty {
                    Text("Reviewers: \(details.reviewers.joined(separator: ", "))")
                }
                Divider()
                Text("Checks")
                    .font(theme.fonts.caption.weight(.semibold))
                if details.checks.isEmpty {
                    Text("No checks reported")
                        .foregroundStyle(theme.colors.textTertiary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(details.checks) { check in
                                HStack(spacing: 7) {
                                    Image(systemName: check.passed
                                          ? "checkmark.circle.fill" : "clock")
                                        .foregroundStyle(check.passed
                                                         ? theme.colors.success : theme.colors.warning)
                                    Text(check.name).lineLimit(1)
                                    Spacer()
                                    Text((check.conclusion?.nilIfBlank ?? check.status)
                                        .replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(theme.fonts.micro)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                HStack {
                    Button("Refresh") { workbench.loadPullRequest() }
                    Spacer()
                    Button("Open on GitHub") { NSWorkspace.shared.open(details.url) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .font(theme.fonts.caption)
        .padding(16)
        .frame(width: 420)
        .accessibilityIdentifier("codex.review.pull-request-details")
        .onDisappear { workbench.cancelPullRequestLoad() }
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

private enum RevertScope {
    case selected
    case all
}

/// Changed files arranged as a directory tree. Single-child directory chains
/// collapse into one row so deep repositories do not turn into a staircase.
struct CodexReviewFileTreeNode: Identifiable {
    enum Kind {
        case directory(children: [CodexReviewFileTreeNode])
        case file(CodexGitReviewFileChange)
    }

    let id: String
    let name: String
    let kind: Kind

    var fileCount: Int {
        switch kind {
        case .file: 1
        case .directory(let children): children.reduce(0) { $0 + $1.fileCount }
        }
    }

    static func build(_ files: [CodexGitReviewFileChange]) -> [CodexReviewFileTreeNode] {
        nodes(
            from: files.map { (components: pathComponents($0.path), file: $0) },
            prefix: ""
        )
    }

    static func flatten(
        _ nodes: [CodexReviewFileTreeNode],
        collapsedIDs: Set<String>,
        depth: Int = 0
    ) -> [(node: CodexReviewFileTreeNode, depth: Int)] {
        var result: [(node: CodexReviewFileTreeNode, depth: Int)] = []
        for node in nodes {
            result.append((node, depth))
            if case .directory(let children) = node.kind,
               !collapsedIDs.contains(node.id) {
                result.append(contentsOf: flatten(
                    children,
                    collapsedIDs: collapsedIDs,
                    depth: depth + 1
                ))
            }
        }
        return result
    }

    private static func pathComponents(_ path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        return components.isEmpty ? [path] : components
    }

    private static func nodes(
        from entries: [(components: [String], file: CodexGitReviewFileChange)],
        prefix: String
    ) -> [CodexReviewFileTreeNode] {
        var directoryOrder: [String] = []
        var grouped: [String: [(components: [String], file: CodexGitReviewFileChange)]] = [:]
        var fileNodes: [CodexReviewFileTreeNode] = []

        for entry in entries {
            guard entry.components.count > 1, let head = entry.components.first else {
                fileNodes.append(CodexReviewFileTreeNode(
                    id: entry.file.id,
                    name: entry.components.last ?? entry.file.path,
                    kind: .file(entry.file)
                ))
                continue
            }
            if grouped[head] == nil { directoryOrder.append(head) }
            grouped[head, default: []].append((
                components: Array(entry.components.dropFirst()),
                file: entry.file
            ))
        }

        var result = directoryOrder.map { head -> CodexReviewFileTreeNode in
            let id = prefix + head + "/"
            let children = nodes(from: grouped[head] ?? [], prefix: id)
            if children.count == 1, case .directory(let nested) = children[0].kind {
                return CodexReviewFileTreeNode(
                    id: children[0].id,
                    name: head + "/" + children[0].name,
                    kind: .directory(children: nested)
                )
            }
            return CodexReviewFileTreeNode(id: id, name: head, kind: .directory(children: children))
        }
        result.append(contentsOf: fileNodes)
        return result
    }
}

enum CodexReviewPath {
    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func directory(_ path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}

struct CodexReviewDiffStat: View {
    @Environment(\.codexAgentTheme) private var theme
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            if added > 0 || removed == 0 {
                Text("+\(added)").foregroundStyle(theme.colors.success)
            }
            if removed > 0 {
                Text("−\(removed)").foregroundStyle(theme.colors.danger)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(added) additions, \(removed) removals")
    }
}

struct CodexReviewStatusBadge: View {
    @Environment(\.codexAgentTheme) private var theme
    let status: CodexGitReviewFileStatus

    static func color(
        _ status: CodexGitReviewFileStatus,
        theme: CodexAgentTheme
    ) -> Color {
        switch status {
        case .added, .untracked: theme.colors.success
        case .modified: theme.colors.warning
        case .deleted: theme.colors.danger
        case .renamed: theme.colors.accentText
        }
    }

    private var letter: String {
        switch status {
        case .added: "A"
        case .untracked: "U"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    var body: some View {
        let color = Self.color(status, theme: theme)
        Text(letter)
            .font(theme.fonts.micro.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(
                color.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .accessibilityLabel(status.title)
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

/// A unified patch parsed into presentable rows.
///
/// A unified diff carries one number per row — the new side, or the old side
/// for a line that only existed before the change — the way the official Codex
/// renderer does it. Both sides are retained per row for accessibility and for
/// deciding whether a whole-file hunk header says anything.
struct CodexReviewDiffDocument: Equatable {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case hunk, context, add, remove, note }
        let id: Int
        let oldLine: Int?
        let newLine: Int?
        let kind: Kind
        /// Line content with the unified-diff marker removed, so every row
        /// shares one indentation origin.
        let text: String

        /// The single number a unified diff shows: the new side, or the old
        /// side for a line that only existed before the change.
        var displayLine: Int? { newLine ?? oldLine }
    }

    let rows: [Row]
    let hasOldSide: Bool
    let hasNewSide: Bool
    let widestLineNumber: Int

    static let empty = CodexReviewDiffDocument(
        rows: [],
        hasOldSide: false,
        hasNewSide: false,
        widestLineNumber: 0
    )

    static func parse(_ patch: String) -> CodexReviewDiffDocument {
        var rows: [Row] = []
        rows.reserveCapacity(min(2_048, max(16, patch.count / 20)))
        var oldLine = 1
        var newLine = 1
        var sawHunk = false
        var widest = 0

        for (index, rawLine) in patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                let starts = hunkStarts(line)
                oldLine = starts.old
                newLine = starts.new
                sawHunk = true
                rows.append(.init(
                    id: index,
                    oldLine: nil,
                    newLine: nil,
                    kind: .hunk,
                    text: line
                ))
                continue
            }
            if isFileHeaderLine(line) { continue }
            if line.hasPrefix("\\") {
                rows.append(.init(
                    id: index,
                    oldLine: nil,
                    newLine: nil,
                    kind: .note,
                    text: line.dropFirst().trimmingCharacters(in: .whitespaces)
                ))
                continue
            }
            if sawHunk, line.hasPrefix("+") {
                rows.append(.init(
                    id: index,
                    oldLine: nil,
                    newLine: newLine,
                    kind: .add,
                    text: String(line.dropFirst())
                ))
                widest = max(widest, newLine)
                newLine += 1
            } else if sawHunk, line.hasPrefix("-") {
                rows.append(.init(
                    id: index,
                    oldLine: oldLine,
                    newLine: nil,
                    kind: .remove,
                    text: String(line.dropFirst())
                ))
                widest = max(widest, oldLine)
                oldLine += 1
            } else {
                // Outside a hunk the payload is plain file content, which only
                // ever has a new side.
                rows.append(.init(
                    id: index,
                    oldLine: sawHunk ? oldLine : nil,
                    newLine: newLine,
                    kind: .context,
                    text: sawHunk && line.hasPrefix(" ") ? String(line.dropFirst()) : line
                ))
                widest = max(widest, sawHunk ? oldLine : newLine, newLine)
                oldLine += 1
                newLine += 1
            }
        }

        // A patch that ends in a newline yields one phantom trailing row.
        if let last = rows.last, last.kind == .context, last.text.isEmpty {
            rows.removeLast()
            widest = rows.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        }

        let hasOldSide = rows.contains { $0.oldLine != nil }
        let hasNewSide = rows.contains { $0.newLine != nil }
        // A whole-file addition or deletion has one hunk that says nothing the
        // file header has not already said.
        if !hasOldSide || !hasNewSide,
           rows.filter({ $0.kind == .hunk }).count == 1 {
            rows.removeAll { $0.kind == .hunk }
        }

        return CodexReviewDiffDocument(
            rows: rows,
            hasOldSide: hasOldSide,
            hasNewSide: hasNewSide,
            widestLineNumber: widest
        )
    }

    private static func isFileHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line == "---"
            || line == "+++"
            || line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ")
            || line.hasPrefix("old mode ")
            || line.hasPrefix("new mode ")
            || line.hasPrefix("similarity index ")
            || line.hasPrefix("dissimilarity index ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
            || line.hasPrefix("copy from ")
            || line.hasPrefix("copy to ")
    }

    private static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        let fields = header.split(separator: " ")
        func start(prefix: Character) -> Int {
            guard let value = fields.first(where: { $0.first == prefix }) else { return 1 }
            let parsed = Int(value.dropFirst().split(separator: ",").first ?? "1") ?? 1
            // `@@ -0,0` marks an empty old side; content still starts at line 1.
            return max(1, parsed)
        }
        return (start(prefix: "-"), start(prefix: "+"))
    }
}

private struct CodexUnifiedReviewDiff: View {
    @Environment(\.codexAgentTheme) private var theme

    let patch: String
    let isTruncated: Bool
    let wrapsLines: Bool

    private var document: CodexReviewDiffDocument { .parse(patch) }

    var body: some View {
        let document = document
        let gutterWidth = Self.gutterWidth(for: document.widestLineNumber)
        ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.rows) { row in
                    diffRow(row, document: document, gutterWidth: gutterWidth)
                }
                if isTruncated {
                    Label(
                        "Preview bounded at 256 KiB; narrow the source or file to continue.",
                        systemImage: "ellipsis.rectangle"
                    )
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.warning)
                    .padding(12)
                }
            }
            .padding(.vertical, 6)
        }
        .defaultScrollAnchor(.topLeading)
        .background(theme.colors.codeBackground)
        .accessibilityIdentifier("codex.review.unified-diff")
    }

    @ViewBuilder
    private func diffRow(
        _ row: CodexReviewDiffDocument.Row,
        document: CodexReviewDiffDocument,
        gutterWidth: CGFloat
    ) -> some View {
        switch row.kind {
        case .hunk:
            hunkRow(row)
        case .note:
            Text(verbatim: row.text)
                .font(theme.fonts.micro.italic())
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.leading, gutterLead(document: document, gutterWidth: gutterWidth))
                .padding(.vertical, 3)
        case .context, .add, .remove:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(changeBar(row.kind))
                    .frame(width: 3)
                lineNumber(row.displayLine, width: gutterWidth)
                Text(verbatim: marker(row.kind))
                    .foregroundStyle(foreground(row.kind))
                    .frame(width: 16, alignment: .center)
                Text(verbatim: row.text)
                    .foregroundStyle(foreground(row.kind))
                    .textSelection(.enabled)
                    .padding(.trailing, 12)
                    .fixedSize(horizontal: !wrapsLines, vertical: false)
                Spacer(minLength: 0)
            }
            .font(theme.fonts.code)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(row.kind))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(row))
        }
    }

    private func hunkRow(_ row: CodexReviewDiffDocument.Row) -> some View {
        let parts = Self.hunkParts(row.text)
        return HStack(spacing: 8) {
            Text(verbatim: parts.range)
                .font(theme.fonts.code)
                .foregroundStyle(theme.colors.accentText)
            if let context = parts.context {
                Text(verbatim: context)
                    .font(theme.fonts.code)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceSunken)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
        .padding(.vertical, 4)
        .accessibilityLabel("Hunk \(row.text)")
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(height: 1)
    }

    private func lineNumber(_ value: Int?, width: CGFloat) -> some View {
        Text(value.map(String.init) ?? "")
            .font(theme.fonts.code)
            .monospacedDigit()
            .foregroundStyle(theme.colors.textTertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 8)
    }

    private func gutterLead(
        document: CodexReviewDiffDocument,
        gutterWidth: CGFloat
    ) -> CGFloat {
        // Change bar + one gutter + marker column.
        19 + gutterWidth + 8
    }

    private static func gutterWidth(for widestLineNumber: Int) -> CGFloat {
        let digits = max(2, String(max(1, widestLineNumber)).count)
        return CGFloat(digits) * 8 + 12
    }

    private static func hunkParts(_ header: String) -> (range: String, context: String?) {
        guard let closing = header.range(of: "@@", range: header.index(
            header.startIndex,
            offsetBy: 2
        )..<header.endIndex) else {
            return (header, nil)
        }
        let range = String(header[header.startIndex..<closing.upperBound])
        let context = header[closing.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return (range, context.isEmpty ? nil : context)
    }

    private func marker(_ kind: CodexReviewDiffDocument.Row.Kind) -> String {
        switch kind {
        case .add: "+"
        case .remove: "−"
        default: " "
        }
    }

    private func foreground(_ kind: CodexReviewDiffDocument.Row.Kind) -> Color {
        switch kind {
        case .hunk, .note: theme.colors.textTertiary
        case .context: theme.colors.codeText
        case .add: theme.colors.success
        case .remove: theme.colors.danger
        }
    }

    private func changeBar(_ kind: CodexReviewDiffDocument.Row.Kind) -> Color {
        switch kind {
        case .add: theme.colors.success
        case .remove: theme.colors.danger
        default: .clear
        }
    }

    private func background(_ kind: CodexReviewDiffDocument.Row.Kind) -> Color {
        switch kind {
        case .add: theme.colors.success.opacity(0.12)
        case .remove: theme.colors.danger.opacity(0.12)
        default: .clear
        }
    }

    private func accessibilityLabel(_ row: CodexReviewDiffDocument.Row) -> String {
        let line = row.newLine ?? row.oldLine
        let prefix: String = switch row.kind {
        case .hunk: "Hunk"
        case .note: "Note"
        case .context: "Context"
        case .add: "Added"
        case .remove: "Removed"
        }
        return line.map { "\(prefix), line \($0), \(row.text)" } ?? "\(prefix), \(row.text)"
    }
}

@_spi(VisualTesting)
public struct CodexGitReviewWorkbenchGalleryFixture: View {
    @State private var workbench: CodexGitReviewWorkbench
    private let selectedPath: String?

    public init(selectedPath: String? = nil) {
        self.selectedPath = selectedPath
        _workbench = State(initialValue: CodexGitReviewWorkbench(
            workspaceURL: URL(fileURLWithPath: "/Users/person/Projects/CodexCore"),
            lastTurnSession: CodexGitReviewSession(
                snapshot: CodexGitReviewSnapshot(
                    branchName: "codex/review-workbench-170",
                    upstreamBranchName: "origin/main",
                    files: [
                        CodexGitReviewFileChange(
                            path: "games/guess_game.py",
                            status: .added,
                            isStaged: false,
                            addedLines: 8,
                            removedLines: 0,
                            unifiedPatch: """
                            diff --git a/games/guess_game.py b/games/guess_game.py
                            new file mode 100644
                            --- /dev/null
                            +++ b/games/guess_game.py
                            @@ -0,0 +1,8 @@
                            +import random
                            +
                            +secret = random.randint(1, 10)
                            +print("Guess my number from 1 to 10!")
                            +
                            +while True:
                            +    guess = int(input("Your guess: "))
                            +    if guess == secret:
                            """
                        ),
                        CodexGitReviewFileChange(
                            path: "Sources/CodexCoreUI/CodexGitReviewWorkbenchView.swift",
                            status: .modified,
                            isStaged: true,
                            addedLines: 3,
                            removedLines: 2,
                            unifiedPatch: """
                            diff --git a/Sources/CodexCoreUI/CodexGitReviewWorkbenchView.swift b/Sources/CodexCoreUI/CodexGitReviewWorkbenchView.swift
                            @@ -12,7 +12,8 @@ struct CodexGitReviewWorkbenchView: View {
                                 private var diffPane: some View {
                            -        VStack(spacing: 4) {
                            -            header
                            +        VStack(spacing: 0) {
                            +            selectedFileHeader
                            +            Divider()
                                         diff
                                     }
                                 }
                            """
                        ),
                        CodexGitReviewFileChange(
                            path: "Sources/CodexCoreUI/CodexGitReviewModels.swift",
                            status: .modified,
                            isStaged: false,
                            addedLines: 12,
                            removedLines: 1
                        ),
                        CodexGitReviewFileChange(
                            path: "docs/ui/embedding.md",
                            status: .modified,
                            isStaged: false,
                            addedLines: 6,
                            removedLines: 4
                        ),
                    ]
                )
            )
        ))
    }

    public var body: some View {
        CodexGitReviewWorkbenchView(workbench: workbench)
            .frame(width: 880, height: 460)
            .task {
                if let selectedPath { workbench.selectFile(path: selectedPath) }
            }
    }
}
