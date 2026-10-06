import CodexCore
import Foundation

/// The complete disposable presentation consumed by transcript renderers.
/// Canonical protocol state remains in `CodexSession`; scroll position and
/// expansion sets are UI-local decorations maintained by the presentation
/// store.
public struct CodexThreadUIPresentation: Sendable, Equatable {
    public var threadID: String
    public var transcript: CodexTranscriptV2
    public var rawScrollOffset: CGFloat
    public var isPinnedToBottom: Bool
    public var expandedWorkTurnIDs: Set<String>
    public var expandedRowIDs: Set<String>
    public var selectedDiffFileIndexByRowID: [String: Int]
    public var agentDisplayNameByThreadID: [String: String]
    public var agentDisplayStatusByThreadID: [String: CodexAgentDisplayStatusV2]
    public var presentedAtByTurnID: [String: Date]
    public var pendingApprovals: [CodexApprovalPrompt]

    public init(
        threadID: String,
        transcript: CodexTranscriptV2,
        rawScrollOffset: CGFloat = 0,
        isPinnedToBottom: Bool = true,
        expandedWorkTurnIDs: Set<String> = [],
        expandedRowIDs: Set<String> = [],
        selectedDiffFileIndexByRowID: [String: Int] = [:],
        agentDisplayNameByThreadID: [String: String] = [:],
        agentDisplayStatusByThreadID: [String: CodexAgentDisplayStatusV2] = [:],
        presentedAtByTurnID: [String: Date] = [:],
        pendingApprovals: [CodexApprovalPrompt] = []
    ) {
        self.threadID = threadID
        self.transcript = transcript
        self.rawScrollOffset = rawScrollOffset
        self.isPinnedToBottom = isPinnedToBottom
        self.expandedWorkTurnIDs = expandedWorkTurnIDs
        self.expandedRowIDs = expandedRowIDs
        self.selectedDiffFileIndexByRowID = selectedDiffFileIndexByRowID
        self.agentDisplayNameByThreadID = agentDisplayNameByThreadID
        self.agentDisplayStatusByThreadID = agentDisplayStatusByThreadID
        self.presentedAtByTurnID = presentedAtByTurnID
        self.pendingApprovals = pendingApprovals
    }
}

public enum CodexThreadLiveStatus: String, Sendable, Equatable {
    case idle
    case running
    case failed
}

/// A request that currently needs the user's attention. This remains separate
/// from live lifecycle so a waiting turn does not lose its running state.
public enum CodexSidebarThreadAttention: Sendable, Equatable {
    case approval
    case input

    public static func resolve(_ status: CanonicalThreadStatus) -> Self? {
        guard case .active(let flags) = status else { return nil }
        if flags.contains(.waitingOnApproval) { return .approval }
        if flags.contains(.waitingOnUserInput) { return .input }
        return nil
    }
}

public struct CodexThreadStatusEntry: Sendable, Equatable {
    public var status: CodexThreadLiveStatus
    public var attention: CodexSidebarThreadAttention?
    public var hasUnreadWhileInactive: Bool
    public var lastEventAt: Date
    public var progress: Double?
    public var statusText: String?

    public init(
        status: CodexThreadLiveStatus = .idle,
        attention: CodexSidebarThreadAttention? = nil,
        hasUnreadWhileInactive: Bool = false,
        lastEventAt: Date = Date(),
        progress: Double? = nil,
        statusText: String? = nil
    ) {
        self.status = status
        self.attention = attention
        self.hasUnreadWhileInactive = hasUnreadWhileInactive
        self.lastEventAt = lastEventAt
        self.progress = progress.map { min(max($0, 0), 1) }
        self.statusText = statusText?.nilIfBlank
    }
}
