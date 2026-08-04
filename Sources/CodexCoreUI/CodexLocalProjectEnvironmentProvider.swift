import Foundation

public enum CodexLocalProjectEnvironmentError: LocalizedError, Equatable, Sendable {
    case notRepository
    case dirtyBranchSwitch(Int)
    case invalidBranch
    case targetExists(String)
    case commandFailed(String)
    case recoveryRequired(String)
    case handoffFailed(message: String, pathOutcomes: [CodexWorktreeHandoffPathOutcome])

    public var pathOutcomes: [CodexWorktreeHandoffPathOutcome] {
        guard case .handoffFailed(_, let pathOutcomes) = self else { return [] }
        return pathOutcomes
    }

    public var errorDescription: String? {
        switch self {
        case .notRepository:
            return "The selected workspace is not a Git repository."
        case .dirtyBranchSwitch(let count):
            return "Switching branches is disabled while \(count) file\(count == 1 ? " is" : "s are") uncommitted."
        case .invalidBranch:
            return "Enter a valid, unused branch name."
        case .targetExists(let path):
            return "The worktree destination already exists: \(path)"
        case .commandFailed(let message):
            return message
        case .recoveryRequired(let message):
            return "The handoff could not finish safely. \(message)"
        case .handoffFailed(let message, let pathOutcomes):
            let summary = pathOutcomes.map {
                "\($0.path): \($0.status.rawValue)"
            }.joined(separator: ", ")
            if summary.isEmpty {
                return "The handoff could not finish safely. \(message)"
            }
            return "The handoff could not finish safely. \(message) Outcomes: \(summary)"
        }
    }
}

/// Local Git boundary for the Environment surface.
///
/// Handoff captures the source diff without changing the source worktree,
/// creates a detached worktree before creating its branch, and transfers
/// untracked files one at a time. The source is never stashed or reset, so a
/// process interruption cannot strand the user's changes in a recovery object.
public actor CodexLocalProjectEnvironmentProvider: CodexProjectEnvironmentProviding {
    private static let maximumCapturedDiffBytes = 16 * 1_024 * 1_024
    private static let maximumCommandOutputBytes = 4 * 1_024 * 1_024

    private let workspaceURL: URL

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
    }

    public func repositorySnapshot() async throws -> CodexProjectEnvironmentRepositorySnapshot {
        let root = try await repositoryRoot()
        let branch = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branches = try await git(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            at: root
        )
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        let status = try await git(
            ["status", "--porcelain", "-z", "--untracked-files=all"],
            at: root
        )
        return .init(
            branchName: branch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            branches: branches,
            dirtyFileCount: Self.nullSeparatedValues(status).count
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
        try await handOffToWorktree(request, progress: { _ in })
    }

    public func handOffToWorktree(
        _ request: CodexWorktreeHandoffRequest,
        progress: @escaping @MainActor @Sendable (CodexWorktreeHandoffProgressStage) -> Void
    ) async throws -> CodexWorktreeHandoffResult {
        await progress(.preparing)
        let source = URL(fileURLWithPath: request.sourcePath).standardizedFileURL
        let root = try await repositoryRoot(at: source)
        let target = URL(fileURLWithPath: request.targetPath).standardizedFileURL
        let branch = request.branchName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw CodexLocalProjectEnvironmentError.targetExists(target.path)
        }
        guard target != root, !target.path.hasPrefix(root.path + "/") else {
            throw CodexLocalProjectEnvironmentError.commandFailed(
                "Choose a worktree destination outside the source repository."
            )
        }
        guard (try? await git(["check-ref-format", "--branch", branch], at: root)) != nil,
              (try? await git([
                  "show-ref", "--verify", "--quiet", "refs/heads/\(branch)",
              ], at: root)) == nil else {
            throw CodexLocalProjectEnvironmentError.invalidBranch
        }

        let startingRef = try await git(["rev-parse", "--verify", "HEAD"], at: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryPrefix = try await git(["rev-parse", "--show-prefix"], at: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let patch = try await git(
            ["diff", "--no-ext-diff", "--find-renames", "--binary", "HEAD", "--"],
            at: source,
            maximumOutputBytes: Self.maximumCapturedDiffBytes
        )
        let trackedPaths = try await trackedChangedPaths(at: source)
        let untrackedPaths = try await untrackedPaths(at: root)
        let allPaths = Array(Set(trackedPaths + untrackedPaths)).sorted()
        var outcomes = allPaths.map {
            CodexWorktreeHandoffPathOutcome(
                path: $0,
                status: .skipped,
                detail: "Not transferred"
            )
        }

        var worktreeAttempted = false
        var branchCreated = false
        do {
            await progress(.creatingWorktree)
            worktreeAttempted = true
            _ = try await git(
                ["worktree", "add", "--detach", target.path, startingRef],
                at: root
            )

            await progress(.creatingBranch)
            _ = try await git(["switch", "-c", branch], at: target)
            branchCreated = true

            await progress(.applyingTrackedChanges)
            if !patch.isEmpty {
                do {
                    _ = try await git(
                        ["apply", "--3way", "--binary", "-"],
                        at: target,
                        stdin: Data(patch.utf8)
                    )
                } catch {
                    outcomes = try await outcomesAfterApplyFailure(
                        paths: trackedPaths,
                        existing: outcomes,
                        at: target
                    )
                    throw CodexLocalProjectEnvironmentError.handoffFailed(
                        message: error.localizedDescription,
                        pathOutcomes: outcomes
                    )
                }

                Self.mark(&outcomes, paths: trackedPaths, as: .applied)
            }

            await progress(.copyingUntrackedFiles)
            for path in untrackedPaths {
                do {
                    try copyUntrackedPath(path, from: root, to: target)
                    Self.mark(&outcomes, paths: [path], as: .applied)
                } catch {
                    Self.mark(
                        &outcomes,
                        paths: [path],
                        as: .skipped,
                        detail: error.localizedDescription
                    )
                    throw CodexLocalProjectEnvironmentError.handoffFailed(
                        message: error.localizedDescription,
                        pathOutcomes: outcomes
                    )
                }
            }

            let workingDirectory = target.appendingPathComponent(
                repositoryPrefix,
                isDirectory: true
            ).standardizedFileURL
            await progress(.finalizing)
            return CodexWorktreeHandoffResult(
                title: request.title,
                branchName: branch,
                worktreePath: target.path,
                workingDirectoryPath: workingDirectory.path,
                pathOutcomes: outcomes
            )
        } catch let error as CodexLocalProjectEnvironmentError {
            let cleanupDetail = await cleanup(
                root: root,
                target: target,
                branch: branch,
                worktreeAttempted: worktreeAttempted,
                branchCreated: branchCreated
            )
            switch error {
            case .handoffFailed(let message, let pathOutcomes):
                let message = Self.appendingCleanupDetail(message, cleanupDetail)
                throw CodexLocalProjectEnvironmentError.handoffFailed(
                    message: message,
                    pathOutcomes: pathOutcomes
                )
            default:
                throw Self.recoveryError(error, cleanupDetail: cleanupDetail)
            }
        } catch {
            let cleanupDetail = await cleanup(
                root: root,
                target: target,
                branch: branch,
                worktreeAttempted: worktreeAttempted,
                branchCreated: branchCreated
            )
            throw CodexLocalProjectEnvironmentError.recoveryRequired(
                Self.appendingCleanupDetail(error.localizedDescription, cleanupDetail)
            )
        }
    }

    private func repositoryRoot() async throws -> URL {
        try await repositoryRoot(at: workspaceURL)
    }

    private func repositoryRoot(at directory: URL) async throws -> URL {
        guard let path = try? await git(["rev-parse", "--show-toplevel"], at: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw CodexLocalProjectEnvironmentError.notRepository
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func trackedChangedPaths(at directory: URL) async throws -> [String] {
        let output = try await git(
            ["diff", "--no-ext-diff", "--find-renames", "--name-only", "-z", "HEAD", "--"],
            at: directory
        )
        return Self.nullSeparatedValues(output)
    }

    private func untrackedPaths(at directory: URL) async throws -> [String] {
        let output = try await git(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: directory
        )
        return Self.nullSeparatedValues(output)
    }

    private func outcomesAfterApplyFailure(
        paths: [String],
        existing: [CodexWorktreeHandoffPathOutcome],
        at directory: URL
    ) async throws -> [CodexWorktreeHandoffPathOutcome] {
        let conflicted: Set<String>
        if let status = try? await git(
            ["status", "--porcelain", "-z", "--untracked-files=all"],
            at: directory
        ) {
            conflicted = Set(
                Self.nullSeparatedValues(status).compactMap(Self.conflictPath)
            )
        } else {
            conflicted = Set(paths)
        }

        var outcomes = existing
        for path in paths {
            if conflicted.contains(path) {
                Self.mark(
                    &outcomes,
                    paths: [path],
                    as: .conflicted,
                    detail: "Git reported a merge conflict."
                )
            } else {
                Self.mark(
                    &outcomes,
                    paths: [path],
                    as: .skipped,
                    detail: "Git did not apply this path."
                )
            }
        }
        return outcomes
    }

    private func copyUntrackedPath(_ path: String, from sourceRoot: URL, to targetRoot: URL) throws {
        let source = try safePath(path, under: sourceRoot)
        let destination = try safePath(path, under: targetRoot)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func safePath(_ path: String, under root: URL) throws -> URL {
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate != root else {
            throw CodexLocalProjectEnvironmentError.commandFailed(
                "Refusing to transfer a path outside the repository: \(path)"
            )
        }
        return candidate
    }

    private func cleanup(
        root: URL,
        target: URL,
        branch: String,
        worktreeAttempted: Bool,
        branchCreated: Bool
    ) async -> String? {
        var failures: [String] = []
        if worktreeAttempted {
            do {
                _ = try await git(["worktree", "remove", "--force", target.path], at: root)
            } catch {
                failures.append("worktree cleanup failed: \(error.localizedDescription)")
            }
        }
        if branchCreated {
            do {
                _ = try await git(["branch", "-D", branch], at: root)
            } catch {
                failures.append("branch cleanup failed: \(error.localizedDescription)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private static func recoveryError(
        _ error: CodexLocalProjectEnvironmentError,
        cleanupDetail: String?
    ) -> CodexLocalProjectEnvironmentError {
        switch error {
        case .recoveryRequired(let message):
            return .recoveryRequired(appendingCleanupDetail(message, cleanupDetail))
        default:
            return .recoveryRequired(
                appendingCleanupDetail(error.localizedDescription, cleanupDetail)
            )
        }
    }

    private static func appendingCleanupDetail(_ message: String, _ cleanupDetail: String?) -> String {
        guard let cleanupDetail else { return message }
        return "\(message) \(cleanupDetail)"
    }

    private static func mark(
        _ outcomes: inout [CodexWorktreeHandoffPathOutcome],
        paths: [String],
        as status: CodexWorktreeHandoffPathStatus,
        detail: String? = nil
    ) {
        let paths = Set(paths)
        for index in outcomes.indices where paths.contains(outcomes[index].path) {
            outcomes[index].status = status
            outcomes[index].detail = detail
        }
    }

    private static func conflictPath(_ record: String) -> String? {
        guard record.count >= 3 else { return nil }
        let code = String(record.prefix(2))
        guard code.contains("U") || code == "AA" || code == "DD" else { return nil }
        return String(record.dropFirst(3))
    }

    private static func nullSeparatedValues(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    private func git(
        _ arguments: [String],
        at directory: URL,
        stdin: Data? = nil,
        maximumOutputBytes: Int = CodexLocalProjectEnvironmentProvider.maximumCommandOutputBytes
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () async throws -> String in
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-git-output-\(UUID().uuidString)")
            let errorURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-git-error-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
                  FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
                throw CodexLocalProjectEnvironmentError.commandFailed(
                    "Unable to create temporary files for git \(arguments.first ?? "command")"
                )
            }
            defer {
                _ = try? FileManager.default.removeItem(at: outputURL)
                _ = try? FileManager.default.removeItem(at: errorURL)
            }

            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            let input = stdin.map { _ in Pipe() }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = output
            process.standardError = error
            if let input {
                process.standardInput = input
            }

            do {
                try process.run()
                if let stdin, let input {
                    try input.fileHandleForWriting.write(contentsOf: stdin)
                    try input.fileHandleForWriting.close()
                }
            } catch {
                throw CodexLocalProjectEnvironmentError.commandFailed(
                    "Unable to run git \(arguments.first ?? "command"): \(error.localizedDescription)"
                )
            }
            process.waitUntilExit()
            try output.close()
            try error.close()

            let fileManager = FileManager.default
            let outputSize = (try fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)
                .map { Int(truncating: $0) } ?? 0
            let errorSize = (try fileManager.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)
                .map { Int(truncating: $0) } ?? 0
            guard outputSize <= maximumOutputBytes,
                  errorSize <= maximumOutputBytes else {
                throw CodexLocalProjectEnvironmentError.commandFailed(
                    "git \(arguments.first ?? "command") produced too much output"
                )
            }
            let stdoutData = try Data(contentsOf: outputURL)
            let stderrData = try Data(contentsOf: errorURL)
            let stdout = String(decoding: stdoutData, as: UTF8.self)
            let stderr = String(decoding: stderrData, as: UTF8.self)
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
