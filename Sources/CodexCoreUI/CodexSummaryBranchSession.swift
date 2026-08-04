import Foundation
import Observation

/// Branch reads and switching for the task summary's branch control.
///
/// The official bundle puts a live branch picker behind that row rather than a
/// label. This session owns the same capability for the summary panel: it does
/// no Git work until the control is opened, and every mutation still goes
/// through the serialized repository actor with an expected-revision check.
@MainActor
@Observable
public final class CodexSummaryBranchSession {
    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var picker: CodexGitBranchPickerState?
    public private(set) var operationTitle: String?
    public private(set) var operationError: String?
    /// Set once a checkout lands, so the row can show the new branch before the
    /// host's own workspace summary catches up.
    public private(set) var checkedOutBranch: String?
    public var filter = ""
    public var newBranchName = ""

    private let repository: CodexGitRepository
    private var revision: CodexGitReviewRevision?
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var operationGeneration: UInt64 = 0

    public init(workspaceURL: URL) {
        repository = CodexGitRepository(workspaceURL: workspaceURL)
    }

    public var currentBranchName: String? {
        checkedOutBranch ?? picker?.currentBranchName.nilIfBlank
    }

    /// Branches other than the current one, filtered by the search field.
    public var matchingOptions: [CodexGitBranchPickerOption] {
        let options = picker?.options ?? []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { $0.branchName.localizedCaseInsensitiveContains(query) }
    }

    public var canSwitchBranches: Bool {
        picker?.canCreateOrCheckout ?? false
    }

    /// Why switching is unavailable, so a disabled control can say so instead
    /// of going quiet.
    public var switchDisabledReason: String? {
        guard let picker, !picker.canCreateOrCheckout else { return nil }
        return picker.createOrCheckoutDisabledReason
            ?? "Commit or discard changes before switching branches"
    }

    public var isBusy: Bool {
        operationTitle != nil
    }

    public var trimmedNewBranchName: String {
        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canCreateBranch: Bool {
        canSwitchBranches
            && !isBusy
            && !trimmedNewBranchName.isEmpty
            && picker?.options.contains { $0.branchName == trimmedNewBranchName } != true
    }

    /// The reason a typed branch name cannot be created, surfaced while typing.
    public var newBranchNameProblem: String? {
        let name = trimmedNewBranchName
        guard !name.isEmpty else { return nil }
        if picker?.options.contains(where: { $0.branchName == name }) == true {
            return "Branch already exists."
        }
        if name.hasSuffix("/") {
            return "Branch name cannot end with “/”."
        }
        return nil
    }

    public func loadIfNeeded() {
        guard loadState == .idle else { return }
        refresh()
    }

    public func refresh() {
        generation &+= 1
        let requestGeneration = generation
        loadTask?.cancel()
        loadState = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await repository.snapshot(source: .uncommitted)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                picker = snapshot.branchPicker
                revision = snapshot.revision
                checkedOutBranch = nil
                loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    public func checkout(_ branchName: String) {
        perform(.checkoutBranch(name: branchName), switchingTo: branchName)
    }

    public func createAndCheckout() {
        let name = trimmedNewBranchName
        guard canCreateBranch else { return }
        perform(.createBranch(name: name), switchingTo: name)
    }

    /// Stops the branch listing when the control closes. An in-flight checkout
    /// keeps running: the user asked for it, and abandoning it midway would
    /// leave the repository in whatever state Git had reached.
    public func cancelLoad() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        if loadState == .loading {
            loadState = picker == nil ? .idle : .ready
        }
    }

    public func cancelAll() {
        cancelLoad()
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        operationTitle = nil
    }

    public func dismissError() {
        operationError = nil
    }

    private func perform(_ mutation: CodexGitMutation, switchingTo branchName: String) {
        guard let revision, operationTask == nil else { return }
        operationTitle = mutation.progressTitle
        operationError = nil
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
                _ = try await repository.mutate(
                    mutation,
                    expectedRevision: revision,
                    source: .uncommitted
                )
                try Task.checkCancellation()
                guard operationGeneration == requestGeneration else { return }
                newBranchName = ""
                filter = ""
                refresh()
                // The refresh clears this once the new snapshot lands; until
                // then the row already reads as the branch the user picked.
                checkedOutBranch = branchName
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == requestGeneration else { return }
                operationError = error.localizedDescription
                refresh()
            }
        }
    }
}
