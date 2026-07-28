import Foundation

public enum CodexGitReviewFileStatus: String, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case untracked

    public var title: String {
        switch self {
        case .added:
            return "Added"
        case .modified:
            return "Modified"
        case .deleted:
            return "Deleted"
        case .renamed:
            return "Renamed"
        case .untracked:
            return "Untracked"
        }
    }
}

public struct CodexGitReviewFileChange: Equatable, Sendable {
    public var path: String
    public var status: CodexGitReviewFileStatus
    public var isStaged: Bool
    public var addedLines: Int
    public var removedLines: Int

    public init(
        path: String,
        status: CodexGitReviewFileStatus,
        isStaged: Bool,
        addedLines: Int = 0,
        removedLines: Int = 0
    ) {
        self.path = path
        self.status = status
        self.isStaged = isStaged
        self.addedLines = max(0, addedLines)
        self.removedLines = max(0, removedLines)
    }
}

public struct CodexGitReviewDiffStats: Equatable, Sendable {
    public var changedFiles: Int
    public var addedLines: Int
    public var removedLines: Int

    public init(changedFiles: Int = 0, addedLines: Int = 0, removedLines: Int = 0) {
        self.changedFiles = max(0, changedFiles)
        self.addedLines = max(0, addedLines)
        self.removedLines = max(0, removedLines)
    }

    public var isEmpty: Bool {
        changedFiles == 0 && addedLines == 0 && removedLines == 0
    }

    public var summary: String {
        "\(changedFiles) files +\(addedLines) -\(removedLines)"
    }

    public static func from(_ files: [CodexGitReviewFileChange]) -> CodexGitReviewDiffStats {
        CodexGitReviewDiffStats(
            changedFiles: files.count,
            addedLines: files.reduce(0) { $0 + $1.addedLines },
            removedLines: files.reduce(0) { $0 + $1.removedLines }
        )
    }
}

public struct CodexGitBranchDirtySummary: Equatable, Sendable {
    public var branchName: String
    public var dirtyFileCount: Int
    public var stagedFileCount: Int
    public var unstagedFileCount: Int
    public var unpushedCommitCount: Int

    public init(
        branchName: String,
        dirtyFileCount: Int,
        stagedFileCount: Int,
        unstagedFileCount: Int,
        unpushedCommitCount: Int
    ) {
        self.branchName = branchName
        self.dirtyFileCount = max(0, dirtyFileCount)
        self.stagedFileCount = max(0, stagedFileCount)
        self.unstagedFileCount = max(0, unstagedFileCount)
        self.unpushedCommitCount = max(0, unpushedCommitCount)
    }

    public var title: String {
        dirtyFileCount == 0 ? branchName : "\(branchName) (\(dirtyFileCount))"
    }
}

public struct CodexGitBranchPickerOption: Equatable, Sendable {
    public var branchName: String
    public var dirtyFileCount: Int
    public var isCurrent: Bool

    public init(branchName: String, dirtyFileCount: Int = 0, isCurrent: Bool = false) {
        self.branchName = branchName.nilIfBlank ?? "HEAD"
        self.dirtyFileCount = max(0, dirtyFileCount)
        self.isCurrent = isCurrent
    }

    public var title: String {
        dirtyFileCount == 0 ? branchName : "\(branchName) (\(dirtyFileCount))"
    }
}

public struct CodexGitBranchPickerState: Equatable, Sendable {
    public var options: [CodexGitBranchPickerOption]
    public var currentBranchName: String
    public var canCreateOrCheckout: Bool
    public var createOrCheckoutDisabledReason: String?

    public init(
        options: [CodexGitBranchPickerOption],
        currentBranchName: String,
        canCreateOrCheckout: Bool,
        createOrCheckoutDisabledReason: String?
    ) {
        self.options = options
        self.currentBranchName = currentBranchName.nilIfBlank ?? "HEAD"
        self.canCreateOrCheckout = canCreateOrCheckout
        self.createOrCheckoutDisabledReason = createOrCheckoutDisabledReason
    }

    public var currentTitle: String {
        options.first(where: \.isCurrent)?.title ?? currentBranchName
    }
}

public struct CodexGitReviewEmptyState: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var isMismatch: Bool

    public init(title: String, detail: String, isMismatch: Bool) {
        self.title = title
        self.detail = detail
        self.isMismatch = isMismatch
    }
}

public struct CodexGitReviewFileListPresentation: Equatable, Sendable {
    public var files: [CodexGitReviewFileChange]
    public var emptyState: CodexGitReviewEmptyState?

    public init(files: [CodexGitReviewFileChange], emptyState: CodexGitReviewEmptyState? = nil) {
        self.files = files
        self.emptyState = emptyState
    }
}

public struct CodexGitCommitDraft: Equatable, Sendable {
    public var message: String
    public var includeUnstaged: Bool

    public init(message: String = "", includeUnstaged: Bool = true) {
        self.message = message
        self.includeUnstaged = includeUnstaged
    }

    public var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validationError: String? {
        trimmedMessage.isEmpty ? "Commit message is required" : nil
    }

    public var isValid: Bool {
        validationError == nil
    }
}

public struct CodexGitReviewSnapshot: Equatable, Sendable {
    public var branchName: String
    public var upstreamBranchName: String?
    public var branchOptions: [CodexGitBranchPickerOption]
    public var files: [CodexGitReviewFileChange]
    public var reviewFilePaths: [String]?
    public var unpushedCommitCount: Int
    public var pullRequestExists: Bool

    public init(
        branchName: String,
        upstreamBranchName: String? = nil,
        branchOptions: [CodexGitBranchPickerOption] = [],
        files: [CodexGitReviewFileChange] = [],
        reviewFilePaths: [String]? = nil,
        unpushedCommitCount: Int = 0,
        pullRequestExists: Bool = false
    ) {
        self.branchName = branchName.nilIfBlank ?? "HEAD"
        self.upstreamBranchName = upstreamBranchName?.nilIfBlank
        self.branchOptions = branchOptions
        self.files = files
        self.reviewFilePaths = reviewFilePaths
        self.unpushedCommitCount = max(0, unpushedCommitCount)
        self.pullRequestExists = pullRequestExists
    }

    public static func fromTurnDiff(
        branchName: String?,
        turnDiff: String?,
        upstreamBranchName: String? = nil,
        branchOptions: [CodexGitBranchPickerOption] = [],
        reviewFilePaths: [String]? = nil,
        unpushedCommitCount: Int = 0,
        pullRequestExists: Bool = false
    ) -> CodexGitReviewSnapshot? {
        guard let turnDiff = turnDiff?.nilIfBlank else { return nil }
        let parsed = CodexUnifiedDiffParser.parseMetadataBounded(
            turnDiff,
            checkpoint: {}
        )
        guard !parsed.didTruncateFileRecords else { return nil }
        let files = parsed.files.map { file in
            CodexGitReviewFileChange(
                path: file.path,
                status: switch file.kind {
                case "added": .added
                case "deleted": .deleted
                case "renamed": .renamed
                default: .modified
                },
                isStaged: false,
                addedLines: file.added,
                removedLines: file.removed
            )
        }
        guard !files.isEmpty else { return nil }
        return CodexGitReviewSnapshot(
            branchName: branchName?.nilIfBlank ?? "HEAD",
            upstreamBranchName: upstreamBranchName,
            branchOptions: branchOptions,
            files: files,
            reviewFilePaths: reviewFilePaths,
            unpushedCommitCount: unpushedCommitCount,
            pullRequestExists: pullRequestExists
        )
    }

    public var stagedFiles: [CodexGitReviewFileChange] {
        files.filter(\.isStaged)
    }

    public var unstagedFiles: [CodexGitReviewFileChange] {
        files.filter { !$0.isStaged }
    }

    public var hasRemoteBranch: Bool {
        upstreamBranchName != nil
    }

    public var hasUncommittedChanges: Bool {
        !files.isEmpty
    }

    public var branchSummary: CodexGitBranchDirtySummary {
        CodexGitBranchDirtySummary(
            branchName: branchName,
            dirtyFileCount: files.count,
            stagedFileCount: stagedFiles.count,
            unstagedFileCount: unstagedFiles.count,
            unpushedCommitCount: unpushedCommitCount
        )
    }

    public var branchPicker: CodexGitBranchPickerState {
        var seenCurrent = false
        var options = branchOptions.map { option in
            var normalized = option
            normalized.isCurrent = normalized.branchName == branchName
            if normalized.isCurrent {
                normalized.dirtyFileCount = max(normalized.dirtyFileCount, files.count)
                seenCurrent = true
            }
            return normalized
        }

        if !seenCurrent {
            options.insert(CodexGitBranchPickerOption(
                branchName: branchName,
                dirtyFileCount: files.count,
                isCurrent: true
            ), at: 0)
        }

        let canCreateOrCheckout = !hasUncommittedChanges
        return CodexGitBranchPickerState(
            options: options,
            currentBranchName: branchName,
            canCreateOrCheckout: canCreateOrCheckout,
            createOrCheckoutDisabledReason: canCreateOrCheckout ? nil : "Commit or discard changes before switching branches"
        )
    }

    public func commitStats(includeUnstaged: Bool) -> CodexGitReviewDiffStats {
        CodexGitReviewDiffStats.from(includeUnstaged ? files : stagedFiles)
    }

    public var reviewFileList: CodexGitReviewFileListPresentation {
        let visibleFiles: [CodexGitReviewFileChange]
        if let reviewFilePaths {
            let allowed = Set(reviewFilePaths)
            visibleFiles = files.filter { allowed.contains($0.path) }
        } else {
            visibleFiles = files
        }

        guard visibleFiles.isEmpty else {
            return CodexGitReviewFileListPresentation(files: visibleFiles)
        }

        if hasUncommittedChanges {
            return CodexGitReviewFileListPresentation(
                files: [],
                emptyState: CodexGitReviewEmptyState(
                    title: "No matching files",
                    detail: "Dirty worktree state exists, but the review file list is empty.",
                    isMismatch: true
                )
            )
        }

        return CodexGitReviewFileListPresentation(
            files: [],
            emptyState: CodexGitReviewEmptyState(
                title: "No changes",
                detail: "The worktree has no dirty files.",
                isMismatch: false
            )
        )
    }

}

public struct CodexGitReviewActionState: Equatable, Sendable {
    public var isCommitEnabled: Bool
    public var commitDisabledReason: String?
    public var isCommitAndPushEnabled: Bool
    public var commitAndPushDisabledReason: String?
    public var isPushEnabled: Bool
    public var pushDisabledReason: String?
    public var isCreatePullRequestEnabled: Bool
    public var createPullRequestDisabledReason: String?

    public init(
        isCommitEnabled: Bool,
        commitDisabledReason: String?,
        isCommitAndPushEnabled: Bool,
        commitAndPushDisabledReason: String?,
        isPushEnabled: Bool,
        pushDisabledReason: String?,
        isCreatePullRequestEnabled: Bool,
        createPullRequestDisabledReason: String?
    ) {
        self.isCommitEnabled = isCommitEnabled
        self.commitDisabledReason = commitDisabledReason
        self.isCommitAndPushEnabled = isCommitAndPushEnabled
        self.commitAndPushDisabledReason = commitAndPushDisabledReason
        self.isPushEnabled = isPushEnabled
        self.pushDisabledReason = pushDisabledReason
        self.isCreatePullRequestEnabled = isCreatePullRequestEnabled
        self.createPullRequestDisabledReason = createPullRequestDisabledReason
    }
}

public struct CodexGitReviewSession: Equatable, Sendable {
    public var snapshot: CodexGitReviewSnapshot
    public var commitDraft: CodexGitCommitDraft

    public init(
        snapshot: CodexGitReviewSnapshot,
        commitDraft: CodexGitCommitDraft = CodexGitCommitDraft()
    ) {
        self.snapshot = snapshot
        self.commitDraft = commitDraft
    }

    public var branchSummary: CodexGitBranchDirtySummary {
        snapshot.branchSummary
    }

    public var commitStats: CodexGitReviewDiffStats {
        snapshot.commitStats(includeUnstaged: commitDraft.includeUnstaged)
    }

    public var fileList: CodexGitReviewFileListPresentation {
        snapshot.reviewFileList
    }

    public var actionState: CodexGitReviewActionState {
        let commitReason = commitDisabledReason
        let commitEnabled = commitReason == nil
        let commitAndPushReason: String?
        if let commitReason {
            commitAndPushReason = commitReason
        } else if !snapshot.hasRemoteBranch {
            commitAndPushReason = "Push target is unavailable"
        } else {
            commitAndPushReason = nil
        }

        return CodexGitReviewActionState(
            isCommitEnabled: commitEnabled,
            commitDisabledReason: commitReason,
            isCommitAndPushEnabled: commitAndPushReason == nil,
            commitAndPushDisabledReason: commitAndPushReason,
            isPushEnabled: pushDisabledReason == nil,
            pushDisabledReason: pushDisabledReason,
            isCreatePullRequestEnabled: createPullRequestDisabledReason == nil,
            createPullRequestDisabledReason: createPullRequestDisabledReason
        )
    }

    public mutating func setCommitMessage(_ message: String) {
        commitDraft.message = message
    }

    public mutating func setIncludeUnstaged(_ includeUnstaged: Bool) {
        commitDraft.includeUnstaged = includeUnstaged
    }

    public mutating func refresh(_ snapshot: CodexGitReviewSnapshot) {
        self.snapshot = snapshot
    }

    private var commitDisabledReason: String? {
        if let validationError = commitDraft.validationError {
            return validationError
        }
        if commitStats.changedFiles == 0 {
            return commitDraft.includeUnstaged ? "No changes to commit" : "No staged changes to commit"
        }
        return nil
    }

    private var pushDisabledReason: String? {
        if snapshot.hasUncommittedChanges {
            return "Commit or discard changes before pushing"
        }
        if snapshot.unpushedCommitCount == 0 {
            return "No commits to push"
        }
        if !snapshot.hasRemoteBranch {
            return "Push target is unavailable"
        }
        return nil
    }

    private var createPullRequestDisabledReason: String? {
        if snapshot.pullRequestExists {
            return "Pull request already exists"
        }
        if snapshot.hasUncommittedChanges {
            return "Commit or discard changes before creating a PR"
        }
        if snapshot.unpushedCommitCount > 0 {
            return "Push commits before creating a PR"
        }
        if !snapshot.hasRemoteBranch {
            return "Push branch before creating a PR"
        }
        return nil
    }
}
