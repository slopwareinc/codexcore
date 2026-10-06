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
    public var backgroundTerminals: CanonicalBackgroundTerminalState?

    public init(
        workspacePath: String,
        gitBranch: String? = nil,
        turnDiff: String? = nil,
        environmentInfo: CodexEnvironmentInfoState = .unavailable,
        sourceFiles: [CodexReferencedFile] = [],
        plan: CodexPlanSummary? = nil,
        backgroundTerminals: CanonicalBackgroundTerminalState? = nil
    ) {
        self.workspacePath = workspacePath
        self.gitBranch = gitBranch
        self.turnDiff = turnDiff
        self.environmentInfo = environmentInfo
        self.sourceFiles = sourceFiles
        self.plan = plan
        self.backgroundTerminals = backgroundTerminals
    }

    public var workspaceLine: String {
        let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
        if let gitBranch, !gitBranch.isEmpty {
            return "\(folder) · \(gitBranch)"
        }
        return workspacePath
    }

    public var environmentModeTitle: String {
        // Do not launch a synchronous Git subprocess while SwiftUI is rendering.
        return CodexWorkspaceGitProbe.heuristicWorktreePath(URL(fileURLWithPath: workspacePath))
            ? "Worktree" : "Local"
    }

    public var diffStatsLine: String? {
        guard let turnDiff, !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var added = 0
        var removed = 0
        var files = 0
        for line in turnDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
            if line.hasPrefix("diff --git ") {
                files += 1
            }
        }
        return "+\(added) -\(removed) across \(max(1, files)) file(s)"
    }
}

/// Best-effort Git probes never block the caller's actor on subprocess I/O.
enum CodexWorkspaceGitProbe {
    static func repositoryRoot(at url: URL, timeout: Duration = .seconds(3)) async -> URL? {
        guard let result = try? await CodexProcessProbe.runAsync(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["rev-parse", "--show-toplevel"],
            directory: url.standardizedFileURL, timeout: timeout
        ), result.status == 0,
           let path = result.output.nilIfBlank else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func heuristicWorktreePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".codex"), components.contains("worktrees") {
            return true
        }
        return components.contains { $0.hasSuffix("-worktrees") }
    }

}
