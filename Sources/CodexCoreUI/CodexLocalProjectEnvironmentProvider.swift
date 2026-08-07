import Foundation

public enum CodexLocalProjectEnvironmentError: LocalizedError, Equatable, Sendable {
    case notRepository
    case dirtyBranchSwitch(Int)
    case invalidBranch
    case targetExists(String)
    case targetInsideSource
    case commandFailed(String)
    case recoveryRequired(String)

    public var errorDescription: String? {
        switch self {
        case .notRepository:
            "The selected workspace is not a Git repository."
        case .dirtyBranchSwitch(let count):
            "Switching branches is disabled while \(count) file\(count == 1 ? " is" : "s are") uncommitted."
        case .invalidBranch:
            "Enter a valid, unused branch name."
        case .targetExists(let path):
            "The worktree destination already exists: \(path)"
        case .targetInsideSource:
            "The worktree destination must be outside the source repository."
        case .commandFailed(let message):
            message
        case .recoveryRequired(let message):
            "The handoff could not finish safely. \(message)"
        }
    }
}

/// Local Git boundary for the Environment surface.
///
/// Reads and mutations are serialized by CodexGitRepository, which applies
/// bounded process output, branch/path validation, revision checks, and Git
/// operation safety markers. Dirty handoff retains a named stash until the
/// destination worktree has been verified.
public actor CodexLocalProjectEnvironmentProvider: CodexProjectEnvironmentProviding {
    private let workspaceURL: URL
    private let repository: CodexGitRepository

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.repository = CodexGitRepository(workspaceURL: workspaceURL)
    }

    public func repositorySnapshot() async throws -> CodexProjectEnvironmentRepositorySnapshot {
        do {
            let snapshot = try await repository.snapshot(source: .uncommitted)
            return CodexProjectEnvironmentRepositorySnapshot(
                branchName: snapshot.branchName.nilIfBlank,
                branches: snapshot.branchOptions.map(\.branchName),
                dirtyFileCount: snapshot.files.count
            )
        } catch let error as CodexGitRepositoryError {
            throw map(error)
        }
    }

    public func checkoutBranch(_ branchName: String) async throws -> CodexProjectEnvironmentRepositorySnapshot {
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw CodexLocalProjectEnvironmentError.invalidBranch }

        do {
            let snapshot = try await repository.snapshot(source: .uncommitted)
            guard snapshot.files.isEmpty else {
                throw CodexLocalProjectEnvironmentError.dirtyBranchSwitch(snapshot.files.count)
            }
            guard snapshot.branchOptions.contains(where: { $0.branchName == branch }) else {
                throw CodexLocalProjectEnvironmentError.invalidBranch
            }
            _ = try await repository.mutate(
                .checkoutBranch(name: branch),
                expectedRevision: snapshot.revision,
                source: .uncommitted
            )
            return try await repositorySnapshot()
        } catch let error as CodexLocalProjectEnvironmentError {
            throw error
        } catch let error as CodexGitRepositoryError {
            throw map(error)
        }
    }

    public func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        let source = URL(fileURLWithPath: request.sourcePath).standardizedFileURL
        let target = URL(fileURLWithPath: request.targetPath).standardizedFileURL
        guard source.path == workspaceURL.path else {
            throw CodexLocalProjectEnvironmentError.notRepository
        }
        guard target.path != source.path, !target.path.hasPrefix(source.path + "/") else {
            throw CodexLocalProjectEnvironmentError.targetInsideSource
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw CodexLocalProjectEnvironmentError.targetExists(target.path)
        }

        do {
            return try await repository.handOffToWorktree(request)
        } catch let error as CodexLocalProjectEnvironmentError {
            throw error
        } catch let error as CodexGitRepositoryError {
            throw map(error)
        }
    }

    private func map(_ error: CodexGitRepositoryError) -> CodexLocalProjectEnvironmentError {
        switch error {
        case .notRepository:
            return .notRepository
        case .commandFailed(_, let message):
            if message.localizedCaseInsensitiveContains("already-existing")
                || message.localizedCaseInsensitiveContains("already-existing branch")
                || message.localizedCaseInsensitiveContains("already exists") {
                return .invalidBranch
            }
            return .commandFailed(message)
        case .partialSuccess(let detail):
            return .recoveryRequired(detail)
        default:
            return .commandFailed(error.localizedDescription)
        }
    }
}
