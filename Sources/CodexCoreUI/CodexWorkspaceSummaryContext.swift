import Foundation

public struct CodexWorkspaceSummaryContext: Equatable, Sendable {
    public var workspacePath: String
    public var gitBranch: String?
    public var turnDiff: String?
    public var environmentInfo: CodexEnvironmentInfoState

    public init(
        workspacePath: String,
        gitBranch: String? = nil,
        turnDiff: String? = nil,
        environmentInfo: CodexEnvironmentInfoState = .unavailable
    ) {
        self.workspacePath = workspacePath
        self.gitBranch = gitBranch
        self.turnDiff = turnDiff
        self.environmentInfo = environmentInfo
    }

    public var workspaceLine: String {
        let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
        if let gitBranch, !gitBranch.isEmpty {
            return "\(folder) · \(gitBranch)"
        }
        return workspacePath
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
