import Foundation
import CodexCore

public struct CodexPlanSummary: Equatable, Sendable {
    public var steps: [TurnPlanStep]
    public var explanation: String?

    public init(steps: [TurnPlanStep], explanation: String? = nil) {
        self.steps = steps
        self.explanation = explanation
    }

    public var completedCount: Int {
        steps.count { $0.status == .completed }
    }

    public var progressLabel: String {
        "\(completedCount)/\(steps.count)"
    }
}

public struct CodexWorkspaceSummaryContext: Equatable, Sendable {
    public var workspacePath: String
    public var gitBranch: String?
    public var turnDiff: String?
    public var environmentInfo: CodexEnvironmentInfoState
    public var sourceFiles: [CodexReferencedFile]
    public var plan: CodexPlanSummary?

    public init(
        workspacePath: String,
        gitBranch: String? = nil,
        turnDiff: String? = nil,
        environmentInfo: CodexEnvironmentInfoState = .unavailable,
        sourceFiles: [CodexReferencedFile] = [],
        plan: CodexPlanSummary? = nil
    ) {
        self.workspacePath = workspacePath
        self.gitBranch = gitBranch
        self.turnDiff = turnDiff
        self.environmentInfo = environmentInfo
        self.sourceFiles = sourceFiles
        self.plan = plan
    }

    public var workspaceLine: String {
        let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
        if let gitBranch, !gitBranch.isEmpty {
            return "\(folder) · \(gitBranch)"
        }
        return workspacePath
    }

    public var environmentModeTitle: String {
        if let isWorktree = CodexWorkspaceGitProbe.isLinkedWorktree(at: URL(fileURLWithPath: workspacePath)) {
            return isWorktree ? "Worktree" : "Local"
        }
        return CodexWorkspaceGitProbe.heuristicWorktreePath(URL(fileURLWithPath: workspacePath))
            ? "Worktree" : "Local"
    }

    public var diffStatsLine: String? {
        guard let turnDiff, !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let lines = turnDiff.split(separator: "\n", omittingEmptySubsequences: false)
        let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        let files = max(1, lines.filter { $0.hasPrefix("diff --git ") }.count)
        return "+\(added) -\(removed) across \(files) file(s)"
    }
}

/// Small synchronous Git probe used by value-type summary models. The query is
/// intentionally best-effort: a missing Git binary or a non-repository path
/// falls back to the historical path heuristic instead of making rendering
/// fail.
enum CodexWorkspaceGitProbe {
    static func isLinkedWorktree(at url: URL) -> Bool? {
        let directory = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--git-common-dir", "--git-dir"]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let values = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        guard values.count >= 2 else { return nil }

        let commonDirectory = resolveGitPath(values[0], relativeTo: directory)
        let worktreeGitDirectory = resolveGitPath(values[1], relativeTo: directory)
        return commonDirectory != worktreeGitDirectory
    }

    static func repositoryRoot(at url: URL) -> URL? {
        let directory = url.standardizedFileURL
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func heuristicWorktreePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".codex"), components.contains("worktrees") {
            return true
        }
        return components.contains { $0.hasSuffix("-worktrees") }
    }

    private static func resolveGitPath(_ path: String, relativeTo directory: URL) -> URL {
        let url = URL(fileURLWithPath: path)
        return url.isFileURL && path.hasPrefix("/")
            ? url.standardizedFileURL
            : directory.appendingPathComponent(path).standardizedFileURL
    }
}
