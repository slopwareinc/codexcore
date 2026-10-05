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
    /// Disclosure and focus are presentation decorations, never protocol facts.
    public var expandedCardIDs: Set<String>
    public var focusedItemID: String?
    public var selectedDiffFileIndexByRowID: [String: Int]
    /// Presentation-only inline editor state. Canonical user content is never
    /// mutated until the host explicitly commits the edit.
    public var editingMessageID: String?
    public var editingMessageText: String
    public var bookmarkedTurnIDs: Set<String>
    public var outputBadgesByTurnID: [String: String]
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
        expandedCardIDs: Set<String> = [],
        focusedItemID: String? = nil,
        selectedDiffFileIndexByRowID: [String: Int] = [:],
        editingMessageID: String? = nil,
        editingMessageText: String = "",
        bookmarkedTurnIDs: Set<String> = [],
        outputBadgesByTurnID: [String: String] = [:],
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
        self.expandedCardIDs = expandedCardIDs
        self.focusedItemID = focusedItemID
        self.selectedDiffFileIndexByRowID = selectedDiffFileIndexByRowID
        self.editingMessageID = editingMessageID
        self.editingMessageText = editingMessageText
        self.bookmarkedTurnIDs = bookmarkedTurnIDs
        self.outputBadgesByTurnID = outputBadgesByTurnID
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

public struct CodexThreadStatusEntry: Sendable, Equatable {
    public var status: CodexThreadLiveStatus
    public var hasUnreadWhileInactive: Bool
    public var lastEventAt: Date
    public var progress: Double?
    public var statusText: String?

    public init(
        status: CodexThreadLiveStatus = .idle,
        hasUnreadWhileInactive: Bool = false,
        lastEventAt: Date = Date(),
        progress: Double? = nil,
        statusText: String? = nil
    ) {
        self.status = status
        self.hasUnreadWhileInactive = hasUnreadWhileInactive
        self.lastEventAt = lastEventAt
        self.progress = progress.map { min(max($0, 0), 1) }
        self.statusText = statusText?.nilIfBlank
    }
}
