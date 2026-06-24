import Foundation
import CodexCore

public struct CodexChatRuntimeState: Sendable {
    public var goalSession: CodexGoalStateSession
    public var mainChatSession: CodexMainChatSession
    public var sideChatSession: CodexSideChatSession
    public var agentStateMapper: CodexAgentStateMapper
    public var integrationCatalogSession: CodexIntegrationCatalogSession

    public init(
        goalSession: CodexGoalStateSession = CodexGoalStateSession(),
        mainChatSession: CodexMainChatSession = CodexMainChatSession(),
        sideChatSession: CodexSideChatSession = CodexSideChatSession(),
        agentStateMapper: CodexAgentStateMapper = CodexAgentStateMapper(),
        integrationCatalogSession: CodexIntegrationCatalogSession = CodexIntegrationCatalogSession()
    ) {
        self.goalSession = goalSession
        self.mainChatSession = mainChatSession
        self.sideChatSession = sideChatSession
        self.agentStateMapper = agentStateMapper
        self.integrationCatalogSession = integrationCatalogSession
    }

    public var messages: [CodexChatMessage] {
        mainChatSession.messages
    }

    public var lifecycleEvents: [CodexAgentLifecycleEvent] {
        agentStateMapper.lifecycleEvents
    }

    public var sideChat: CodexSideChatState? {
        sideChatSession.sideChat ?? agentStateMapper.sideChat
    }

    public var subagents: [CodexSubagentState] {
        agentStateMapper.subagents
    }

    public var isSending: Bool {
        mainChatSession.isSending
    }

    public var isSideChatSending: Bool {
        sideChatSession.isSending
    }

    public var activeTurn: CodexTurnHandle? {
        mainChatSession.activeTurn
    }

    public var activeSideChatTurn: CodexTurnHandle? {
        sideChatSession.activeTurn
    }

    public var currentPlan: [TurnPlanStep] {
        mainChatSession.currentPlan
    }

    public var currentPlanExplanation: String? {
        mainChatSession.currentPlanExplanation
    }

    public var currentDiff: String? {
        mainChatSession.currentDiff
    }

    public var activeGoal: ThreadGoal? {
        goalSession.activeGoal
    }

    public var isGoalPursuitEnabled: Bool {
        goalSession.isPursuitEnabled
    }

    public var activeGoalTurnID: String? {
        goalSession.activeTurnID
    }

    public func canSendFollowUp(hasActiveTurnHandle: Bool) -> Bool {
        isSending && goalSession.canSendFollowUp(hasActiveTurnHandle: hasActiveTurnHandle)
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
        prompt: String,
        composerSession: inout CodexComposerStateSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        CodexTurnSubmissionSession.prepareFollowUp(
            prompt: prompt,
            composerSession: &composerSession,
            mainChatSession: &mainChatSession,
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

    public mutating func startMainTurn(_ handle: CodexTurnHandle) {
        mainChatSession.start(handle)
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

    public mutating func startSideChatTurn(_ handle: CodexTurnHandle) {
        sideChatSession.start(handle)
    }

    @discardableResult
    public mutating func failSideChatSubmission(message: String) -> CodexActivity {
        sideChatSession.failSubmission(message: message)
    }

    public mutating func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        mainChatSession.appendMessage(role, text, detail: detail)
    }

    public mutating func append(_ message: CodexChatMessage) {
        mainChatSession.append(message)
    }

    @discardableResult
    @MainActor
    public mutating func apply(
        _ notification: CodexNotification,
        mode: CodexChatNotificationPipelineMode,
        currentThreadID: String?,
        store: CodexCoreStore?
    ) -> CodexChatNotificationPipelineResult? {
        CodexChatNotificationRuntime.apply(
            notification,
            mode: mode,
            currentThreadID: currentThreadID,
            store: store,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper,
            integrationCatalogSession: &integrationCatalogSession
        )
    }

    @discardableResult
    @MainActor
    public mutating func applySideChat(
        _ notification: CodexNotification,
        store: CodexCoreStore?,
        currentThreadID: String?
    ) -> CodexSideChatSessionUpdate? {
        CodexChatNotificationRuntime.applySideChat(
            notification,
            store: store,
            currentThreadID: currentThreadID,
            sideChatSession: &sideChatSession
        )
    }

    @discardableResult
    @MainActor
    public mutating func finishMainTurn(
        id turnID: String?,
        currentThreadID: String?
    ) -> CodexChatNotificationPipelineResult? {
        CodexChatNotificationRuntime.finishMainTurn(
            id: turnID,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper
        )
    }

    @discardableResult
    @MainActor
    public mutating func finishSideChatTurn(id turnID: String?) -> CodexSideChatSessionUpdate? {
        CodexChatNotificationRuntime.finishSideChatTurn(
            id: turnID,
            sideChatSession: &sideChatSession
        )
    }

    @discardableResult
    public mutating func applyHistoryRestore(_ result: CodexThreadHistoryRestoreResult) -> CodexActivity {
        CodexThreadHistorySession.apply(
            result,
            mainChatSession: &mainChatSession,
            agentStateMapper: &agentStateMapper,
            sideChatSession: &sideChatSession
        )
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
        agentStateMapper.reset()
    }
}
