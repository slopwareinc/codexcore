import Foundation
import Observation

@MainActor
@Observable
public final class CodexGitReviewWorkbench {
    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public enum PatchState: Equatable {
        case idle
        case loading
        case ready(CodexGitReviewPatchText)
        case failed(String)
    }

    public enum PullRequestState: Equatable {
        case idle
        case loading
        case notFound
        case ready(CodexGitPullRequestDetails)
        case failed(String)
    }

    public private(set) var source: CodexGitReviewSource = .lastTurn
    public private(set) var snapshot: CodexGitReviewSnapshot?
    public private(set) var loadState: LoadState = .idle
    public private(set) var patchState: PatchState = .idle
    public private(set) var operationTitle: String?
    public private(set) var operationMessage: String?
    public private(set) var operationError: String?
    public private(set) var operationURL: URL?
    public private(set) var pullRequestState: PullRequestState = .idle
    public var filter = ""
    public var selectedFileID: String?
    public var commitMessage = ""
    // Preserve the user's unstaged work unless they explicitly opt in.
    public var includeUnstaged = false
    public var branchName = ""
    public var pullRequestTitle = ""
    public var pullRequestBody = ""
    public var baseBranch = ""
    public var commitRef = "HEAD"
    private var viewedFileRevisionByID: [String: CodexGitReviewRevision] = [:]

    private let repository: CodexGitRepository
    private let lastTurnSession: CodexGitReviewSession?
    private var refreshTask: Task<Void, Never>?
    private var patchTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var pullRequestTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var pullRequestGeneration: UInt64 = 0
    private var patchCache: [String: CodexGitReviewPatchText] = [:]
    private var patchCacheOrder: [String] = []
    private let maximumCachedPatches = 12

    public init(
        workspaceURL: URL,
        lastTurnSession: CodexGitReviewSession?
    ) {
        repository = CodexGitRepository(workspaceURL: workspaceURL)
        self.lastTurnSession = lastTurnSession
        applyLastTurn()
    }

    public var files: [CodexGitReviewFileChange] {
        let files = snapshot?.files ?? []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter {
            $0.path.localizedCaseInsensitiveContains(query)
                || ($0.previousPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public var selectedFile: CodexGitReviewFileChange? {
        guard let selectedFileID else { return files.first }
        return snapshot?.file(id: selectedFileID)
    }

    public var selectedPatch: CodexGitReviewPatchText? {
        guard case .ready(let patch) = patchState else { return nil }
        return patch
    }

    public var viewedCount: Int {
        viewedFileIDs.count
    }

    public var viewedFileIDs: Set<String> {
        guard let revision = snapshot?.revision else { return [] }
        return Set(viewedFileRevisionByID.compactMap { id, viewedRevision in
            viewedRevision == revision ? id : nil
        })
    }

    public var canMutateSelectedFile: Bool {
        canUseGitActions
            && selectedFile != nil
            && operationTitle == nil
    }

    public var canUseGitActions: Bool {
        [.uncommitted, .unstaged, .staged].contains(source)
    }

    public var emptyDetail: String {
        if source == .lastTurn {
            return "The latest turn did not produce file changes."
        }
        return "There are no files in the selected review source."
    }

    public var comparisonLabel: String? {
        switch source {
        case .branch:
            return baseBranch.nilIfBlank.map { "Base: \($0)" } ?? "Choose base"
        case .committed:
            return "Commit: \(commitRef.nilIfBlank ?? "HEAD")"
        default:
            return nil
        }
    }

    public var actionState: CodexGitReviewActionState? {
        guard canUseGitActions, let snapshot else { return nil }
        return CodexGitReviewSession(
            snapshot: snapshot,
            commitDraft: CodexGitCommitDraft(
                message: commitMessage,
                includeUnstaged: includeUnstaged
            )
        ).actionState
    }

    public func selectSource(_ source: CodexGitReviewSource) {
        guard self.source != source else { return }
        self.source = source
        snapshot = nil
        selectedFileID = nil
        patchState = .idle
        if source == .lastTurn {
            cancelRefresh()
            applyLastTurn()
        } else {
            refresh()
        }
    }

    public func refresh() {
        guard source != .lastTurn else {
            applyLastTurn()
            return
        }
        generation &+= 1
        let requestGeneration = generation
        let requestSource = source
        refreshTask?.cancel()
        patchTask?.cancel()
        loadState = .loading
        operationError = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    refreshTask = nil
                }
            }
            do {
                let requestedBase = baseBranch.nilIfBlank
                let requestedCommit = commitRef.nilIfBlank
                let snapshot = try await repository.snapshot(
                    source: requestSource,
                    baseRef: requestedBase,
                    commitRef: requestedCommit
                )
                try Task.checkCancellation()
                guard generation == requestGeneration, source == requestSource else { return }
                self.snapshot = snapshot
                if requestSource == .branch {
                    baseBranch = snapshot.comparisonRef ?? baseBranch
                } else if requestSource == .committed {
                    commitRef = snapshot.comparisonRef ?? commitRef
                }
                loadState = .ready
                reconcileSelection()
                loadSelectedPatch()
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration, source == requestSource else { return }
                snapshot = nil
                loadState = .failed(error.localizedDescription)
                patchState = .idle
            }
        }
    }

    public func selectFile(id: String) {
        guard selectedFileID != id else { return }
        selectedFileID = id
        loadSelectedPatch()
    }

    public func selectFile(path: String) {
        guard let file = snapshot?.files.first(where: { $0.path == path }) else { return }
        selectFile(id: file.id)
    }

    public func retrySelectedPatch() {
        loadSelectedPatch()
    }

    public func selectBaseBranch(_ branch: String) {
        baseBranch = branch
        selectedFileID = nil
        refresh()
    }

    public func applyCommitRef() {
        selectedFileID = nil
        refresh()
    }

    public func moveSelection(_ offset: Int) {
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.id == selectedFileID } ?? 0
        let next = min(max(0, current + offset), files.count - 1)
        selectFile(id: files[next].id)
    }

    public func toggleViewed(_ fileID: String) {
        guard let revision = snapshot?.revision else { return }
        if viewedFileRevisionByID[fileID] == revision {
            viewedFileRevisionByID.removeValue(forKey: fileID)
        } else {
            viewedFileRevisionByID[fileID] = revision
        }
    }

    public func stageSelected() {
        guard let selectedFile else { return }
        perform(.stage(paths: [selectedFile.path]))
    }

    public func unstageSelected() {
        guard let selectedFile else { return }
        perform(.unstage(paths: [selectedFile.path]))
    }

    public func stageAll() {
        let paths = snapshot?.files.filter { $0.stagingState.hasUnstagedChanges }.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        perform(.stage(paths: paths))
    }

    public func unstageAll() {
        let paths = snapshot?.files.filter { $0.stagingState.hasStagedChanges }.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        perform(.unstage(paths: paths))
    }

    public func revertAllTrackedFiles() {
        let paths = snapshot?.files.filter { $0.status != .untracked }.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        perform(.revertTracked(paths: paths))
    }

    public func revertSelectedTrackedFile() {
        guard let selectedFile else { return }
        perform(.revertTracked(paths: [selectedFile.path]))
    }

    public func createBranch() {
        perform(.createBranch(name: branchName))
    }

    public func checkoutBranch(_ name: String) {
        perform(.checkoutBranch(name: name))
    }

    public func commit() {
        perform(.commit(message: commitMessage, includeUnstaged: includeUnstaged))
    }

    public func commitAndPush() {
        perform(.commitAndPush(message: commitMessage, includeUnstaged: includeUnstaged))
    }

    public func push() {
        perform(.push)
    }

    public func createDraftPullRequest() {
        perform(.createDraftPullRequest(
            title: pullRequestTitle,
            body: pullRequestBody
        ))
    }

    public func loadPullRequest() {
        pullRequestGeneration &+= 1
        let requestGeneration = pullRequestGeneration
        pullRequestTask?.cancel()
        pullRequestState = .loading
        pullRequestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pullRequestGeneration == requestGeneration {
                    pullRequestTask = nil
                }
            }
            do {
                let details = try await repository.pullRequest()
                try Task.checkCancellation()
                guard pullRequestGeneration == requestGeneration else { return }
                pullRequestState = details.map(PullRequestState.ready) ?? .notFound
            } catch is CancellationError {
                return
            } catch {
                guard pullRequestGeneration == requestGeneration else { return }
                pullRequestState = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelPullRequestLoad() {
        pullRequestGeneration &+= 1
        pullRequestTask?.cancel()
        pullRequestTask = nil
        if pullRequestState == .loading {
            pullRequestState = .idle
        }
    }

    public func cancelOperation() {
        operationTask?.cancel()
    }

    public func cancelAll() {
        generation &+= 1
        operationGeneration &+= 1
        pullRequestGeneration &+= 1
        refreshTask?.cancel()
        patchTask?.cancel()
        operationTask?.cancel()
        pullRequestTask?.cancel()
        refreshTask = nil
        patchTask = nil
        operationTask = nil
        pullRequestTask = nil
        if loadState == .loading {
            loadState = snapshot == nil ? .idle : .ready
        }
        if patchState == .loading {
            patchState = .idle
        }
        if pullRequestState == .loading {
            pullRequestState = .idle
        }
        operationTitle = nil
    }

    public func dismissOperationMessage() {
        operationMessage = nil
        operationError = nil
        operationURL = nil
    }

    private func perform(_ mutation: CodexGitMutation) {
        guard canUseGitActions,
              let revision = snapshot?.revision,
              operationTask == nil else { return }
        operationTitle = mutation.progressTitle
        operationMessage = nil
        operationError = nil
        operationURL = nil
        let requestSource = source
        operationGeneration &+= 1
        let requestGeneration = operationGeneration
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if operationGeneration == requestGeneration {
                    operationTitle = nil
                    operationTask = nil
                }
            }
            do {
                let result = try await repository.mutate(
                    mutation,
                    expectedRevision: revision,
                    source: requestSource
                )
                try Task.checkCancellation()
                guard operationGeneration == requestGeneration else { return }
                operationMessage = result.message
                operationURL = result.externalURL
                if case .commit = mutation {
                    commitMessage = ""
                } else if case .commitAndPush = mutation {
                    commitMessage = ""
                } else if case .createDraftPullRequest = mutation {
                    pullRequestState = .idle
                }
                refresh()
            } catch is CancellationError {
                guard operationGeneration == requestGeneration else { return }
                operationMessage = "Operation cancelled. Repository state will be refreshed."
                refresh()
            } catch {
                guard operationGeneration == requestGeneration else { return }
                operationError = error.localizedDescription
                refresh()
            }
        }
    }

    private func applyLastTurn() {
        snapshot = lastTurnSession?.snapshot
        loadState = .ready
        reconcileSelection()
        loadSelectedPatch()
    }

    private func reconcileSelection() {
        let available = snapshot?.files ?? []
        if let selectedFileID, available.contains(where: { $0.id == selectedFileID }) {
            return
        }
        selectedFileID = available.first?.id
    }

    private func loadSelectedPatch() {
        patchTask?.cancel()
        guard let file = selectedFile else {
            patchState = .idle
            return
        }
        let cacheKey = "\(source.rawValue):\(snapshot?.revision.value ?? 0):\(file.id)"
        if let cached = patchCache[cacheKey] {
            patchState = .ready(cached)
            return
        }
        if source == .lastTurn {
            let patch = file.patchText
            cache(patch, key: cacheKey)
            patchState = .ready(patch)
            return
        }
        let requestSource = source
        let fileID = file.id
        let path = file.path
        patchState = .loading
        patchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await repository.patch(
                    source: requestSource,
                    path: path,
                    baseRef: baseBranch.nilIfBlank,
                    commitRef: commitRef.nilIfBlank
                )
                try Task.checkCancellation()
                guard source == requestSource, selectedFileID == fileID else { return }
                cache(patch, key: cacheKey)
                patchState = .ready(patch)
            } catch is CancellationError {
                return
            } catch {
                guard source == requestSource, selectedFileID == fileID else { return }
                patchState = .failed(error.localizedDescription)
            }
        }
    }

    private func cache(_ patch: CodexGitReviewPatchText, key: String) {
        patchCache[key] = patch
        patchCacheOrder.removeAll { $0 == key }
        patchCacheOrder.append(key)
        while patchCacheOrder.count > maximumCachedPatches {
            patchCache.removeValue(forKey: patchCacheOrder.removeFirst())
        }
    }

    private func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }
}
