import Foundation
import CodexCore

@MainActor
public final class CodexChatRuntimeSession {
    private struct HostBindings {
        var currentThreadID: @MainActor () -> String?
        var store: @MainActor () -> CodexCoreStore?
        var applyResult: @MainActor (CodexChatNotificationPipelineResult) -> Void
        var applySideChatUpdate: @MainActor (CodexSideChatSessionUpdate) -> Void
    }

    private var state: CodexChatRuntimeState
    private let streams: CodexChatStreamSession
    private var hostBindings: HostBindings?
    private var transcriptReducerV2: CodexTranscriptReducerV2?

    public init(
        state: CodexChatRuntimeState = CodexChatRuntimeState(),
        streams: CodexChatStreamSession = CodexChatStreamSession()
    ) {
        self.state = state
        self.streams = streams
    }

    public var integrationCatalogSession: CodexIntegrationCatalogSession {
        get { state.integrationCatalogSession }
        set { state.integrationCatalogSession = newValue }
    }

    public var messages: [CodexChatMessage] { state.messages }
    public var lifecycleEvents: [CodexAgentLifecycleEvent] { state.lifecycleEvents }
    public var sideChat: CodexSideChatState? { state.sideChat }
    public var subagents: [CodexSubagentState] { state.subagents }
    public var isSending: Bool { state.isSending }
    public var isSideChatSending: Bool { state.isSideChatSending }
    public var activeTurn: CodexTurnHandle? { state.activeTurn }
    public var activeSideChatTurn: CodexTurnHandle? { state.activeSideChatTurn }
    public var currentPlan: [TurnPlanStep] { state.currentPlan }
    public var currentPlanExplanation: String? { state.currentPlanExplanation }
    public var currentDiff: String? { state.currentDiff }
    public var activeGoal: ThreadGoal? { state.activeGoal }
    public var isGoalPursuitEnabled: Bool { state.isGoalPursuitEnabled }
    public var activeGoalTurnID: String? { state.activeGoalTurnID }
    public var hasActiveGoal: Bool { state.hasActiveGoal }
    public var threadHistorySnapshot: CodexThreadHistorySnapshot { state.threadHistorySnapshot }
    public var transcriptV2: CodexTranscriptV2 { transcriptReducerV2?.transcript ?? .init() }

    public func bindHost(
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void,
        applySideChatUpdate: @escaping @MainActor (CodexSideChatSessionUpdate) -> Void
    ) {
        hostBindings = HostBindings(
            currentThreadID: currentThreadID,
            store: store,
            applyResult: applyResult,
            applySideChatUpdate: applySideChatUpdate
        )
    }

    public func canSendFollowUp(hasActiveTurnHandle: Bool) -> Bool {
        state.canSendFollowUp(hasActiveTurnHandle: hasActiveTurnHandle)
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

    public func startMainTurn(_ handle: CodexTurnHandle) {
        state.startMainTurn(handle)
    }

    public func openSideChat() -> CodexActivity {
        state.openSideChat()
    }

    public func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        state.appendMessage(role, text, detail: detail)
    }

    public func append(_ message: CodexChatMessage) {
        state.append(message)
    }

    @discardableResult
    public func submitMainTurn(
        _ submission: CodexComposerSubmission,
        start: @escaping @MainActor () async throws -> CodexTurnHandle,
        onActivity: @escaping @MainActor (CodexActivity) -> Void,
        errorMessage: (Error) -> String
    ) async -> Bool {
        guard let hostBindings else {
            onActivity(state.failTurnSubmission(message: "Runtime host is not connected"))
            return false
        }
        return await submitMainTurn(
            submission,
            start: start,
            currentThreadID: hostBindings.currentThreadID,
            store: hostBindings.store,
            applyResult: hostBindings.applyResult,
            onActivity: onActivity,
            errorMessage: errorMessage
        )
    }

    @discardableResult
    public func submitMainTurn(
        _ submission: CodexComposerSubmission,
        start: @escaping @MainActor () async throws -> CodexTurnHandle,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void,
        onActivity: @escaping @MainActor (CodexActivity) -> Void,
        errorMessage: (Error) -> String
    ) async -> Bool {
        onActivity(state.beginTurnSubmission(submission))
        var optimisticThreadID: String?
        if let threadID = currentThreadID() {
            prepareTranscriptReducerV2(for: threadID)
            transcriptReducerV2?.submitLocalUserMessage(text: submission.prompt, clientID: submission.clientID)
            optimisticThreadID = threadID
        }
        do {
            let handle = try await start()
            if optimisticThreadID != handle.threadId {
                prepareTranscriptReducerV2(for: handle.threadId)
                transcriptReducerV2?.submitLocalUserMessage(text: submission.prompt, clientID: submission.clientID)
            }
            state.startMainTurn(handle)
            consumeMainTurn(
                handle,
                currentThreadID: currentThreadID,
                store: store,
                applyResult: applyResult
            )
            return true
        } catch {
            onActivity(state.failTurnSubmission(message: errorMessage(error)))
            return false
        }
    }

    @discardableResult
    public func submitGoal(
        _ submission: CodexComposerSubmission,
        start: @escaping @MainActor () async throws -> ThreadGoal,
        onActivity: @escaping @MainActor (CodexActivity) -> Void,
        errorMessage: (Error) -> String
    ) async -> Bool {
        onActivity(state.beginGoalSubmission(submission))
        do {
            let goal = try await start()
            if let activity = state.applyGoal(goal, turnID: nil) {
                onActivity(activity)
            }
            onActivity(CodexActivity(kind: .notice, title: "Goal started", detail: state.goalSummary(for: goal)))
            return true
        } catch {
            onActivity(state.failGoalSubmission(message: errorMessage(error)))
            return false
        }
    }

    @discardableResult
    public func submitSideChat(
        prompt: String,
        start: @escaping @MainActor () async throws -> CodexTurnHandle,
        onActivity: @escaping @MainActor (CodexActivity) -> Void,
        errorMessage: (Error) -> String
    ) async -> Bool {
        guard let hostBindings else {
            onActivity(state.failSideChatSubmission(message: "Runtime host is not connected"))
            return false
        }
        return await submitSideChat(
            prompt: prompt,
            start: start,
            currentThreadID: hostBindings.currentThreadID,
            store: hostBindings.store,
            applyUpdate: hostBindings.applySideChatUpdate,
            onActivity: onActivity,
            errorMessage: errorMessage
        )
    }

    @discardableResult
    public func submitSideChat(
        prompt: String,
        start: @escaping @MainActor () async throws -> CodexTurnHandle,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyUpdate: @escaping @MainActor (CodexSideChatSessionUpdate) -> Void,
        onActivity: @escaping @MainActor (CodexActivity) -> Void,
        errorMessage: (Error) -> String
    ) async -> Bool {
        for activity in state.beginSideChatSubmission(prompt: prompt) {
            onActivity(activity)
        }
        do {
            let handle = try await start()
            state.startSideChatTurn(handle)
            consumeSideChatTurn(
                handle,
                currentThreadID: currentThreadID,
                store: store,
                applyUpdate: applyUpdate
            )
            return true
        } catch {
            onActivity(state.failSideChatSubmission(message: errorMessage(error)))
            return false
        }
    }

    public func applyHistoryRestore(_ result: CodexThreadHistoryRestoreResult) -> CodexActivity {
        var reducer = CodexTranscriptReducerV2(threadID: result.hydration.parent.snapshot.id)
        reducer.restoreHistory(items: result.transcriptItemsV2)
        transcriptReducerV2 = reducer
        return state.applyHistoryRestore(result)
    }

    public func applyGoal(_ goal: ThreadGoal, turnID: String?, shouldAnnounce: Bool = true) -> CodexActivity? {
        state.applyGoal(goal, turnID: turnID, shouldAnnounce: shouldAnnounce)
    }

    public func resetGoal() {
        state.resetGoal()
    }

    public func resetThreadState() {
        streams.cancelTurnStreams()
        state.resetThreadState()
        transcriptReducerV2 = nil
    }

    public func cancelGlobalNotifications() {
        streams.cancelGlobalNotifications()
    }

    public func reset() {
        streams.reset()
        state.resetThreadState()
        transcriptReducerV2 = nil
    }

    public func consumeMainTurn(
        _ handle: CodexTurnHandle
    ) {
        guard let hostBindings else { return }
        consumeMainTurn(
            handle,
            currentThreadID: hostBindings.currentThreadID,
            store: hostBindings.store,
            applyResult: hostBindings.applyResult
        )
    }

    public func consumeMainTurn(
        _ handle: CodexTurnHandle,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        consumeMainTurnStream(
            id: handle.id,
            notifications: handle.stream(),
            currentThreadID: currentThreadID,
            store: store,
            applyResult: applyResult
        )
    }

    public func consumeMainTurnStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        streams.consumeMainTurnResultStream(
            id: turnID,
            notifications: notifications,
            routeNotification: { [weak self] notification in
                self?.applyToTranscriptV2(notification, threadID: currentThreadID())
                return self?.state.apply(
                    notification,
                    mode: .mainTurnStream,
                    currentThreadID: currentThreadID(),
                    store: store()
                )
            },
            finishTurn: { [weak self] turnID in
                self?.state.finishMainTurn(id: turnID, currentThreadID: currentThreadID())
            },
            applyResult: applyResult
        )
    }

    public func consumeSideChatTurn(
        _ handle: CodexTurnHandle
    ) {
        guard let hostBindings else { return }
        consumeSideChatTurn(
            handle,
            currentThreadID: hostBindings.currentThreadID,
            store: hostBindings.store,
            applyUpdate: hostBindings.applySideChatUpdate
        )
    }

    public func consumeSideChatTurn(
        _ handle: CodexTurnHandle,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyUpdate: @escaping @MainActor (CodexSideChatSessionUpdate) -> Void
    ) {
        consumeSideChatTurnStream(
            id: handle.id,
            notifications: handle.stream(),
            currentThreadID: currentThreadID,
            store: store,
            applyUpdate: applyUpdate
        )
    }

    public func consumeSideChatTurnStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        currentThreadID: @escaping @MainActor () -> String?,
        store: @escaping @MainActor () -> CodexCoreStore?,
        applyUpdate: @escaping @MainActor (CodexSideChatSessionUpdate) -> Void
    ) {
        streams.consumeSideChatTurnUpdateStream(
            id: turnID,
            notifications: notifications,
            routeNotification: { [weak self] notification in
                self?.state.applySideChat(
                    notification,
                    store: store(),
                    currentThreadID: currentThreadID()
                )
            },
            finishTurn: { [weak self] turnID in
                self?.state.finishSideChatTurn(id: turnID)
            },
            applyUpdate: applyUpdate
        )
    }

    public func consumeGlobalNotifications(
        from codex: Codex
    ) {
        guard let hostBindings else { return }
        consumeGlobalNotifications(
            from: codex,
            currentThreadID: hostBindings.currentThreadID,
            applyResult: hostBindings.applyResult
        )
    }

    public func consumeGlobalNotifications(
        from codex: Codex,
        currentThreadID: @escaping @MainActor () -> String?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        consumeGlobalNotificationStream(
            codex.notifications(),
            store: codex.store,
            currentThreadID: currentThreadID,
            applyResult: applyResult
        )
    }

    public func consumeGlobalNotificationStream(
        _ notifications: AsyncStream<CodexNotification>,
        store: CodexCoreStore?,
        currentThreadID: @escaping @MainActor () -> String?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        streams.consumeGlobalNotificationResultStream(
            notifications,
            routeNotification: { [weak self] notification in
                self?.applyToTranscriptV2(notification, threadID: currentThreadID())
                return self?.state.apply(
                    notification,
                    mode: .globalStream,
                    currentThreadID: currentThreadID(),
                    store: store
                )
            },
            applyResult: applyResult
        )
    }

    private func prepareTranscriptReducerV2(for threadID: String) {
        if transcriptReducerV2?.threadID != threadID {
            transcriptReducerV2 = CodexTranscriptReducerV2(threadID: threadID)
        }
    }

    private func applyToTranscriptV2(_ notification: CodexNotification, threadID: String?) {
        guard let threadID else { return }
        prepareTranscriptReducerV2(for: threadID)
        transcriptReducerV2?.apply(
            method: notification.method,
            params: .dictionary(notification.rawParams)
        )
    }
}
