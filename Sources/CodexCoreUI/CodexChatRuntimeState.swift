import Foundation
import CodexCore

public struct CodexChatRuntimeState: Sendable {
    public var goalSession: CodexGoalStateSession
    public var mainChatSession: CodexMainChatSession
    public var sideChatSession: CodexSideChatSession
    public var integrationCatalogSession: CodexIntegrationCatalogSession
    public var integrationControlPlaneSession: CodexIntegrationControlPlaneSession
    private var hasCanonicalSnapshot = false
    private var canonicalIsSending = false
    private var canonicalPlan: [TurnPlanStep] = []
    private var canonicalPlanExplanation: String?
    private var canonicalDiff: String?
    private var canonicalDiffSourceID: String?
    private var canonicalDiffRevision: StateRevision?
    private var canonicalGoal: ThreadGoal?

    public init(
        goalSession: CodexGoalStateSession = CodexGoalStateSession(),
        mainChatSession: CodexMainChatSession = CodexMainChatSession(),
        sideChatSession: CodexSideChatSession = CodexSideChatSession(),
        integrationCatalogSession: CodexIntegrationCatalogSession = CodexIntegrationCatalogSession(),
        integrationControlPlaneSession: CodexIntegrationControlPlaneSession = CodexIntegrationControlPlaneSession()
    ) {
        self.goalSession = goalSession
        self.mainChatSession = mainChatSession
        self.sideChatSession = sideChatSession
        self.integrationCatalogSession = integrationCatalogSession
        self.integrationControlPlaneSession = integrationControlPlaneSession
    }

    public var sideChat: CodexSideChatState? {
        sideChatSession.sideChat
    }

    public var isSending: Bool {
        mainChatSession.isSending || canonicalIsSending
    }

    public var isSideChatSending: Bool {
        sideChatSession.isSending
    }

    public var activeTurnID: String? {
        mainChatSession.activeTurnID
    }

    public var activeSideChatTurnID: String? {
        sideChatSession.activeTurnID
    }

    public var currentPlan: [TurnPlanStep] {
        canonicalPlan
    }

    public var currentPlanExplanation: String? {
        canonicalPlanExplanation
    }

    public var currentDiff: String? {
        canonicalDiff
    }

    public var currentDiffSourceID: String? { canonicalDiffSourceID }
    public var currentDiffRevision: StateRevision? { canonicalDiffRevision }

    public var activeGoal: ThreadGoal? {
        hasCanonicalSnapshot ? canonicalGoal : goalSession.activeGoal
    }

    public var isGoalPursuitEnabled: Bool {
        goalSession.isPursuitEnabled
    }

    public var activeGoalTurnID: String? {
        goalSession.activeTurnID
    }

    public func canSendFollowUp(canSteer: Bool) -> Bool {
        isSending && goalSession.canSendFollowUp(canSteer: canSteer)
    }

    public func goalSummary(for goal: ThreadGoal) -> String {
        goalSession.summary(for: goal)
    }

    public var hasActiveGoal: Bool {
        goalSession.hasActiveGoal
    }

    public mutating func setGoalPursuitEnabled(_ enabled: Bool) -> CodexGoalPursuitModeChange? {
        goalSession.setPursuitEnabled(enabled)
    }

    public mutating func restorePursuitAfterClearFailure() {
        goalSession.restorePursuitAfterClearFailure()
    }

    public mutating func prepareFollowUp(
        submission: CodexComposerSubmission,
        composerSession: inout CodexComposerStateSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        CodexTurnSubmissionSession.prepareFollowUp(
            submission: submission,
            composerSession: &composerSession,
            mainChatSession: &mainChatSession,
            followUpBehavior: followUpBehavior,
            canSteer: canSteer
        )
    }

    public mutating func prepareFollowUp(
        prompt: String,
        composerSession: inout CodexComposerStateSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        prepareFollowUp(
            submission: CodexComposerSubmission(prompt: prompt),
            composerSession: &composerSession,
            followUpBehavior: followUpBehavior,
            canSteer: canSteer
        )
    }

    public mutating func dequeueQueuedFollowUp(
        composerSession: inout CodexComposerStateSession,
        isSending: Bool
    ) -> CodexQueuedFollowUpSubmission? {
        CodexTurnSubmissionSession.dequeueQueuedFollowUp(
            composerSession: &composerSession,
            mainChatSession: &mainChatSession,
            isSending: isSending
        )
    }

    public mutating func failQueuedFollowUp(
        _ submission: CodexQueuedFollowUpSubmission,
        message: String,
        composerSession: inout CodexComposerStateSession
    ) -> CodexActivity {
        CodexTurnSubmissionSession.failQueuedFollowUp(
            submission,
            message: message,
            composerSession: &composerSession,
            mainChatSession: &mainChatSession
        )
    }

    @discardableResult
    public mutating func beginTurnSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        mainChatSession.beginTurnSubmission(submission)
    }

    public mutating func startMainTurn(id turnID: String) {
        mainChatSession.start(turnID: turnID)
    }

    @discardableResult
    public mutating func finishMainTurn(id turnID: String?) -> CodexMainChatUpdate? {
        mainChatSession.finishActiveTurn(id: turnID)
    }

    @discardableResult
    public mutating func failTurnSubmission(message: String) -> CodexActivity {
        mainChatSession.failTurnSubmission(message: message)
    }

    @discardableResult
    public mutating func beginGoalSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        mainChatSession.beginGoalSubmission(submission)
    }

    @discardableResult
    public mutating func failGoalSubmission(message: String) -> CodexActivity {
        mainChatSession.failGoalSubmission(message: message)
    }

    @discardableResult
    public mutating func openSideChat() -> CodexActivity {
        sideChatSession.open()
    }

    public mutating func beginSideChatSubmission(prompt: String) -> [CodexActivity] {
        sideChatSession.beginSubmission(prompt: prompt)
    }

    public mutating func startSideChatTurn(id turnID: String, threadID: ThreadID) {
        sideChatSession.start(turnID: turnID, threadID: threadID)
    }

    @discardableResult
    public mutating func finishSideChatTurn(id turnID: String?) -> CodexSideChatSessionUpdate? {
        sideChatSession.finishTurn(id: turnID)
    }

    @discardableResult
    public mutating func failSideChatSubmission(message: String) -> CodexActivity {
        sideChatSession.failSubmission(message: message)
    }

    /// Refreshes non-transcript chrome from canonical state. This is a pure
    /// snapshot projection: it never interprets or replays protocol messages.
    public mutating func applyCanonicalSnapshot(
        _ snapshot: CodexSessionStateSnapshot,
        selectedThreadID: ThreadID?
    ) {
        guard let selectedThreadID,
              let thread = snapshot.canonical.threads[selectedThreadID]
        else {
            clearCanonicalSnapshot()
            return
        }

        hasCanonicalSnapshot = true
        let latestTurn = thread.turnOrder.reversed().lazy.compactMap { turnID in
            snapshot.canonical.turns[TurnKey(threadID: selectedThreadID, turnID: turnID)]
        }.first
        canonicalIsSending = thread.status.isActive || latestTurn?.status == .inProgress
        canonicalPlan = (latestTurn?.plan ?? []).map { step in
            TurnPlanStep(step: step.step, status: Self.planStatus(step.status))
        }
        canonicalPlanExplanation = latestTurn?.planExplanation
        canonicalDiff = latestTurn?.diff
        if canonicalDiff != nil, let latestTurn {
            canonicalDiffSourceID = "canonical/\(selectedThreadID.rawValue)/\(latestTurn.key.turnID.rawValue)"
            canonicalDiffRevision = latestTurn.lastChangedRevision
        } else {
            canonicalDiffSourceID = nil
            canonicalDiffRevision = nil
        }
        canonicalGoal = thread.goal.map(Self.threadGoal)
    }

    @discardableResult
    public mutating func applyGoal(
        _ goal: ThreadGoal,
        turnID: String?,
        shouldAnnounce: Bool = true
    ) -> CodexActivity? {
        let change = goalSession.apply(goal, turnID: turnID, shouldAnnounce: shouldAnnounce)
        if change.endedActiveTurn {
            mainChatSession.failToStart()
        }
        return change.activity.map { CodexActivity(kind: .notice, title: $0.title, detail: $0.detail) }
    }

    @discardableResult
    public mutating func clearGoal(threadID: String?, currentThreadID: String?) -> CodexActivity? {
        guard let change = goalSession.clear(threadID: threadID, currentThreadID: currentThreadID),
              let activity = change.activity else {
            return nil
        }
        return CodexActivity(kind: .notice, title: activity.title, detail: activity.detail)
    }

    public mutating func resetGoal() {
        goalSession.reset()
    }

    public mutating func resetThreadState() {
        mainChatSession.reset()
        sideChatSession.reset()
        clearCanonicalSnapshot()
    }

    private mutating func clearCanonicalSnapshot() {
        hasCanonicalSnapshot = false
        canonicalIsSending = false
        canonicalPlan = []
        canonicalPlanExplanation = nil
        canonicalDiff = nil
        canonicalDiffSourceID = nil
        canonicalDiffRevision = nil
        canonicalGoal = nil
    }

    private static func planStatus(_ status: CanonicalPlanStepStatus) -> TurnPlanStepStatus {
        switch status {
        case .pending, .unknown: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }

    private static func threadGoal(_ goal: CanonicalThreadGoal) -> ThreadGoal {
        ThreadGoal(
            threadId: goal.threadID.rawValue,
            objective: goal.objective,
            status: goalStatus(goal.status),
            tokenBudget: goal.tokenBudget.map { Int(clamping: $0) },
            tokensUsed: Int(clamping: goal.tokensUsed),
            timeUsedSeconds: Int(clamping: goal.timeUsedSeconds),
            createdAt: Int(clamping: goal.createdAt.rawValue),
            updatedAt: Int(clamping: goal.updatedAt.rawValue)
        )
    }

    private static func goalStatus(_ status: CanonicalThreadGoalStatus) -> ThreadGoalStatus {
        switch status {
        case .active, .unknown: .active
        case .paused: .paused
        case .blocked: .blocked
        case .usageLimited: .usageLimited
        case .budgetLimited: .budgetLimited
        case .complete: .complete
        }
    }
}
