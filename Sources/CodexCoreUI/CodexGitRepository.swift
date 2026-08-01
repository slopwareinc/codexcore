import Foundation

public enum CodexGitReviewSource: String, CaseIterable, Identifiable, Sendable {
    case lastTurn
    case uncommitted
    case unstaged
    case staged
    case committed
    case branch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastTurn: "Last Turn"
        case .uncommitted: "Uncommitted"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .committed: "Committed"
        case .branch: "Branch"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .lastTurn: "No changes in the last turn"
        case .uncommitted: "No uncommitted changes"
        case .unstaged: "No unstaged changes"
        case .staged: "No staged changes"
        case .committed: "No changes in this commit"
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
    case commitAndPush(message: String, includeUnstaged: Bool)
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
        case .commitAndPush: "Committing and pushing"
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
    case unsafeRepositoryState(String)
    case comparisonRequired(String)
    case partialSuccess(String)
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
        case .unsafeRepositoryState(let detail):
            "Git operation blocked while \(detail). Finish or abort that operation, then refresh Review."
        case .comparisonRequired(let detail):
            detail
        case .partialSuccess(let detail):
            detail
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
    public static let maximumVisibleUntrackedFiles = 5_000
    private static let maximumUntrackedMetadataBytes = 512 * 1_024

    private let requestedWorkspaceURL: URL
    private var rootURL: URL?

    public init(workspaceURL: URL) {
        requestedWorkspaceURL = workspaceURL.standardizedFileURL
    }

    public func snapshot(
        source: CodexGitReviewSource,
        baseRef: String? = nil,
        commitRef: String? = nil
    ) async throws -> CodexGitReviewSnapshot {
        precondition(source != .lastTurn, "Last Turn comes from canonical transcript state")
        _ = try await repositoryRoot()
        async let branchResult = optional(["symbolic-ref", "--quiet", "--short", "HEAD"])
        async let headResult = run(["rev-parse", "HEAD"])
        async let upstreamResult = optional(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        async let branchesResult = run(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        async let remotesResult = run(["remote"])
        async let commitsResult = run([
            "log", "-n", "25", "--format=%H%x1f%s%x1f%ct%x1e",
        ])
        async let statusResult = run([
            "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=no",
        ])
        async let untrackedResult = source == .unstaged || source == .uncommitted
            ? untrackedSnapshot()
            : UntrackedSnapshot.empty

        let branch = try await branchResult?.stdout.nilIfBlank ?? "HEAD"
        let headOID = try await headResult.stdout
        let upstream = try await upstreamResult?.stdout.nilIfBlank
        let status = try await statusResult
        let untracked = try await untrackedResult
        let revisionStatus = status.stdout + untracked.porcelainStatus
        let branchNames = try await branchesResult.stdout
            .split(separator: "\n")
            .map(String.init)
        let remoteNames = try await remotesResult.stdout
            .split(separator: "\n")
            .map(String.init)
        let commits = try await parseCommitOptions(commitsResult.stdout)
        let comparisonRef = try await resolvedComparisonRef(
            source: source,
            requestedBaseRef: baseRef,
            requestedCommitRef: commitRef,
            upstream: upstream,
            branches: branchNames,
            currentBranch: branch
        )
        let revision = try await revision(
            source: source,
            branch: branch,
            headOID: headOID,
            status: revisionStatus,
            comparisonRef: comparisonRef
        )
        let files = try await files(
            source: source,
            comparisonRef: comparisonRef,
            status: status.stdout,
            untrackedPaths: untracked.paths
        )
        let unpushedCount: Int
        if upstream != nil,
           let result = try await optional(["rev-list", "--count", "@{upstream}..HEAD"]) {
            unpushedCount = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else if !remoteNames.isEmpty,
                  let result = try await optional(["rev-list", "--count", "HEAD", "--not", "--remotes"]) {
            unpushedCount = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else {
            unpushedCount = 0
        }
        return CodexGitReviewSnapshot(
            revision: revision,
            branchName: branch,
            upstreamBranchName: upstream,
            remoteNames: remoteNames,
            branchOptions: branchNames.map {
                CodexGitBranchPickerOption(branchName: $0, isCurrent: $0 == branch)
            },
            commitOptions: commits,
            comparisonRef: comparisonRef,
            files: files,
            unpushedCommitCount: unpushedCount,
            ignoredChangeCount: untracked.didTruncate ? 1 : 0
        )
    }

    public func patch(
        source: CodexGitReviewSource,
        path: String,
        baseRef: String? = nil,
        commitRef: String? = nil
    ) async throws -> CodexGitReviewPatchText {
        let safePath = try await validatedPath(path)
        let relativePath = safePath.path.replacingOccurrences(
            of: try await repositoryRoot().path + "/",
            with: ""
        )
        if (source == .unstaged || source == .uncommitted),
           try await isUntracked(relativePath) {
            return try untrackedPatch(url: safePath, relativePath: relativePath)
        }
        let arguments = try await diffArguments(
            source: source,
            comparisonRef: source == .branch ? baseRef : commitRef,
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
        try await ensureSafeMutationState()
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
            let untracked = Set(try await untrackedPaths(matching: safe))
            if let path = safe.first(where: { untracked.contains($0) }) {
                throw CodexGitRepositoryError.destructiveUntrackedPath(path)
            }
            try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + safe)
            return .init(message: "Reverted \(paths.count) tracked file\(paths.count == 1 ? "" : "s").")
        case .createBranch(let name):
            try await run(["switch", "-c", try validatedBranchName(name)])
            return .init(message: "Created and switched to \(name).")
        case .checkoutBranch(let name):
            try await run(["switch", try validatedBranchName(name)])
            return .init(message: "Switched to \(name).")
        case .commit(let message, let includeUnstaged):
            try await createCommit(message: message, includeUnstaged: includeUnstaged)
            return .init(message: "Commit created.")
        case .commitAndPush(let message, let includeUnstaged):
            try await createCommit(message: message, includeUnstaged: includeUnstaged)
            do {
                _ = try await pushCurrentBranch()
            } catch {
                throw CodexGitRepositoryError.partialSuccess(
                    "Commit created, but push failed: \(error.localizedDescription) Retry Push; do not recreate the commit."
                )
            }
            return .init(message: "Commit created and branch pushed.")
        case .push:
            let result = try await pushCurrentBranch()
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

    private func createCommit(message: String, includeUnstaged: Bool) async throws {
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
    }

    private func pushCurrentBranch() async throws -> CodexGitCommandResult {
        if (try await optional([
            "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
        ])) != nil {
            return try await run(["push", "--porcelain"])
        }
        guard let branch = try await optional([
            "symbolic-ref", "--quiet", "--short", "HEAD",
        ])?.stdout.nilIfBlank else {
            throw CodexGitRepositoryError.commandFailed(
                command: "git push",
                message: "Cannot push a detached HEAD. Create or check out a branch first."
            )
        }
        let remotes = try await run(["remote"]).stdout
            .split(separator: "\n")
            .map(String.init)
        guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
            throw CodexGitRepositoryError.commandFailed(
                command: "git push",
                message: "No Git remote is configured."
            )
        }
        return try await run(["push", "--porcelain", "--set-upstream", remote, branch])
    }

    /// Refuse every mutation while another Git writer or a history-changing
    /// operation owns the repository. Reads remain available so Review can
    /// explain and recover from the state without racing the operation.
    private func ensureSafeMutationState() async throws {
        let gitDirectoryResult = try await run(["rev-parse", "--absolute-git-dir"])
        let gitDirectory = URL(
            fileURLWithPath: gitDirectoryResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let markers: [(String, String)] = [
            ("index.lock", "another Git process holds the index lock"),
            ("MERGE_HEAD", "a merge is in progress"),
            ("CHERRY_PICK_HEAD", "a cherry-pick is in progress"),
            ("REVERT_HEAD", "a revert is in progress"),
            ("BISECT_LOG", "a bisect is in progress"),
            ("rebase-merge", "a rebase is in progress"),
            ("rebase-apply", "a rebase or apply operation is in progress"),
            ("sequencer", "a sequenced Git operation is in progress"),
        ]
        if let marker = markers.first(where: {
            FileManager.default.fileExists(atPath: gitDirectory.appending(path: $0.0).path)
        }) {
            throw CodexGitRepositoryError.unsafeRepositoryState(marker.1)
        }
    }

    private func files(
        source: CodexGitReviewSource,
        comparisonRef: String?,
        status: String,
        untrackedPaths: [String]
    ) async throws -> [CodexGitReviewFileChange] {
        let namesArguments = try await diffArguments(
            source: source,
            comparisonRef: comparisonRef,
            paths: [],
            outputOptions: ["--name-status", "-z"]
        )
        let statsArguments = try await diffArguments(
            source: source,
            comparisonRef: comparisonRef,
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
            let count = stats[entry.path] ?? (0, 0, false)
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
                isBinary: count.2
            )
        }
        if source == .unstaged || source == .uncommitted {
            let known = Set(files.map(\.path))
            files.append(contentsOf: untrackedPaths
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
        comparisonRef: String? = nil,
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
        case .committed:
            guard let comparisonRef else {
                throw CodexGitRepositoryError.comparisonRequired("Choose a commit to review.")
            }
            result.append(contentsOf: ["\(comparisonRef)^", comparisonRef])
        case .branch:
            guard let comparisonRef else {
                throw CodexGitRepositoryError.comparisonRequired("Choose a base branch to compare with the current branch.")
            }
            result.append("\(comparisonRef)...HEAD")
        }
        if !paths.isEmpty {
            result.append("--")
            result.append(contentsOf: paths)
        }
        return result
    }

    private func currentRevision(source: CodexGitReviewSource) async throws -> CodexGitReviewRevision {
        let branch = try await optional(["symbolic-ref", "--quiet", "--short", "HEAD"])?.stdout.nilIfBlank ?? "HEAD"
        async let headResult = run(["rev-parse", "HEAD"])
        async let statusResult = run([
            "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=no",
        ])
        async let untrackedResult = source == .unstaged || source == .uncommitted
            ? untrackedSnapshot()
            : UntrackedSnapshot.empty
        let headOID = try await headResult.stdout
        let status = try await statusResult.stdout
        let untracked = try await untrackedResult
        return try await revision(
            source: source,
            branch: branch,
            headOID: headOID,
            status: status + untracked.porcelainStatus,
            comparisonRef: nil
        )
    }

    private func revision(
        source: CodexGitReviewSource,
        branch: String,
        headOID: String,
        status: String,
        comparisonRef: String?
    ) async throws -> CodexGitReviewRevision {
        var fingerprint = CodexStableFingerprint()
        fingerprint.combine(source.rawValue)
        fingerprint.combine(branch)
        fingerprint.combine(headOID)
        fingerprint.combine(status)
        fingerprint.combine(comparisonRef ?? "")
        if source != .staged {
            fingerprint.combine(try await worktreeContentFingerprint(status: status))
        }
        return .init(sourceID: "git/\(source.rawValue)", value: fingerprint.value)
    }

    private func resolvedComparisonRef(
        source: CodexGitReviewSource,
        requestedBaseRef: String?,
        requestedCommitRef: String?,
        upstream: String?,
        branches: [String],
        currentBranch: String
    ) async throws -> String? {
        switch source {
        case .lastTurn, .uncommitted, .unstaged, .staged:
            return nil
        case .committed:
            return try await validatedCommitRef(requestedCommitRef?.nilIfBlank ?? "HEAD")
        case .branch:
            let requested = requestedBaseRef?.nilIfBlank
            let candidate = requested
                ?? upstream
                ?? branches.first(where: { $0 == "main" && $0 != currentBranch })
                ?? branches.first(where: { $0 == "master" && $0 != currentBranch })
            guard let candidate else {
                throw CodexGitRepositoryError.comparisonRequired(
                    "No base branch could be determined. Choose a base branch explicitly."
                )
            }
            return try await validatedCommitRef(candidate)
        }
    }

    private func validatedCommitRef(_ ref: String) async throws -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              (try await optional(["rev-parse", "--verify", "\(trimmed)^{commit}"])) != nil else {
            throw CodexGitRepositoryError.commandFailed(
                command: "git rev-parse --verify",
                message: "Unknown commit or branch ‘\(trimmed)’."
            )
        }
        return trimmed
    }

    /// Porcelain status alone does not change when an already-modified file is
    /// edited again. Hash the changed worktree paths so mutations reject that
    /// stale display instead of applying to content the user never reviewed.
    private func worktreeContentFingerprint(status: String) async throws -> String {
        let root = try await repositoryRoot()
        let paths = changedWorktreePaths(status: status).filter { path in
            FileManager.default.fileExists(atPath: root.appending(path: path).path)
        }
        guard !paths.isEmpty else { return "" }

        var result = ""
        let chunkSize = 128
        for start in stride(from: 0, to: paths.count, by: chunkSize) {
            let end = min(start + chunkSize, paths.count)
            let hashes = try await run(
                ["hash-object", "--no-filters", "--"] + Array(paths[start..<end])
            )
            result += hashes.stdout
        }
        return result
    }

    private func changedWorktreePaths(status: String) -> [String] {
        var paths: Set<String> = []
        for record in status.split(separator: "\0", omittingEmptySubsequences: true) {
            if record.hasPrefix("? ") {
                paths.insert(String(record.dropFirst(2)))
            } else if record.hasPrefix("1 ") {
                let fields = record.split(
                    separator: " ",
                    maxSplits: 8,
                    omittingEmptySubsequences: true
                )
                if fields.count == 9 { paths.insert(String(fields[8])) }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(
                    separator: " ",
                    maxSplits: 9,
                    omittingEmptySubsequences: true
                )
                if fields.count == 10 { paths.insert(String(fields[9])) }
            } else if record.hasPrefix("u ") {
                let fields = record.split(
                    separator: " ",
                    maxSplits: 10,
                    omittingEmptySubsequences: true
                )
                if fields.count == 11 { paths.insert(String(fields[10])) }
            }
        }
        return paths.sorted()
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

    private func untrackedPaths(matching paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        return try await run(
            ["ls-files", "--others", "--exclude-standard", "-z", "--"] + paths
        ).stdout
            .split(separator: "\0")
            .map(String.init)
    }

    private func isUntracked(_ path: String) async throws -> Bool {
        !(try await untrackedPaths(matching: [path])).isEmpty
    }

    private struct UntrackedSnapshot: Sendable {
        var paths: [String]
        var didTruncate: Bool

        static let empty = UntrackedSnapshot(paths: [], didTruncate: false)

        var porcelainStatus: String {
            paths.map { "? \($0)\0" }.joined()
        }
    }

    private func untrackedSnapshot() async throws -> UntrackedSnapshot {
        let result = try await run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            maximumOutputBytes: Self.maximumUntrackedMetadataBytes,
            allowTruncation: true
        )
        var paths = result.stdout.split(separator: "\0").map(String.init)
        // A truncated byte stream can end inside a path. Never expose that
        // fragment as an actionable file.
        if result.wasTruncated, !result.stdout.hasSuffix("\0"), !paths.isEmpty {
            paths.removeLast()
        }
        let exceededRecordLimit = paths.count > Self.maximumVisibleUntrackedFiles
        if exceededRecordLimit {
            paths.removeSubrange(Self.maximumVisibleUntrackedFiles...)
        }
        return UntrackedSnapshot(
            paths: paths,
            didTruncate: result.wasTruncated || exceededRecordLimit
        )
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

    private func parseNumstat(_ output: String) -> [String: (Int, Int, Bool)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [String: (Int, Int, Bool)] = [:]
        var index = 0
        while index < fields.count {
            let header = fields[index]
            index += 1
            guard !header.isEmpty else { continue }
            let components = header.split(separator: "\t", omittingEmptySubsequences: false)
            guard components.count >= 3 else { continue }
            let added = Int(components[0]) ?? 0
            let removed = Int(components[1]) ?? 0
            let isBinary = components[0] == "-" || components[1] == "-"
            if !components[2].isEmpty {
                result[String(components[2])] = (added, removed, isBinary)
            } else if index + 1 < fields.count {
                _ = fields[index]
                let destination = fields[index + 1]
                index += 2
                result[destination] = (added, removed, isBinary)
            }
        }
        return result
    }

    private func parseCommitOptions(_ output: String) -> [CodexGitCommitOption] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 3, let timestamp = TimeInterval(fields[2]) else { return nil }
            return CodexGitCommitOption(
                sha: String(fields[0]),
                subject: String(fields[1]),
                committedAt: Date(timeIntervalSince1970: timestamp)
            )
        }
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
    var wasTruncated: Bool
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
            // FileHandle's synchronous reads must not occupy Swift's
            // cooperative executor. A snapshot launches several Git commands
            // concurrently, so two detached blocking readers per command can
            // otherwise starve the tasks that are responsible for completing
            // those same reads.
            let reads = CodexProcessReadPair()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                reads.setOutput(Result {
                    try Self.readBounded(
                        standardOutput.fileHandleForReading,
                        limit: maximumOutputBytes
                    )
                })
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                reads.setError(Result {
                    try Self.readBounded(
                        standardError.fileHandleForReading,
                        limit: 128 * 1_024
                    )
                })
                readGroup.leave()
            }
            await withCheckedContinuation { continuation in
                readGroup.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume()
                }
            }
            let output = try reads.output.get()
            let error = try reads.error.get()
            // `Process.waitUntilExit()` can remain blocked on a detached Swift
            // worker even after both pipes reached EOF and the child was reaped.
            // Polling `isRunning` keeps this boundary cancellable and avoids
            // pinning a worker thread indefinitely.
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
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
            return CodexGitCommandResult(
                stdout: stdout,
                stderr: stderr,
                wasTruncated: output.wasTruncated
            )
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
    ) throws -> (data: Data, wasTruncated: Bool) {
        var data = Data()
        var truncated = false
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            if data.count < limit {
                let remaining = limit - data.count
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining {
                    truncated = true
                }
            } else {
                truncated = true
            }
        }
        return (data, truncated)
    }
}

private final class CodexProcessReadPair: @unchecked Sendable {
    typealias Capture = (data: Data, wasTruncated: Bool)

    private let lock = NSLock()
    private var storedOutput: Result<Capture, Error>?
    private var storedError: Result<Capture, Error>?

    var output: Result<Capture, Error> {
        lock.withLock { storedOutput! }
    }

    var error: Result<Capture, Error> {
        lock.withLock { storedError! }
    }

    func setOutput(_ result: Result<Capture, Error>) {
        lock.withLock { storedOutput = result }
    }

    func setError(_ result: Result<Capture, Error>) {
        lock.withLock { storedError = result }
    }
}
