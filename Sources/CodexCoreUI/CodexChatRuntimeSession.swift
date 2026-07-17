import Foundation
import CodexCore

@MainActor
public final class CodexChatRuntimeSession {
    enum TranscriptIngressSource {
        case mainTurn
        case global
    }

    private struct PendingTranscriptIngress {
        var mainTurn: [Date] = []
        var global: [Date] = []
    }

    private struct HostBindings {
        var currentThreadID: @MainActor () -> String?
        var store: @MainActor () -> CodexCoreStore?
        var applyResult: @MainActor (CodexChatNotificationPipelineResult) -> Void
        var applySideChatUpdate: @MainActor (CodexSideChatSessionUpdate) -> Void
    }

    private var state: CodexChatRuntimeState
    private let streams: CodexChatStreamSession
    private var hostBindings: HostBindings?
    public let transcriptSessions: CodexThreadUISessionStore
    public let threadStatusStore: CodexThreadStatusStore
    private var subagentStoreV2 = CodexSubagentStoreV2()
    private var discoveryCodex: Codex?
    private var requestedSubagentIDs: Set<String> = []
    private var pendingTranscriptIngressByFingerprint: [String: PendingTranscriptIngress] = [:]
    public private(set) var transcriptIngressDeduplicationCount = 0

    public init(
        state: CodexChatRuntimeState = CodexChatRuntimeState(),
        streams: CodexChatStreamSession = CodexChatStreamSession(),
        transcriptSessions: CodexThreadUISessionStore = CodexThreadUISessionStore(),
        threadStatusStore: CodexThreadStatusStore = CodexThreadStatusStore()
    ) {
        self.state = state
        self.streams = streams
        self.transcriptSessions = transcriptSessions
        self.threadStatusStore = threadStatusStore
    }

    public var integrationCatalogSession: CodexIntegrationCatalogSession {
        get { state.integrationCatalogSession }
        set { state.integrationCatalogSession = newValue }
    }

    public var lifecycleEvents: [CodexAgentLifecycleEvent] { state.lifecycleEvents }
    public var sideChat: CodexSideChatState? { state.sideChat }
    public var subagents: [CodexSubagentState] {
        let nativeAgents = activeSubagentsV2.map { agent in
            CodexSubagentState(
                id: agent.threadID,
                name: agent.displayName,
                title: agent.role.map { "\(agent.displayName) (\($0))" } ?? agent.displayName,
                prompt: agent.prompt ?? "Subagent task",
                status: agent.legacyStatus,
                transcript: agent.transcript
            )
        }
        return nativeAgents.isEmpty ? state.subagents : nativeAgents
    }
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
    public var transcriptV2: CodexTranscriptV2 { transcriptSessions.activeTruthTranscript }
    public var presentedTranscriptV2: CodexTranscriptV2 {
        transcriptSessions.activePresentation?.transcript ?? .init()
    }
    public var subagentsV2: CodexSubagentStoreV2 { subagentStoreV2 }

    public func selectThread(_ threadID: String?) {
        transcriptSessions.activate(threadID: threadID)
        threadStatusStore.select(threadID: threadID)
    }

    public func hasWarmTranscriptSession(threadID: String) -> Bool {
        transcriptSessions.containsWarmSession(for: threadID)
    }

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
            selectThread(threadID)
            transcriptSessions.submitLocalUserMessage(text: submission.prompt, clientID: submission.clientID, threadID: threadID)
            optimisticThreadID = threadID
        }
        do {
            let handle = try await start()
            if optimisticThreadID != handle.threadId {
                selectThread(handle.threadId)
                transcriptSessions.submitLocalUserMessage(text: submission.prompt, clientID: submission.clientID, threadID: handle.threadId)
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

    public func applyHistoryRestore(
        _ result: CodexThreadHistoryRestoreResult,
        restoreTranscript: Bool = true
    ) -> CodexActivity {
        let threadID = result.hydration.parent.snapshot.id
        selectThread(threadID)
        if restoreTranscript {
            transcriptSessions.restoreHistory(turns: result.transcriptTurnsV2, threadID: threadID)
        }
        return state.applyHistoryRestore(result)
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

    public func cancelGlobalNotifications() {
        streams.cancelGlobalNotifications()
    }

    public func reset() {
        streams.reset()
        state.resetThreadState()
        transcriptSessions.reset()
        threadStatusStore.reset()
        subagentStoreV2 = CodexSubagentStoreV2()
        requestedSubagentIDs = []
        pendingTranscriptIngressByFingerprint = [:]
        transcriptIngressDeduplicationCount = 0
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
                self?.applyTranscriptNotification(
                    notification,
                    fallbackThreadID: currentThreadID(),
                    source: .mainTurn
                )
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
        discoveryCodex = codex
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
                self?.applyTranscriptNotification(
                    notification,
                    fallbackThreadID: currentThreadID(),
                    source: .global
                )
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

    func applyTranscriptNotification(
        _ notification: CodexNotification,
        fallbackThreadID: String?,
        source: TranscriptIngressSource
    ) {
        guard shouldApplyTranscriptNotification(notification, source: source) else { return }
        let params = CodexJSONValue.dictionary(notification.rawParams)
        let discoveries = subagentStoreV2.apply(method: notification.method, params: params)
        for discovery in discoveries { discoverSubagent(discovery) }
        guard let threadID = CodexNotificationMetadata.threadID(from: notification) ?? fallbackThreadID else { return }
        guard !subagentStoreV2.contains(threadID: threadID) else { return }
        transcriptSessions.apply(method: notification.method, params: params, threadID: threadID)
        threadStatusStore.apply(method: notification.method, params: params, threadID: threadID)
    }

    private func shouldApplyTranscriptNotification(
        _ notification: CodexNotification,
        source: TranscriptIngressSource,
        now: Date = Date()
    ) -> Bool {
        let fingerprint = Self.transcriptIngressFingerprint(notification)
        let cutoff = now.addingTimeInterval(-5)
        var pending = pendingTranscriptIngressByFingerprint[fingerprint] ?? PendingTranscriptIngress()
        pending.mainTurn.removeAll { $0 < cutoff }
        pending.global.removeAll { $0 < cutoff }

        let shouldApply: Bool
        switch source {
        case .mainTurn:
            if pending.global.isEmpty {
                pending.mainTurn.append(now)
                shouldApply = true
            } else {
                pending.global.removeFirst()
                transcriptIngressDeduplicationCount &+= 1
                shouldApply = false
            }
        case .global:
            if pending.mainTurn.isEmpty {
                pending.global.append(now)
                shouldApply = true
            } else {
                pending.mainTurn.removeFirst()
                transcriptIngressDeduplicationCount &+= 1
                shouldApply = false
            }
        }

        if pending.mainTurn.isEmpty && pending.global.isEmpty {
            pendingTranscriptIngressByFingerprint.removeValue(forKey: fingerprint)
        } else {
            pendingTranscriptIngressByFingerprint[fingerprint] = pending
        }
        if pendingTranscriptIngressByFingerprint.count > 2_048 {
            pendingTranscriptIngressByFingerprint = pendingTranscriptIngressByFingerprint.filter { _, value in
                value.mainTurn.contains { $0 >= cutoff } || value.global.contains { $0 >= cutoff }
            }
        }
        return shouldApply
    }

    private static func transcriptIngressFingerprint(_ notification: CodexNotification) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let params = (try? encoder.encode(CodexJSONValue.dictionary(notification.rawParams))) ?? Data()
        return notification.method + "\u{0}" + params.base64EncodedString()
    }

    private var activeSubagentsV2: [CodexSubagentV2] {
        guard let parentThreadID = transcriptSessions.activeThreadID else { return [] }
        let allAgents = subagentStoreV2.agents
        var includedParents: Set<String> = [parentThreadID]
        var changed = true
        while changed {
            changed = false
            for agent in allAgents where agent.parentThreadID.map(includedParents.contains) == true {
                if includedParents.insert(agent.threadID).inserted { changed = true }
            }
        }
        return allAgents.filter { includedParents.contains($0.threadID) }
    }

    private func discoverSubagent(_ discovery: CodexSubagentDiscoveryV2) {
        guard let codex = discoveryCodex, requestedSubagentIDs.insert(discovery.threadID).inserted else { return }
        Task { [weak self] in
            if let response = try? await codex.threadReadSchema(discovery.threadID, includeTurns: false) {
                self?.applySubagentMetadata(response.thread)
            }
            _ = try? await codex.threadResume(discovery.threadID)
            if let response = try? await codex.threadListSchema(.init(parentThreadID: discovery.threadID)) {
                for child in response.data { self?.discoverListedSubagent(child) }
            }
        }
    }

    private func applySubagentMetadata(_ thread: CodexSchemaThread) {
        let source = Self.agentSource(thread.threadSource?.rawValue) ?? Self.agentSource(thread.extra?.rawValue)
        let fields = source ?? [:]
        _ = state.agentStateMapper.updateSubagentMetadata(id: thread.id, name: thread.agentNickname, role: thread.agentRole)
        subagentStoreV2.updateMetadata(threadID: thread.id, nickname: thread.agentNickname, role: thread.agentRole,
            agentPath: Self.string(in: fields, keys: ["agentPath", "agent_path"]),
            depth: Self.int(in: fields, keys: ["depth"]),
            parentThreadID: Self.string(in: fields, keys: ["parentThreadId", "parent_thread_id"]) ?? thread.parentThreadID)
    }

    private func discoverListedSubagent(_ thread: CodexSchemaThread) {
        let source = Self.agentSource(thread.threadSource?.rawValue) ?? Self.agentSource(thread.extra?.rawValue)
        let fields = source ?? [:]
        let parent = Self.string(in: fields, keys: ["parentThreadId", "parent_thread_id"]) ?? thread.parentThreadID
        let path = Self.string(in: fields, keys: ["agentPath", "agent_path"])
        let isNew = subagentStoreV2.register(threadID: thread.id, parentThreadID: parent, agentPath: path)
        applySubagentMetadata(thread)
        if isNew { discoverSubagent(.init(threadID: thread.id, parentThreadID: parent, agentPath: path)) }
    }

    private static func agentSource(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object) = value else { return nil }
        for key in ["subAgent", "sub_agent", "subAgentThreadSpawn", "sub_agent_thread_spawn"] {
            if case .dictionary(let nested)? = object[key] { return nested }
        }
        return object
    }
    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys { if case .string(let value)? = object[key] { return value } }
        return nil
    }
    private static func int(in object: [String: CodexJSONValue], keys: [String]) -> Int? {
        for key in keys { if case .int(let value)? = object[key] { return value } }
        return nil
    }

}
