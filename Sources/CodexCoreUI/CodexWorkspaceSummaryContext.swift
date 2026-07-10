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
        let change = CodexChatMessage.fileChange(itemID: "summary-diff", path: nil, diff: turnDiff)
        return "+\(change.addedLineCount) -\(change.removedLineCount) across \(change.changedFileCount) file(s)"
    }
}
