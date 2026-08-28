import Foundation

public struct CodexGitReviewRevision: Hashable, Sendable {
    public let sourceID: String
    public let value: UInt64

    public init(sourceID: String, value: UInt64) {
        self.sourceID = sourceID
        self.value = value
    }

    public static let manual = CodexGitReviewRevision(
        sourceID: "manual",
        value: 0
    )
}

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

public enum CodexGitStagingState: String, Equatable, Sendable {
    case unstaged
    case staged
    case partiallyStaged

    public var hasStagedChanges: Bool { self != .unstaged }
    public var hasUnstagedChanges: Bool { self != .staged }
}

public struct CodexGitReviewPatchText: Equatable, Sendable {
    public static let defaultMaximumDisplayUTF8Bytes = 128 * 1_024
    public static let defaultMaximumDisplayLineCount = 800

    private let fullTextStorage: CodexGitReviewFullPatchStorage
    public let displayText: String
    public let isTruncated: Bool

    public var fullText: String {
        fullTextStorage.materialized()
    }

    public var hasFullText: Bool {
        fullTextStorage.hasText
    }

    public init(
        fullText: String,
        displayText: String,
        isTruncated: Bool
    ) {
        let boundedDisplay = Self.bounded(fullText: displayText)
        self.fullTextStorage = .immediate(fullText)
        self.displayText = boundedDisplay.displayText
        self.isTruncated = isTruncated
            || boundedDisplay.isTruncated
            || displayText != fullText
    }

    public static func bounded(
        fullText: String,
        maximumDisplayUTF8Bytes: Int = defaultMaximumDisplayUTF8Bytes,
        maximumDisplayLineCount: Int = defaultMaximumDisplayLineCount
    ) -> Self {
        let byteLimit = max(1, maximumDisplayUTF8Bytes)
        let lineLimit = max(1, maximumDisplayLineCount)
        let utf8 = fullText.utf8
        var end = utf8.startIndex
        var byteCount = 0
        var lineCount = 1

        while end != utf8.endIndex, byteCount < byteLimit {
            let byte = utf8[end]
            if byte == 0x0A, lineCount >= lineLimit {
                break
            }
            utf8.formIndex(after: &end)
            byteCount += 1
            if byte == 0x0A {
                lineCount += 1
            }
        }

        guard end != utf8.endIndex else {
            return Self(
                uncheckedFullText: fullText,
                displayText: fullText,
                isTruncated: false
            )
        }

        while end != utf8.startIndex,
              String.Index(end, within: fullText) == nil {
            utf8.formIndex(before: &end)
        }
        let stringEnd = String.Index(end, within: fullText)
            ?? fullText.startIndex
        return Self(
            uncheckedFullText: fullText,
            displayText: String(fullText[..<stringEnd]),
            isTruncated: true
        )
    }

    private init(
        uncheckedFullText: String,
        displayText: String,
        isTruncated: Bool
    ) {
        self.fullTextStorage = .immediate(uncheckedFullText)
        self.displayText = displayText
        self.isTruncated = isTruncated
    }

    init(
        deferredFullText: CodexGitReviewDeferredPatch,
        displayText: String,
        isTruncated: Bool
    ) {
        let boundedDisplay = Self.bounded(fullText: displayText)
        self.fullTextStorage = .deferred(deferredFullText)
        self.displayText = boundedDisplay.displayText
        self.isTruncated = isTruncated || boundedDisplay.isTruncated
    }
}

final class CodexGitReviewDeferredPatch: @unchecked Sendable {
    let identity: String
    let hasText: Bool
    private let materialize: @Sendable () -> String

    init(
        identity: String,
        hasText: Bool,
        materialize: @escaping @Sendable () -> String
    ) {
        self.identity = identity
        self.hasText = hasText
        self.materialize = materialize
    }

    func materialized() -> String {
        materialize()
    }
}

private enum CodexGitReviewFullPatchStorage: @unchecked Sendable, Equatable {
    case immediate(String)
    case deferred(CodexGitReviewDeferredPatch)

    var hasText: Bool {
        switch self {
        case .immediate(let text):
            !text.isEmpty
        case .deferred(let patch):
            patch.hasText
        }
    }

    func materialized() -> String {
        switch self {
        case .immediate(let text):
            text
        case .deferred(let patch):
            patch.materialized()
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.immediate(let lhsText), .immediate(let rhsText)):
            lhsText == rhsText
        case (.deferred(let lhsPatch), .deferred(let rhsPatch)):
            lhsPatch.identity == rhsPatch.identity
        default:
            false
        }
    }
}

public struct CodexGitReviewFileChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let previousPath: String?
    public let status: CodexGitReviewFileStatus
    public let stagingState: CodexGitStagingState
    public let addedLines: Int
    public let removedLines: Int
    public let patchText: CodexGitReviewPatchText
    public let isBinary: Bool

    public var unifiedPatch: String {
        patchText.fullText
    }

    public var isStaged: Bool {
        stagingState == .staged
    }

    public var displayPatch: String {
        patchText.displayText
    }

    public var isPatchTruncated: Bool {
        patchText.isTruncated
    }

    public var hasCopyablePatch: Bool {
        patchText.hasFullText
    }

    public init(
        id: String? = nil,
        path: String,
        previousPath: String? = nil,
        status: CodexGitReviewFileStatus,
        isStaged: Bool,
        stagingState: CodexGitStagingState? = nil,
        addedLines: Int = 0,
        removedLines: Int = 0,
        unifiedPatch: String = "",
        displayPatch: String? = nil,
        isPatchTruncated: Bool = false,
        isBinary: Bool = false
    ) {
        self.id = id ?? "\(status.rawValue):\(path)"
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.stagingState = stagingState ?? (isStaged ? .staged : .unstaged)
        self.addedLines = max(0, addedLines)
        self.removedLines = max(0, removedLines)
        if let displayPatch {
            self.patchText = CodexGitReviewPatchText(
                fullText: unifiedPatch,
                displayText: displayPatch,
                isTruncated: isPatchTruncated
            )
        } else {
            self.patchText = CodexGitReviewPatchText.bounded(
                fullText: unifiedPatch
            )
        }
        self.isBinary = isBinary
    }

    public init(
        id: String,
        path: String,
        previousPath: String? = nil,
        status: CodexGitReviewFileStatus,
        isStaged: Bool = false,
        stagingState: CodexGitStagingState? = nil,
        addedLines: Int,
        removedLines: Int,
        patchText: CodexGitReviewPatchText,
        isBinary: Bool
    ) {
        self.id = id
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.stagingState = stagingState ?? (isStaged ? .staged : .unstaged)
        self.addedLines = max(0, addedLines)
        self.removedLines = max(0, removedLines)
        self.patchText = patchText
        self.isBinary = isBinary
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

public struct CodexGitCommitOption: Identifiable, Equatable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let subject: String
    public let committedAt: Date

    public init(sha: String, subject: String, committedAt: Date) {
        self.sha = sha
        self.subject = subject
        self.committedAt = committedAt
    }

    public var shortSHA: String {
        String(sha.prefix(8))
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

public struct CodexGitPullRequestCheck: Equatable, Sendable, Identifiable {
    public let name: String
    public let status: String
    public let conclusion: String?
    public let detailsURL: URL?

    public init(name: String, status: String, conclusion: String? = nil, detailsURL: URL? = nil) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
    }

    public var id: String { "\(name):\(detailsURL?.absoluteString ?? status)" }
    public var passed: Bool { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion ?? "") }
}

public struct CodexGitPullRequestDetails: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let state: String
    public let mergeState: String?
    public let reviewDecision: String?
    public let baseBranch: String
    public let headBranch: String
    public let reviewers: [String]
    public let checks: [CodexGitPullRequestCheck]

    public init(
        number: Int,
        title: String,
        url: URL,
        isDraft: Bool,
        state: String,
        mergeState: String? = nil,
        reviewDecision: String? = nil,
        baseBranch: String,
        headBranch: String,
        reviewers: [String] = [],
        checks: [CodexGitPullRequestCheck] = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.state = state
        self.mergeState = mergeState?.nilIfBlank
        self.reviewDecision = reviewDecision?.nilIfBlank
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.reviewers = reviewers
        self.checks = checks
    }
}

public struct CodexGitReviewSnapshot: Equatable, Sendable {
    public let revision: CodexGitReviewRevision
    public let branchName: String
    public let upstreamBranchName: String?
    public let remoteNames: [String]
    public let branchOptions: [CodexGitBranchPickerOption]
    public let commitOptions: [CodexGitCommitOption]
    public let comparisonRef: String?
    public let files: [CodexGitReviewFileChange]
    public let diffStats: CodexGitReviewDiffStats
    public let reviewFilePaths: [String]?
    public let unpushedCommitCount: Int
    public let pullRequestExists: Bool
    public let ignoredChangeCount: Int
    private let fileIndexByID: [String: Int]
    private let stagedDiffStats: CodexGitReviewDiffStats

    public init(
        revision: CodexGitReviewRevision = .manual,
        branchName: String,
        upstreamBranchName: String? = nil,
        remoteNames: [String] = [],
        branchOptions: [CodexGitBranchPickerOption] = [],
        commitOptions: [CodexGitCommitOption] = [],
        comparisonRef: String? = nil,
        files: [CodexGitReviewFileChange] = [],
        diffStats: CodexGitReviewDiffStats? = nil,
        reviewFilePaths: [String]? = nil,
        unpushedCommitCount: Int = 0,
        pullRequestExists: Bool = false,
        ignoredChangeCount: Int = 0
    ) {
        self.revision = revision
        self.branchName = branchName.nilIfBlank ?? "HEAD"
        self.upstreamBranchName = upstreamBranchName?.nilIfBlank
        self.remoteNames = remoteNames
        self.branchOptions = branchOptions
        self.commitOptions = commitOptions
        self.comparisonRef = comparisonRef?.nilIfBlank
        self.files = files
        self.diffStats = diffStats ?? CodexGitReviewDiffStats.from(files)
        self.fileIndexByID = files.enumerated().reduce(into: [:]) {
            result, entry in
            if result[entry.element.id] == nil {
                result[entry.element.id] = entry.offset
            }
        }
        var stagedCount = 0
        var stagedAddedLines = 0
        var stagedRemovedLines = 0
        for file in files where file.isStaged {
            stagedCount += 1
            stagedAddedLines += file.addedLines
            stagedRemovedLines += file.removedLines
        }
        self.stagedDiffStats = CodexGitReviewDiffStats(
            changedFiles: stagedCount,
            addedLines: stagedAddedLines,
            removedLines: stagedRemovedLines
        )
        self.reviewFilePaths = reviewFilePaths
        self.unpushedCommitCount = max(0, unpushedCommitCount)
        self.pullRequestExists = pullRequestExists
        self.ignoredChangeCount = max(0, ignoredChangeCount)
    }

    public static func fromTurnDiff(
        branchName: String?,
        turnDiff: String?,
        revision: CodexGitReviewRevision = .manual,
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
            let status: CodexGitReviewFileStatus = switch file.kind {
            case "added": .added
            case "deleted": .deleted
            case "renamed": .renamed
            default: .modified
            }
            return CodexGitReviewFileChange(
                path: file.path,
                status: status,
                isStaged: false,
                addedLines: file.added,
                removedLines: file.removed
            )
        }
        guard !files.isEmpty else { return nil }
        return CodexGitReviewSnapshot(
            revision: revision,
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

    public func file(id: String?) -> CodexGitReviewFileChange? {
        guard let id, let index = fileIndexByID[id] else { return nil }
        return files[index]
    }

    public var unstagedFiles: [CodexGitReviewFileChange] {
        files.filter { !$0.isStaged }
    }

    public var hasRemoteBranch: Bool {
        upstreamBranchName != nil
    }

    public var hasPushRemote: Bool {
        hasRemoteBranch || !remoteNames.isEmpty
    }

    public var hasUncommittedChanges: Bool {
        !files.isEmpty
    }

    public var branchSummary: CodexGitBranchDirtySummary {
        CodexGitBranchDirtySummary(
            branchName: branchName,
            dirtyFileCount: files.count,
            stagedFileCount: stagedDiffStats.changedFiles,
            unstagedFileCount: files.count - stagedDiffStats.changedFiles,
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
        includeUnstaged
            ? diffStats
            : stagedDiffStats
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

public enum CodexLastTurnReviewState: Equatable, Sendable {
    case empty(revision: CodexGitReviewRevision)
    case malformed(revision: CodexGitReviewRevision, detail: String)
    case tooLarge(
        revision: CodexGitReviewRevision,
        byteCount: Int,
        maximumByteCount: Int
    )
    case ready(CodexGitReviewSession)

    public var revision: CodexGitReviewRevision {
        switch self {
        case .empty(let revision),
             .malformed(let revision, _),
             .tooLarge(let revision, _, _):
            return revision
        case .ready(let session):
            return session.snapshot.revision
        }
    }

    public var session: CodexGitReviewSession? {
        guard case .ready(let session) = self else { return nil }
        return session
    }

    public var canOpenReview: Bool {
        session != nil
    }

    public var unavailablePresentation: CodexGitReviewEmptyState? {
        switch self {
        case .ready:
            return nil
        case .empty:
            return CodexGitReviewEmptyState(
                title: "No changes in the last turn",
                detail: "The latest turn did not produce file changes.",
                isMismatch: false
            )
        case .malformed(_, let detail):
            return CodexGitReviewEmptyState(
                title: "Review unavailable",
                detail: detail,
                isMismatch: true
            )
        case .tooLarge(_, let byteCount, let maximumByteCount):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(max(1, maximumByteCount)),
                countStyle: .file
            )
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(max(0, byteCount)),
                countStyle: .file
            )
            return CodexGitReviewEmptyState(
                title: "Review too large",
                detail: "The \(size) last-turn patch exceeds the \(limit) preview limit.",
                isMismatch: true
            )
        }
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
        } else if !snapshot.hasPushRemote {
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
        if !snapshot.hasPushRemote {
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
