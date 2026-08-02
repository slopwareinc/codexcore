import Foundation

public enum CodexLocalProjectEnvironmentError: LocalizedError, Equatable, Sendable {
    case notRepository
    case dirtyBranchSwitch(Int)
    case invalidBranch
    case targetExists(String)
    case commandFailed(String)
    case recoveryRequired(String)

    public var errorDescription: String? {
        switch self {
        case .notRepository:
            "The selected workspace is not a Git repository."
        case .dirtyBranchSwitch(let count):
            "Switching branches is disabled while (count) file\(count == 1 ? " is" : "s are") uncommitted."
        case .invalidBranch:
            "Enter a valid, unused branch name."
        case .targetExists(let path):
            "The worktree destination already exists: \(path)"
        case .commandFailed(let message):
            message
        case .recoveryRequired(let message):
            "The handoff could not finish safely. \(message)"
        }
    }
}

/// Local Git boundary for the Environment surface.
///
/// Dirty handoff uses a named stash as a transaction: source changes are
/// captured (including untracked and staged state), a worktree is created from
/// the same HEAD, and the exact stash object is applied with `--index`. The
/// stash is dropped only after the new worktree contains the changes.
public actor CodexLocalProjectEnvironmentProvider: CodexProjectEnvironmentProviding {
    private let workspaceURL: URL

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
    }

    public func repositorySnapshot() async throws -> CodexProjectEnvironmentRepositorySnapshot {
        let root = try await repositoryRoot()
        let branch = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branches = try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: root)
            .split(separator: "\n").map(String.init)
        let status = try await git(["status", "--porcelain", "-z", "--untracked-files=all"], at: root)
        return .init(
            branchName: branch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            branches: branches,
            dirtyFileCount: status.split(separator: "\0").count
        )
    }

    public func checkoutBranch(_ branchName: String) async throws -> CodexProjectEnvironmentRepositorySnapshot {
        let root = try await repositoryRoot()
        let snapshot = try await repositorySnapshot()
        guard snapshot.dirtyFileCount == 0 else {
            throw CodexLocalProjectEnvironmentError.dirtyBranchSwitch(snapshot.dirtyFileCount)
        }
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.branches.contains(branch) else {
            throw CodexLocalProjectEnvironmentError.invalidBranch
        }
        _ = try await git(["switch", branch], at: root)
        return try await repositorySnapshot()
    }

    public func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        let root = try await repositoryRoot()
        guard URL(fileURLWithPath: request.sourcePath).standardizedFileURL.path == root.path else {
            throw CodexLocalProjectEnvironmentError.notRepository
        }
        let target = URL(fileURLWithPath: request.targetPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw CodexLocalProjectEnvironmentError.targetExists(target.path)
        }
        guard (try? await git(["check-ref-format", "--branch", request.branchName], at: root)) != nil,
              (try? await git(["show-ref", "--verify", "--quiet", "refs/heads/\(request.branchName)"], at: root)) == nil else {
            throw CodexLocalProjectEnvironmentError.invalidBranch
        }

        let status = try await git(["status", "--porcelain", "-z", "--untracked-files=all"], at: root)
        let hasChanges = !status.isEmpty
        var stashOID: String?
        if hasChanges {
            _ = try await git([
                "stash", "push", "--include-untracked", "--message",
                "Codex worktree handoff: \(request.branchName)",
            ], at: root)
            stashOID = try await git(["rev-parse", "refs/stash"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            _ = try await git(["worktree", "add", "-b", request.branchName, target.path, "HEAD"], at: root)
        } catch {
            if let stashOID {
                _ = try? await git(["stash", "apply", "--index", stashOID], at: root)
                _ = try? await dropStash(stashOID, root: root)
            }
            throw error
        }

        if let stashOID {
            do {
                _ = try await git(["stash", "apply", "--index", stashOID], at: target)
                let transferred = try await git(["status", "--porcelain", "-z", "--untracked-files=all"], at: target)
                guard !transferred.isEmpty else {
                    throw CodexLocalProjectEnvironmentError.recoveryRequired(
                        "The captured changes remain in stash \(stashOID)."
                    )
                }
                _ = try await dropStash(stashOID, root: root)
            } catch {
                // Never drop the recovery object after a failed apply. Restore
                // the source as well; duplicated changes are safer than loss.
                _ = try? await git(["stash", "apply", "--index", stashOID], at: root)
                throw CodexLocalProjectEnvironmentError.recoveryRequired(
                    "Changes were restored in the source and retained in stash \(stashOID). The new worktree is at \(target.path). \(error.localizedDescription)"
                )
            }
        }

        return CodexWorktreeHandoffResult(
            title: request.title,
            branchName: request.branchName,
            worktreePath: target.path
        )
    }

    private func dropStash(_ oid: String, root: URL) async throws -> String {
        let current = try await git(["rev-parse", "refs/stash"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == oid else {
            throw CodexLocalProjectEnvironmentError.recoveryRequired(
                "A newer stash appeared; the handoff stash \(oid) was retained."
            )
        }
        return try await git(["stash", "drop", "stash@{0}"], at: root)
    }

    private func repositoryRoot() async throws -> URL {
        guard let path = try? await git(["rev-parse", "--show-toplevel"], at: workspaceURL)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw CodexLocalProjectEnvironmentError.notRepository
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func git(_ arguments: [String], at directory: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw CodexLocalProjectEnvironmentError.commandFailed(
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                        ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                        ?? "git \(arguments.first ?? "command") failed"
                )
            }
            return stdout
        }.value
    }
}
