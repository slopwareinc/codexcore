import Foundation

public enum CodexProjectEnvironmentSelection: String, CaseIterable, Equatable, Sendable {
    case local
    case worktree
    case cloud

    public var title: String {
        switch self {
        case .local:
            return "Local"
        case .worktree:
            return "Worktree"
        case .cloud:
            return "Cloud"
        }
    }
}

public enum CodexWorktreeHandoffPathStatus: String, Equatable, Sendable {
    case applied
    case skipped
    case conflicted

    public var title: String {
        switch self {
        case .applied:
            return "Applied"
        case .skipped:
            return "Skipped"
        case .conflicted:
            return "Conflicted"
        }
    }
}

public struct CodexWorktreeHandoffPathOutcome: Equatable, Sendable {
    public var path: String
    public var status: CodexWorktreeHandoffPathStatus
    public var detail: String?

    public init(
        path: String,
        status: CodexWorktreeHandoffPathStatus,
        detail: String? = nil
    ) {
        self.path = path
        self.status = status
        self.detail = detail
    }
}

public struct CodexProjectEnvironmentRepositorySnapshot: Equatable, Sendable {
    public var branchName: String?
    public var branches: [String]
    public var dirtyFileCount: Int

    public init(branchName: String?, branches: [String], dirtyFileCount: Int) {
        self.branchName = branchName
        self.branches = branches
        self.dirtyFileCount = max(0, dirtyFileCount)
    }
}

public protocol CodexProjectEnvironmentProviding: CodexWorktreeHandoffProviding {
    func repositorySnapshot() async throws -> CodexProjectEnvironmentRepositorySnapshot
    func checkoutBranch(_ branchName: String) async throws -> CodexProjectEnvironmentRepositorySnapshot
}

public enum CodexEnvironmentInfoState: Equatable, Sendable {
    case loading
    case available(cwd: String?, shellName: String, shellPath: String)
    case unavailable
    case failed(String)
}

public struct CodexProjectEnvironmentState: Equatable, Sendable {
    public var selection: CodexProjectEnvironmentSelection
    public var workspacePath: String
    public var branchName: String?
    public var worktreePath: String?
    public var usageRemainingLabel: String?
    public var runtimeInfo: CodexEnvironmentInfoState

    public init(
        selection: CodexProjectEnvironmentSelection = .local,
        workspacePath: String,
        branchName: String? = nil,
        worktreePath: String? = nil,
        usageRemainingLabel: String? = nil,
        runtimeInfo: CodexEnvironmentInfoState = .unavailable
    ) {
        self.selection = selection
        self.workspacePath = workspacePath
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.usageRemainingLabel = usageRemainingLabel
        self.runtimeInfo = runtimeInfo
    }

    public mutating func apply(_ result: CodexWorktreeHandoffResult) {
        selection = .worktree
        branchName = result.branchName
        worktreePath = result.worktreePath
        workspacePath = result.workingDirectoryPath
    }
}

public enum CodexWorktreeHandoffValidationError: String, Equatable, Sendable {
    case titleRequired
    case sourcePathRequired
    case targetPathRequired
    case branchRequired
    case branchInvalid

    public var message: String {
        switch self {
        case .titleRequired:
            return "Title is required"
        case .sourcePathRequired:
            return "Source path is required"
        case .targetPathRequired:
            return "Worktree path is required"
        case .branchRequired:
            return "Branch name is required"
        case .branchInvalid:
            return "Branch name contains unsupported characters"
        }
    }
}

public struct CodexWorktreeHandoffModalState: Equatable, Sendable {
    public var title: String
    public var sourcePath: String
    public var targetPath: String
    public var branchName: String

    public init(
        threadTitle: String,
        sourcePath: String,
        targetPath: String,
        branchName: String? = nil
    ) {
        self.title = threadTitle
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.branchName = branchName ?? Self.defaultBranchName(for: threadTitle)
    }

    public var validationErrors: [CodexWorktreeHandoffValidationError] {
        var errors: [CodexWorktreeHandoffValidationError] = []
        if title.trimmedForHandoff.isEmpty { errors.append(.titleRequired) }
        if sourcePath.trimmedForHandoff.isEmpty { errors.append(.sourcePathRequired) }
        if targetPath.trimmedForHandoff.isEmpty { errors.append(.targetPathRequired) }
        if branchName.trimmedForHandoff.isEmpty {
            errors.append(.branchRequired)
        } else if !Self.isValidBranchName(branchName) {
            errors.append(.branchInvalid)
        }
        return errors
    }

    public var isValid: Bool {
        validationErrors.isEmpty
    }

    public func request() -> CodexWorktreeHandoffRequest? {
        guard isValid else { return nil }
        return CodexWorktreeHandoffRequest(
            title: title.trimmedForHandoff,
            sourcePath: sourcePath.trimmedForHandoff,
            targetPath: targetPath.trimmedForHandoff,
            branchName: branchName.trimmedForHandoff
        )
    }

    public static func defaultBranchName(for threadTitle: String) -> String {
        let slugCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let slug = threadTitle
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                slugCharacters.contains(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "codex/\(slug.isEmpty ? "thread" : slug)"
    }

    private static func isValidBranchName(_ branch: String) -> Bool {
        let trimmed = branch.trimmedForHandoff
        guard trimmed == branch, !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("/") && !trimmed.hasSuffix("/") else { return false }
        guard !trimmed.contains("..") && !trimmed.contains("//") else { return false }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-").contains(scalar)
        }
    }
}

public struct CodexWorktreeHandoffRequest: Equatable, Sendable {
    public var title: String
    public var sourcePath: String
    public var targetPath: String
    public var branchName: String

    public init(title: String, sourcePath: String, targetPath: String, branchName: String) {
        self.title = title
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.branchName = branchName
    }
}

public struct CodexWorktreeHandoffResult: Equatable, Sendable {
    public var title: String
    public var branchName: String
    public var worktreePath: String
    public var workingDirectoryPath: String
    public var pathOutcomes: [CodexWorktreeHandoffPathOutcome]

    public init(
        title: String,
        branchName: String,
        worktreePath: String,
        workingDirectoryPath: String? = nil,
        pathOutcomes: [CodexWorktreeHandoffPathOutcome] = []
    ) {
        self.title = title
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.workingDirectoryPath = workingDirectoryPath?.nilIfBlank ?? worktreePath
        self.pathOutcomes = pathOutcomes
    }

    public var resultCard: CodexWorktreeHandoffResultCard {
        CodexWorktreeHandoffResultCard(
            title: "Handed-off to worktree",
            detail: "\(branchName) at \(worktreePath)",
            branchName: branchName,
            worktreePath: worktreePath,
            pathOutcomes: pathOutcomes
        )
    }
}

public struct CodexWorktreeHandoffResultCard: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var branchName: String
    public var worktreePath: String
    public var pathOutcomes: [CodexWorktreeHandoffPathOutcome]

    public init(
        title: String,
        detail: String,
        branchName: String,
        worktreePath: String,
        pathOutcomes: [CodexWorktreeHandoffPathOutcome] = []
    ) {
        self.title = title
        self.detail = detail
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.pathOutcomes = pathOutcomes
    }
}

public struct CodexWorktreeHandoffCompletion: Equatable, Sendable {
    public var environment: CodexProjectEnvironmentState
    public var activity: CodexActivity
    public var resultCard: CodexWorktreeHandoffResultCard?

    public init(
        environment: CodexProjectEnvironmentState,
        activity: CodexActivity,
        resultCard: CodexWorktreeHandoffResultCard?
    ) {
        self.environment = environment
        self.activity = activity
        self.resultCard = resultCard
    }
}

public struct CodexProjectEnvironmentPanelRow: Equatable, Sendable {
    public var title: String
    public var value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }
}

public struct CodexProjectEnvironmentPanelSession: Equatable, Sendable {
    public var environment: CodexProjectEnvironmentState
    public var modal: CodexWorktreeHandoffModalState?
    public var lastActivity: CodexActivity?
    public var resultCard: CodexWorktreeHandoffResultCard?

    public init(
        environment: CodexProjectEnvironmentState,
        modal: CodexWorktreeHandoffModalState? = nil,
        lastActivity: CodexActivity? = nil,
        resultCard: CodexWorktreeHandoffResultCard? = nil
    ) {
        self.environment = environment
        self.modal = modal
        self.lastActivity = lastActivity
        self.resultCard = resultCard
    }

    public var rows: [CodexProjectEnvironmentPanelRow] {
        var rows = [
            CodexProjectEnvironmentPanelRow(title: "Mode", value: environment.selection.title),
            CodexProjectEnvironmentPanelRow(title: "Branch", value: environment.branchName?.nilIfBlank ?? "No branch"),
            CodexProjectEnvironmentPanelRow(title: "Path", value: environment.worktreePath?.nilIfBlank ?? environment.workspacePath)
        ]
        if let usage = environment.usageRemainingLabel?.nilIfBlank {
            rows.append(CodexProjectEnvironmentPanelRow(title: "Usage", value: usage))
        }
        switch environment.runtimeInfo {
        case .loading:
            rows.append(CodexProjectEnvironmentPanelRow(title: "Runtime", value: "Loading…"))
        case .available(let cwd, let shellName, let shellPath):
            rows.append(CodexProjectEnvironmentPanelRow(title: "Shell", value: "\(shellName) · \(shellPath)"))
            if let cwd = cwd?.nilIfBlank {
                rows.append(CodexProjectEnvironmentPanelRow(title: "CWD", value: cwd))
            }
        case .unavailable:
            rows.append(CodexProjectEnvironmentPanelRow(title: "Runtime", value: "Unavailable"))
        case .failed(let message):
            rows.append(CodexProjectEnvironmentPanelRow(title: "Runtime", value: "Error · \(message)"))
        }
        return rows
    }

    public mutating func prepareModal(threadTitle: String, targetPath: String? = nil) {
        modal = CodexWorktreeHandoffModalState(
            threadTitle: threadTitle,
            sourcePath: environment.workspacePath,
            targetPath: targetPath ?? Self.defaultTargetPath(sourcePath: environment.workspacePath, threadTitle: threadTitle)
        )
        lastActivity = nil
        resultCard = nil
    }

    public mutating func apply(_ completion: CodexWorktreeHandoffCompletion) {
        environment = completion.environment
        lastActivity = completion.activity
        resultCard = completion.resultCard
    }

    public static func defaultTargetPath(sourcePath: String, threadTitle: String) -> String {
        let source = sourcePath.trimmedForHandoff
        guard !source.isEmpty else { return "" }
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
        let repositoryURL = CodexWorkspaceGitProbe.repositoryRoot(at: sourceURL) ?? sourceURL
        let branchName = CodexWorktreeHandoffModalState.defaultBranchName(for: threadTitle)
        let slug = branchName
            .replacingOccurrences(of: "codex/", with: "")
            .replacingOccurrences(of: "/", with: "-")
        let bucket = String(UUID().uuidString.prefix(4)).lowercased()
        return repositoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repositoryURL.lastPathComponent)-worktrees")
            .appendingPathComponent(bucket)
            .appendingPathComponent(slug)
            .path
    }
}

public protocol CodexWorktreeHandoffProviding: Sendable {
    func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult
}

public enum CodexWorktreeHandoffSession {
    public static func perform(
        modal: CodexWorktreeHandoffModalState,
        environment: CodexProjectEnvironmentState,
        provider: any CodexWorktreeHandoffProviding
    ) async -> CodexWorktreeHandoffCompletion {
        guard let request = modal.request() else {
            return CodexWorktreeHandoffCompletion(
                environment: environment,
                activity: CodexActivity(
                    kind: .notice,
                    title: "Worktree handoff unavailable",
                    detail: modal.validationErrors.map(\.message).joined(separator: ", ")
                ),
                resultCard: nil
            )
        }

        do {
            let result = try await provider.handOffToWorktree(request)
            var updated = environment
            updated.apply(result)
            return CodexWorktreeHandoffCompletion(
                environment: updated,
                activity: CodexActivity(kind: .notice, title: result.resultCard.title, detail: result.resultCard.detail),
                resultCard: result.resultCard
            )
        } catch {
            return CodexWorktreeHandoffCompletion(
                environment: environment,
                activity: CodexActivity(kind: .notice, title: "Worktree handoff unavailable", detail: error.localizedDescription),
                resultCard: nil
            )
        }
    }
}

public struct CodexUnsupportedWorktreeHandoffProvider: CodexWorktreeHandoffProviding {
    public init() {}

    public func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        throw CodexUnsupportedWorktreeHandoffError()
    }
}

public struct CodexUnsupportedProjectEnvironmentProvider: CodexProjectEnvironmentProviding {
    public init() {}

    public func repositorySnapshot() async throws -> CodexProjectEnvironmentRepositorySnapshot {
        throw CodexUnsupportedWorktreeHandoffError()
    }

    public func checkoutBranch(_ branchName: String) async throws -> CodexProjectEnvironmentRepositorySnapshot {
        throw CodexUnsupportedWorktreeHandoffError()
    }

    public func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        throw CodexUnsupportedWorktreeHandoffError()
    }
}

public struct CodexUnsupportedWorktreeHandoffError: Error, Equatable, LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Worktree handoff is not available in this build"
    }
}

private extension String {
    var trimmedForHandoff: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
