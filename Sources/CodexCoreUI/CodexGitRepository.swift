import Foundation

public enum CodexGitReviewSource: String, CaseIterable, Identifiable, Sendable {
    case lastTurn
    case uncommitted
    case unstaged
    case staged
    case branch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastTurn: "Last Turn"
        case .uncommitted: "Uncommitted"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .branch: "Branch"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .lastTurn: "No changes in the last turn"
        case .uncommitted: "No uncommitted changes"
        case .unstaged: "No unstaged changes"
        case .staged: "No staged changes"
        case .branch: "No branch changes"
        }
    }
}

public enum CodexGitMutation: Sendable, Equatable {
    case stage(paths: [String])
    case unstage(paths: [String])
    case revertTracked(paths: [String])
    case createBranch(name: String)
    case checkoutBranch(name: String)
    case commit(message: String, includeUnstaged: Bool)
    case push
    case createDraftPullRequest(title: String, body: String)

    var progressTitle: String {
        switch self {
        case .stage: "Staging files"
        case .unstage: "Unstaging files"
        case .revertTracked: "Reverting files"
        case .createBranch: "Creating branch"
        case .checkoutBranch: "Switching branch"
        case .commit: "Creating commit"
        case .push: "Pushing branch"
        case .createDraftPullRequest: "Creating draft pull request"
        }
    }
}

public struct CodexGitMutationResult: Sendable, Equatable {
    public let message: String
    public let externalURL: URL?

    public init(message: String, externalURL: URL? = nil) {
        self.message = message
        self.externalURL = externalURL
    }
}

public enum CodexGitRepositoryError: LocalizedError, Equatable {
    case notRepository
    case stale(expected: CodexGitReviewRevision, actual: CodexGitReviewRevision)
    case unsafePath(String)
    case destructiveUntrackedPath(String)
    case commandFailed(command: String, message: String)
    case outputLimitExceeded(command: String)

    public var errorDescription: String? {
        switch self {
        case .notRepository:
            "The selected workspace is not a Git repository."
        case .stale:
            "The repository changed while this action was being prepared. Refresh and try again."
        case .unsafePath(let path):
            "Refusing to operate on a path outside the worktree: \(path)"
        case .destructiveUntrackedPath(let path):
            "Refusing to discard untracked file \(path). Move it to Trash explicitly."
        case .commandFailed(let command, let message):
            "\(command) failed: \(message)"
        case .outputLimitExceeded(let command):
            "\(command) exceeded the bounded output limit."
        }
    }
}

/// Off-main, serialized Git observation and mutation boundary for Review.
///
/// Rendering never calls this actor. The workbench explicitly invokes reads or
/// mutations from cancellable tasks, and every mutation checks the exact
/// revision that was shown to the user before it changes the repository.
public actor CodexGitRepository {
    public static let maximumMetadataBytes = 4 * 1_024 * 1_024
    public static let maximumPatchBytes = 256 * 1_024

    private let requestedWorkspaceURL: URL
    private var rootURL: URL?

    public init(workspaceURL: URL) {
        requestedWorkspaceURL = workspaceURL.standardizedFileURL
    }

    public func snapshot(source: CodexGitReviewSource) async throws -> CodexGitReviewSnapshot {
        precondition(source != .lastTurn, "Last Turn comes from canonical transcript state")
        _ = try await repositoryRoot()
        async let branchResult = optional(["symbolic-ref", "--quiet", "--short", "HEAD"])
        async let upstreamResult = optional(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        async let branchesResult = run(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        async let statusResult = run(["status", "--porcelain=v2", "-z", "--branch"])

        let branch = try await branchResult?.stdout.nilIfBlank ?? "HEAD"
        let upstream = try await upstreamResult?.stdout.nilIfBlank
        let status = try await statusResult
        let branchNames = try await branchesResult.stdout
            .split(separator: "\n")
            .map(String.init)
        let revision = revision(
            source: source,
            branch: branch,
            status: status.stdout
        )
        let files = try await files(
            source: source,
            upstream: upstream,
            status: status.stdout
        )
        let unpushedCount: Int
        if upstream != nil,
           let result = try await optional(["rev-list", "--count", "@{upstream}..HEAD"]) {
            unpushedCount = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else {
            unpushedCount = 0
        }
        return CodexGitReviewSnapshot(
            revision: revision,
            branchName: branch,
            upstreamBranchName: upstream,
            branchOptions: branchNames.map {
                CodexGitBranchPickerOption(branchName: $0, isCurrent: $0 == branch)
            },
            files: files,
            unpushedCommitCount: unpushedCount
        )
    }

    public func patch(
        source: CodexGitReviewSource,
        path: String
    ) async throws -> CodexGitReviewPatchText {
        let safePath = try await validatedPath(path)
        let relativePath = safePath.path.replacingOccurrences(
            of: try await repositoryRoot().path + "/",
            with: ""
        )
        if (source == .unstaged || source == .uncommitted),
           try await untrackedPaths().contains(relativePath) {
            return try untrackedPatch(url: safePath, relativePath: relativePath)
        }
        let arguments = try await diffArguments(
            source: source,
            paths: [relativePath],
            outputOptions: ["--binary"]
        )
        do {
            let result = try await run(
                arguments,
                maximumOutputBytes: Self.maximumPatchBytes
            )
            return CodexGitReviewPatchText.bounded(fullText: result.stdout)
        } catch CodexGitRepositoryError.outputLimitExceeded {
            let result = try await run(
                arguments,
                maximumOutputBytes: Self.maximumPatchBytes,
                allowTruncation: true
            )
            return CodexGitReviewPatchText(
                fullText: result.stdout,
                displayText: result.stdout,
                isTruncated: true
            )
        }
    }

    public func mutate(
        _ mutation: CodexGitMutation,
        expectedRevision: CodexGitReviewRevision,
        source: CodexGitReviewSource
    ) async throws -> CodexGitMutationResult {
        let actual = try await currentRevision(source: source)
        guard actual == expectedRevision else {
            throw CodexGitRepositoryError.stale(expected: expectedRevision, actual: actual)
        }
        switch mutation {
        case .stage(let paths):
            try await run(["add", "--"] + (try await validatedRelativePaths(paths)))
            return .init(message: "Staged \(paths.count) file\(paths.count == 1 ? "" : "s").")
        case .unstage(let paths):
            try await run(["restore", "--staged", "--"] + (try await validatedRelativePaths(paths)))
            return .init(message: "Unstaged \(paths.count) file\(paths.count == 1 ? "" : "s").")
        case .revertTracked(let paths):
            let safe = try await validatedRelativePaths(paths)
            let untracked = Set(try await untrackedPaths())
            if let path = safe.first(where: { untracked.contains($0) }) {
                throw CodexGitRepositoryError.destructiveUntrackedPath(path)
            }
            try await run(["restore", "--worktree", "--"] + safe)
            return .init(message: "Reverted \(paths.count) tracked file\(paths.count == 1 ? "" : "s").")
        case .createBranch(let name):
            try await run(["switch", "-c", try validatedBranchName(name)])
            return .init(message: "Created and switched to \(name).")
        case .checkoutBranch(let name):
            try await run(["switch", try validatedBranchName(name)])
            return .init(message: "Switched to \(name).")
        case .commit(let message, let includeUnstaged):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CodexGitRepositoryError.commandFailed(
                    command: "git commit",
                    message: "Commit message is required."
                )
            }
            if includeUnstaged {
                try await run(["add", "-A"])
            }
            try await run(["commit", "-m", trimmed])
            return .init(message: "Commit created.")
        case .push:
            let result = try await run(["push", "--porcelain"])
            return .init(message: result.stdout.nilIfBlank ?? "Branch pushed.")
        case .createDraftPullRequest(let title, let body):
            let result = try await runExecutable(
                "gh",
                arguments: [
                    "pr", "create", "--draft",
                    "--title", title,
                    "--body", body,
                ],
                maximumOutputBytes: 128 * 1_024
            )
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                message: "Draft pull request created.",
                externalURL: URL(string: value.split(separator: "\n").last.map(String.init) ?? "")
            )
        }
    }

    private func files(
        source: CodexGitReviewSource,
        upstream: String?,
        status: String
    ) async throws -> [CodexGitReviewFileChange] {
        let namesArguments = try await diffArguments(
            source: source,
            paths: [],
            outputOptions: ["--name-status", "-z"]
        )
        let statsArguments = try await diffArguments(
            source: source,
            paths: [],
            outputOptions: ["--numstat", "-z"]
        )
        async let namesResult = run(namesArguments)
        async let statsResult = run(statsArguments)
        let names = try await parseNameStatus(namesResult.stdout)
        let stats = try await parseNumstat(statsResult.stdout)
        let stagedPaths: Set<String>
        let unstagedPaths: Set<String>
        if source == .uncommitted {
            async let stagedResult = run([
                "diff", "--no-ext-diff", "--find-renames", "--cached", "--name-only", "-z",
            ])
            async let unstagedResult = run([
                "diff", "--no-ext-diff", "--find-renames", "--name-only", "-z",
            ])
            stagedPaths = try await Set(stagedResult.stdout.split(separator: "\0").map(String.init))
            unstagedPaths = try await Set(unstagedResult.stdout.split(separator: "\0").map(String.init))
        } else {
            stagedPaths = source == .staged ? Set(names.map(\.path)) : []
            unstagedPaths = source == .staged ? [] : Set(names.map(\.path))
        }
        var files = names.map { entry in
            let count = stats[entry.path] ?? (0, 0)
            let stagingState: CodexGitStagingState
            if stagedPaths.contains(entry.path), unstagedPaths.contains(entry.path) {
                stagingState = .partiallyStaged
            } else if stagedPaths.contains(entry.path) {
                stagingState = .staged
            } else {
                stagingState = .unstaged
            }
            return CodexGitReviewFileChange(
                id: "\(source.rawValue):\(entry.path)",
                path: entry.path,
                previousPath: entry.previousPath,
                status: entry.status,
                isStaged: stagingState == .staged,
                stagingState: stagingState,
                addedLines: count.0,
                removedLines: count.1,
                isBinary: count.0 == 0 && count.1 == 0 && stats[entry.path] == nil
            )
        }
        if source == .unstaged || source == .uncommitted {
            let known = Set(files.map(\.path))
            files.append(contentsOf: try await untrackedPaths()
                .filter { !known.contains($0) }
                .map {
                    CodexGitReviewFileChange(
                        id: "\(source.rawValue):\($0)",
                        path: $0,
                        status: .untracked,
                        isStaged: false
                    )
                })
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func diffArguments(
        source: CodexGitReviewSource,
        paths: [String],
        outputOptions: [String] = []
    ) async throws -> [String] {
        // Output modes must precede the revision. Appending them after `HEAD`
        // can make Git emit both a patch and metadata, needlessly filling the
        // process pipe for binary files.
        var result = ["diff", "--no-ext-diff", "--find-renames"] + outputOptions
        switch source {
        case .lastTurn:
            preconditionFailure("Last Turn is canonical transcript state")
        case .unstaged:
            break
        case .staged:
            result.append("--cached")
        case .uncommitted:
            result.append("HEAD")
        case .branch:
            if let upstream = try await optional([
                "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
            ])?.stdout.nilIfBlank {
                result.append(upstream)
            } else {
                result.append("HEAD^")
            }
        }
        if !paths.isEmpty {
            result.append("--")
            result.append(contentsOf: paths)
        }
        return result
    }

    private func currentRevision(source: CodexGitReviewSource) async throws -> CodexGitReviewRevision {
        let branch = try await optional(["symbolic-ref", "--quiet", "--short", "HEAD"])?.stdout.nilIfBlank ?? "HEAD"
        let status = try await run(["status", "--porcelain=v2", "-z", "--branch"])
        return revision(source: source, branch: branch, status: status.stdout)
    }

    private func revision(
        source: CodexGitReviewSource,
        branch: String,
        status: String
    ) -> CodexGitReviewRevision {
        var fingerprint = CodexStableFingerprint()
        fingerprint.combine(source.rawValue)
        fingerprint.combine(branch)
        fingerprint.combine(status)
        return .init(sourceID: "git/\(source.rawValue)", value: fingerprint.value)
    }

    private func repositoryRoot() async throws -> URL {
        if let rootURL { return rootURL }
        guard let root = try await optional(["rev-parse", "--show-toplevel"])?.stdout.nilIfBlank else {
            throw CodexGitRepositoryError.notRepository
        }
        let url = URL(fileURLWithPath: root).standardizedFileURL
        rootURL = url
        return url
    }

    private func validatedRelativePaths(_ paths: [String]) async throws -> [String] {
        let root = try await repositoryRoot()
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for path in paths {
            let safe = try await validatedPath(path)
            result.append(String(safe.path.dropFirst(root.path.count + 1)))
        }
        return result
    }

    private func validatedPath(_ path: String) async throws -> URL {
        let root = try await repositoryRoot()
        let candidate = root.appending(path: path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate.path != root.path else {
            throw CodexGitRepositoryError.unsafePath(path)
        }
        return candidate
    }

    private func validatedBranchName(_ name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              (try await optional(["check-ref-format", "--branch", trimmed])) != nil else {
            throw CodexGitRepositoryError.commandFailed(
                command: "git check-ref-format",
                message: "Invalid branch name."
            )
        }
        return trimmed
    }

    private func untrackedPaths() async throws -> [String] {
        try await run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
            .split(separator: "\0")
            .map(String.init)
    }

    private func untrackedPatch(
        url: URL,
        relativePath: String
    ) throws -> CodexGitReviewPatchText {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = Self.maximumPatchBytes
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let retained = data.prefix(limit)
        let truncated = data.count > limit
        if retained.contains(0) {
            return CodexGitReviewPatchText(
                fullText: "Binary files /dev/null and b/\(relativePath) differ",
                displayText: "Binary files /dev/null and b/\(relativePath) differ",
                isTruncated: truncated
            )
        }
        let content = String(decoding: retained, as: UTF8.self)
        let body = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+\($0)" }
            .joined(separator: "\n")
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let patch = """
        diff --git a/\(relativePath) b/\(relativePath)
        new file mode 100644
        --- /dev/null
        +++ b/\(relativePath)
        @@ -0,0 +1,\(lineCount) @@
        \(body)
        """
        return CodexGitReviewPatchText(
            fullText: patch,
            displayText: patch,
            isTruncated: truncated
        )
    }

    private struct NameStatus {
        var path: String
        var previousPath: String?
        var status: CodexGitReviewFileStatus
    }

    private func parseNameStatus(_ output: String) -> [NameStatus] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [NameStatus] = []
        var index = 0
        while index < fields.count {
            let code = fields[index]
            index += 1
            guard index < fields.count else { break }
            let firstPath = fields[index]
            index += 1
            if code.hasPrefix("R") || code.hasPrefix("C") {
                guard index < fields.count else { break }
                let destination = fields[index]
                index += 1
                result.append(.init(path: destination, previousPath: firstPath, status: .renamed))
            } else {
                let status: CodexGitReviewFileStatus = switch code.first {
                case "A": .added
                case "D": .deleted
                default: .modified
                }
                result.append(.init(path: firstPath, previousPath: nil, status: status))
            }
        }
        return result
    }

    private func parseNumstat(_ output: String) -> [String: (Int, Int)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [String: (Int, Int)] = [:]
        var index = 0
        while index < fields.count {
            let header = fields[index]
            index += 1
            guard !header.isEmpty else { continue }
            let components = header.split(separator: "\t", omittingEmptySubsequences: false)
            guard components.count >= 3 else { continue }
            let added = Int(components[0]) ?? 0
            let removed = Int(components[1]) ?? 0
            if !components[2].isEmpty {
                result[String(components[2])] = (added, removed)
            } else if index + 1 < fields.count {
                _ = fields[index]
                let destination = fields[index + 1]
                index += 2
                result[destination] = (added, removed)
            }
        }
        return result
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        maximumOutputBytes: Int = CodexGitRepository.maximumMetadataBytes,
        allowTruncation: Bool = false
    ) async throws -> CodexGitCommandResult {
        try Task.checkCancellation()
        return try await runExecutable(
            "/usr/bin/git",
            arguments: arguments,
            maximumOutputBytes: maximumOutputBytes,
            allowTruncation: allowTruncation
        )
    }

    private func optional(_ arguments: [String]) async throws -> CodexGitCommandResult? {
        do {
            return try await run(arguments)
        } catch CodexGitRepositoryError.commandFailed {
            return nil
        }
    }

    private func runExecutable(
        _ executable: String,
        arguments: [String],
        maximumOutputBytes: Int,
        allowTruncation: Bool = false
    ) async throws -> CodexGitCommandResult {
        let root = rootURL ?? requestedWorkspaceURL
        let command = ([executable] + arguments).joined(separator: " ")
        return try await CodexBoundedProcess.run(
            executable: executable,
            arguments: arguments,
            directory: root,
            maximumOutputBytes: maximumOutputBytes,
            allowTruncation: allowTruncation,
            commandDescription: command
        )
    }
}

private struct CodexGitCommandResult: Sendable {
    var stdout: String
    var stderr: String
}

private final class CodexBoundedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        maximumOutputBytes: Int,
        allowTruncation: Bool,
        commandDescription: String
    ) async throws -> CodexGitCommandResult {
        let runner = CodexBoundedProcess()
        return try await withTaskCancellationHandler {
            try await runner.start(
                executable: executable,
                arguments: arguments,
                directory: directory,
                maximumOutputBytes: maximumOutputBytes,
                allowTruncation: allowTruncation,
                commandDescription: commandDescription
            )
        } onCancel: {
            runner.cancel()
        }
    }

    private func start(
        executable: String,
        arguments: [String],
        directory: URL,
        maximumOutputBytes: Int,
        allowTruncation: Bool,
        commandDescription: String
    ) async throws -> CodexGitCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = executable.hasPrefix("/")
                ? URL(fileURLWithPath: executable)
                : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = executable.hasPrefix("/")
                ? arguments
                : [executable] + arguments
            process.currentDirectoryURL = directory
            process.standardOutput = standardOutput
            process.standardError = standardError
            self.lock.withLock { self.process = process }
            try process.run()
            // Process inherits duplicated write descriptors. Closing the
            // parent's copies is required for the async readers to observe EOF.
            try standardOutput.fileHandleForWriting.close()
            try standardError.fileHandleForWriting.close()
            async let outputData = Self.readBounded(
                standardOutput.fileHandleForReading,
                limit: maximumOutputBytes
            )
            async let errorData = Self.readBounded(
                standardError.fileHandleForReading,
                limit: 128 * 1_024
            )
            let output = try await outputData
            let error = try await errorData
            process.waitUntilExit()
            self.lock.withLock { self.process = nil }
            try Task.checkCancellation()
            if output.wasTruncated, !allowTruncation {
                throw CodexGitRepositoryError.outputLimitExceeded(command: commandDescription)
            }
            let stdout = String(decoding: output.data, as: UTF8.self)
            let stderr = String(decoding: error.data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw CodexGitRepositoryError.commandFailed(
                    command: commandDescription,
                    message: stderr.nilIfBlank ?? stdout.nilIfBlank ?? "Exit \(process.terminationStatus)"
                )
            }
            return CodexGitCommandResult(stdout: stdout, stderr: stderr)
        }.value
    }

    private func cancel() {
        lock.withLock {
            guard let process, process.isRunning else { return }
            process.interrupt()
            process.terminate()
        }
    }

    private static func readBounded(
        _ handle: FileHandle,
        limit: Int
    ) async throws -> (data: Data, wasTruncated: Bool) {
        var data = Data()
        var truncated = false
        for try await byte in handle.bytes {
            if data.count < limit {
                data.append(byte)
            } else {
                truncated = true
            }
        }
        return (data, truncated)
    }
}
