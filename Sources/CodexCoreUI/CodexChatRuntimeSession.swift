import Foundation
import CodexCore

@MainActor
public final class CodexChatRuntimeSession {
    private var state: CodexChatRuntimeState
    private var subagentCoordinator: CodexSubagentPresentationCoordinator?
    public let presentationStore: CodexPresentationStore
    public let sideChatPresentationStore: CodexPresentationStore

    public init(
        state: CodexChatRuntimeState = CodexChatRuntimeState(),
        presentationStore: CodexPresentationStore = CodexPresentationStore(),
        sideChatPresentationStore: CodexPresentationStore = CodexPresentationStore()
    ) {
        self.state = state
        self.presentationStore = presentationStore
        self.sideChatPresentationStore = sideChatPresentationStore
    }

    public var integrationCatalogSession: CodexIntegrationCatalogSession {
        get { state.integrationCatalogSession }
        set { state.integrationCatalogSession = newValue }
    }

    public var lifecycleEvents: [CodexAgentLifecycleEvent] {
        subagentCoordinator?.lifecycleEvents ?? []
    }
    public var sideChat: CodexSideChatState? {
        guard var sideChat = state.sideChat else { return nil }
        if let presentation = sideChatPresentationStore.activePresentation {
            sideChat.transcript = presentation.transcript
        }
        return sideChat
    }
    public var subagents: [CodexSubagentState] {
        subagentCoordinator?.panelSubagents ?? []
    }
    public var subagentsV2: [CodexSubagentV2] {
        subagentCoordinator?.agents ?? []
    }
    public var isSending: Bool { state.isSending }
    /// Local optimistic state used to serialize queued turn submission.
    /// Unlike `isSending`, this deliberately excludes canonical snapshot state,
    /// which may still describe the just-completed turn while its completion is
    /// being handled.
    public var isMainTurnPendingOrRunning: Bool { state.mainChatSession.isSending }
    public var isSideChatSending: Bool { state.isSideChatSending }
    public var activeTurnID: String? { state.activeTurnID }
    public var activeSideChatTurnID: String? { state.activeSideChatTurnID }
    public var currentPlan: [TurnPlanStep] { state.currentPlan }
    public var currentPlanExplanation: String? { state.currentPlanExplanation }
    public var currentDiff: String? { state.currentDiff }
    public var activeGoal: ThreadGoal? { state.activeGoal }
    public var isGoalPursuitEnabled: Bool { state.isGoalPursuitEnabled }
    public var activeGoalTurnID: String? { state.activeGoalTurnID }
    public var hasActiveGoal: Bool { state.hasActiveGoal }
    public var transcriptV2: CodexTranscriptV2 {
        presentationStore.activeCanonicalPresentation?.transcript ?? .init()
    }
    public var presentedTranscriptV2: CodexTranscriptV2 {
        presentationStore.activePresentation?.transcript ?? .init()
    }
    public var activePresentation: CodexThreadUIPresentation? { presentationStore.activePresentation }
    public var activeRenderUpdate: CodexCanonicalTranscriptRenderUpdate? {
        presentationStore.activeRenderUpdate
    }

    public func selectThread(_ threadID: String?) {
        let threadID = threadID.map { ThreadID($0) }
        presentationStore.select(threadID: threadID)
        subagentCoordinator?.selectParent(threadID)
    }

    /// Updates the subagent transcript currently visible in the agent panel.
    public func selectSubagentTranscript(_ threadID: String?) {
        subagentCoordinator?.selectTranscript(threadID.map { ThreadID($0) })
    }

    /// Connects every runtime projection to one public facade and therefore one
    /// ordered `CodexSession` actor.
    public func connect(to codex: Codex) async {
        await disconnect()
        let adapter = CodexPresentationStateAdapter(session: codex.session)
        presentationStore.connect(adapter)
        sideChatPresentationStore.connect(adapter)
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        subagentCoordinator = coordinator
        coordinator.selectParent(presentationStore.selectedThreadID)
    }

    public func disconnect() async {
        presentationStore.disconnect()
        sideChatPresentationStore.disconnect()
        if let subagentCoordinator {
            await subagentCoordinator.disconnect()
            self.subagentCoordinator = nil
        }
    }

    public func applyCanonicalSnapshot(_ snapshot: CodexSessionStateSnapshot) {
        state.applyCanonicalSnapshot(
            snapshot,
            selectedThreadID: presentationStore.selectedThreadID
        )
    }

    public func canSendFollowUp(canSteer: Bool) -> Bool {
        state.canSendFollowUp(canSteer: canSteer)
    }

    public func goalSummary(for goal: ThreadGoal) -> String {
        state.goalSummary(for: goal)
    }

    public func setGoalPursuitEnabled(_ enabled: Bool) -> CodexGoalPursuitModeChange? {
        state.setGoalPursuitEnabled(enabled)
    }

    public func restorePursuitAfterClearFailure() {
        state.restorePursuitAfterClearFailure()
    }

    public func prepareFollowUp(
        submission: CodexComposerSubmission,
        composerSession: inout CodexComposerStateSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        state.prepareFollowUp(
            submission: submission,
            composerSession: &composerSession,
            followUpBehavior: followUpBehavior,
            canSteer: canSteer
        )
    }

    public func prepareFollowUp(
        prompt: String,
        composerSession: inout CodexComposerStateSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        state.prepareFollowUp(
            prompt: prompt,
            composerSession: &composerSession,
            followUpBehavior: followUpBehavior,
            canSteer: canSteer
        )
    }

    public func dequeueQueuedFollowUp(
        composerSession: inout CodexComposerStateSession,
        isSending: Bool
    ) -> CodexQueuedFollowUpSubmission? {
        state.dequeueQueuedFollowUp(composerSession: &composerSession, isSending: isSending)
    }

    public func failQueuedFollowUp(
        _ submission: CodexQueuedFollowUpSubmission,
        message: String,
        composerSession: inout CodexComposerStateSession
    ) -> CodexActivity {
        state.failQueuedFollowUp(submission, message: message, composerSession: &composerSession)
    }

    public func beginMainTurnSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        state.beginTurnSubmission(submission)
    }

    public func startMainTurn(id turnID: String) {
        state.startMainTurn(id: turnID)
    }

    public func failMainTurnSubmission(message: String) -> CodexActivity {
        state.failTurnSubmission(message: message)
    }

    public func finishMainTurn(id turnID: String?) -> CodexMainChatUpdate? {
        state.finishMainTurn(id: turnID)
    }

    public func beginGoalSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        state.beginGoalSubmission(submission)
    }

    public func failGoalSubmission(message: String) -> CodexActivity {
        state.failGoalSubmission(message: message)
    }

    public func openSideChat() -> CodexActivity {
        state.openSideChat()
    }

    public func beginSideChatSubmission(prompt: String) -> [CodexActivity] {
        state.beginSideChatSubmission(prompt: prompt)
    }

    public func startSideChat(id turnID: String, threadID: String) {
        let threadID = ThreadID(threadID)
        sideChatPresentationStore.select(threadID: threadID)
        state.startSideChatTurn(id: turnID, threadID: threadID)
    }

    public func failSideChatSubmission(message: String) -> CodexActivity {
        state.failSideChatSubmission(message: message)
    }

    public func finishSideChat(id turnID: String?) -> CodexSideChatSessionUpdate? {
        state.finishSideChatTurn(id: turnID)
    }

    public func applyGoal(_ goal: ThreadGoal, turnID: String?, shouldAnnounce: Bool = true) -> CodexActivity? {
        state.applyGoal(goal, turnID: turnID, shouldAnnounce: shouldAnnounce)
    }

    public func resetGoal() {
        state.resetGoal()
    }

    public func resetThreadState(deactivateTranscript: Bool = true) {
        state.resetThreadState()
        if deactivateTranscript { selectThread(nil) }
    }

    public func reset() {
        state.resetThreadState()
        subagentCoordinator?.selectParent(nil)
        presentationStore.resetLocalState()
        sideChatPresentationStore.resetLocalState()
    }

}
