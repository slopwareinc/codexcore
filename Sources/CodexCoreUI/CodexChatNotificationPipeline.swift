import Foundation
import CodexCore

public enum CodexChatNotificationPipelineMode: Equatable, Sendable {
    case mainTurnStream
    case globalStream
}

public enum CodexChatNotificationPipelineAction: Equatable, Sendable {
    case refreshRecentChats
    case refreshSlashCommands(forceReload: Bool)
    case flushQueuedFollowUps
}

public struct CodexChatNotificationPipelineResult: Equatable, Sendable {
    public var syncMainTranscript: Bool
    public var syncAgentState: Bool
    public var didApplyTranscriptIngress: Bool
    public var activities: [CodexActivity]
    public var actions: [CodexChatNotificationPipelineAction]

    public init(
        syncMainTranscript: Bool = false,
        syncAgentState: Bool = false,
        didApplyTranscriptIngress: Bool = false,
        activities: [CodexActivity] = [],
        actions: [CodexChatNotificationPipelineAction] = []
    ) {
        self.syncMainTranscript = syncMainTranscript
        self.syncAgentState = syncAgentState
        self.didApplyTranscriptIngress = didApplyTranscriptIngress
        self.activities = activities
        self.actions = actions
    }

    public mutating func merge(_ other: CodexChatNotificationPipelineResult) {
        syncMainTranscript = syncMainTranscript || other.syncMainTranscript
        syncAgentState = syncAgentState || other.syncAgentState
        didApplyTranscriptIngress = didApplyTranscriptIngress || other.didApplyTranscriptIngress
        activities.append(contentsOf: other.activities)
        actions.append(contentsOf: other.actions)
    }
}

public enum CodexChatNotificationPipeline {
    public static func apply(
        _ notification: CodexNotification,
        mode: CodexChatNotificationPipelineMode,
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper,
        integrationCatalogSession: inout CodexIntegrationCatalogSession,
        turnSnapshot: (String?, String?) -> CodexTurnSnapshot?
    ) -> CodexChatNotificationPipelineResult? {
        if let result = applyAgentMessageDelta(notification, agentStateMapper: &agentStateMapper) {
            return result
        }

        if let result = applyGlobalNotification(
            notification,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper,
            integrationCatalogSession: &integrationCatalogSession,
            turnSnapshot: turnSnapshot
        ) {
            return result
        }

        if let result = applySubagentNotification(
            notification,
            agentStateMapper: &agentStateMapper,
            turnSnapshot: turnSnapshot
        ) {
            return result
        }

        guard mode == .mainTurnStream ||
            goalSession.isActiveTurnNotification(notification) ||
            mainChatSession.isCompletion(notification) ||
            isGlobalNoticeCardNotification(notification) else {
            return nil
        }

        return applyMainNotification(
            notification,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper,
            turnSnapshot: turnSnapshot
        )
    }

    public static func apply(
        _ update: CodexMainChatUpdate,
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper
    ) -> CodexChatNotificationPipelineResult {
        var result = CodexChatNotificationPipelineResult(syncMainTranscript: true)
        applyMainUpdateActions(
            update.actions,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper,
            result: &result
        )
        return result
    }

    private static func applyAgentMessageDelta(
        _ notification: CodexNotification,
        agentStateMapper: inout CodexAgentStateMapper
    ) -> CodexChatNotificationPipelineResult? {
        guard let delta = CodexMainChatSession.agentMessageDelta(from: notification),
              agentStateMapper.messageDelta(delta.delta, itemID: delta.itemID) else {
            return nil
        }
        return CodexChatNotificationPipelineResult(syncAgentState: true)
    }

    private static func applyGlobalNotification(
        _ notification: CodexNotification,
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper,
        integrationCatalogSession: inout CodexIntegrationCatalogSession,
        turnSnapshot: (String?, String?) -> CodexTurnSnapshot?
    ) -> CodexChatNotificationPipelineResult? {
        guard let route = CodexGlobalNotificationRouter.apply(
            notification,
            context: goalSession.globalRouteContext(currentThreadID: currentThreadID)
        ) else {
            return nil
        }

        var result = CodexChatNotificationPipelineResult()
        guard let action = route.action else { return result }

        switch action {
        case .threadStartedMetadata(let metadata):
            if metadata.parentThreadID == currentThreadID,
               agentStateMapper.registerSubagentThread(
                   id: metadata.threadID,
                   name: metadata.name,
                   role: metadata.role
               ) {
                result.syncAgentState = true
            }

        case .threadListChanged:
            result.actions.append(.refreshRecentChats)

        case .skillsChanged:
            result.actions.append(.refreshSlashCommands(forceReload: true))

        case .threadCompacted(let threadID):
            guard threadID == nil || threadID == currentThreadID else { return result }
            result.activities.append(activity(.notice, title: "Context compacted", detail: threadID ?? currentThreadID ?? "Current chat"))
            result.actions.append(.refreshRecentChats)

        case .goalUpdated(let goal, let turnID):
            applyGoal(goal, turnID: turnID, shouldAnnounce: true, mainChatSession: &mainChatSession, goalSession: &goalSession, result: &result)

        case .goalCleared(let threadID):
            applyGoalCleared(threadID: threadID, currentThreadID: currentThreadID, goalSession: &goalSession, result: &result)

        case .goalTurnStarted(let turnID):
            goalSession.trackStartedTurn(id: turnID)
            mainChatSession.start(turnID: turnID)
            if let mainResult = applyMainNotification(
                notification,
                currentThreadID: currentThreadID,
                mainChatSession: &mainChatSession,
                goalSession: &goalSession,
                agentStateMapper: &agentStateMapper,
                turnSnapshot: turnSnapshot
            ) {
                result.merge(mainResult)
            }

        case .mcpServerStartupStatus(let update):
            integrationCatalogSession.applyMCPStartupStatus(update)
            result.activities.append(activity(.notice, title: "MCP \(update.status)", detail: update.error ?? update.name))
        }

        return result
    }

    private static func applySubagentNotification(
        _ notification: CodexNotification,
        agentStateMapper: inout CodexAgentStateMapper,
        turnSnapshot: (String?, String?) -> CodexTurnSnapshot?
    ) -> CodexChatNotificationPipelineResult? {
        guard let route = CodexAgentNotificationRouter.apply(
            notification,
            to: &agentStateMapper,
            turnSnapshot: { threadID, turnID in turnSnapshot(threadID, turnID) }
        ) else {
            return nil
        }
        return CodexChatNotificationPipelineResult(
            syncAgentState: route.didUpdateAgentState,
            activities: route.activity.map { [$0] } ?? []
        )
    }

    private static func applyMainNotification(
        _ notification: CodexNotification,
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper,
        turnSnapshot: (String?, String?) -> CodexTurnSnapshot?
    ) -> CodexChatNotificationPipelineResult? {
        let turnID = CodexNotificationMetadata.turnID(from: notification)
        guard let update = mainChatSession.apply(
            notification,
            turnSnapshot: turnSnapshot(currentThreadID, turnID),
            isSubagentItem: { item in agentStateMapper.isSubagentItem(item) }
        ) else {
            return nil
        }
        return apply(
            update,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper
        )
    }

    private static func applyMainUpdateActions(
        _ actions: [CodexMainChatAction],
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper,
        result: inout CodexChatNotificationPipelineResult
    ) {
        for action in actions {
            switch action {
            case .activity(let kind, let title, let detail):
                result.activities.append(activity(kind, title: title, detail: detail))

            case .assistantMessageCompleted(let text):
                if agentStateMapper.assistantMessageCompleted(text) {
                    result.syncAgentState = true
                }

            case .subagentItemStarted(let item):
                if let update = agentStateMapper.itemStarted(item) {
                    result.syncAgentState = true
                    result.activities.append(activity(.tool, title: update.activityTitle, detail: update.activityDetail))
                }

            case .subagentItemCompleted(let item):
                if let update = agentStateMapper.itemCompleted(item) {
                    result.syncAgentState = true
                    result.activities.append(activity(.tool, title: update.activityTitle, detail: update.activityDetail))
                }

            case .goalUpdated(let goal, let turnID):
                applyGoal(goal, turnID: turnID, shouldAnnounce: true, mainChatSession: &mainChatSession, goalSession: &goalSession, result: &result)

            case .goalCleared(let threadID):
                applyGoalCleared(threadID: threadID, currentThreadID: currentThreadID, goalSession: &goalSession, result: &result)

            case .refreshRecentChats:
                result.actions.append(.refreshRecentChats)

            case .flushQueuedFollowUps:
                result.actions.append(.flushQueuedFollowUps)
            }
        }
    }

    private static func applyGoal(
        _ goal: ThreadGoal,
        turnID: String?,
        shouldAnnounce: Bool,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        result: inout CodexChatNotificationPipelineResult
    ) {
        let change = goalSession.apply(goal, turnID: turnID, shouldAnnounce: shouldAnnounce)
        if change.endedActiveTurn {
            mainChatSession.failToStart()
        }
        if let notice = change.activity {
            result.activities.append(activity(.notice, title: notice.title, detail: notice.detail))
        }
    }

    private static func applyGoalCleared(
        threadID: String?,
        currentThreadID: String?,
        goalSession: inout CodexGoalStateSession,
        result: inout CodexChatNotificationPipelineResult
    ) {
        guard let change = goalSession.clear(threadID: threadID, currentThreadID: currentThreadID),
              let notice = change.activity else {
            return
        }
        result.activities.append(activity(.notice, title: notice.title, detail: notice.detail))
    }

    private static func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexActivity {
        CodexActivity(kind: kind, title: title, detail: detail)
    }

    private static func isGlobalNoticeCardNotification(_ notification: CodexNotification) -> Bool {
        let method: CodexAppServerNotificationMethod
        let params: [String: CodexJSONValue]
        switch notification.payload {
        case .known(let knownMethod, let knownParams):
            method = knownMethod
            params = knownParams
        case .unknown(let rawMethod, let rawParams):
            guard let knownMethod = CodexAppServerNotificationMethod(rawValue: rawMethod) else { return false }
            method = knownMethod
            params = rawParams
        default:
            return false
        }

        guard method == .guardianWarning
            || method == .itemAutoApprovalReviewStarted
            || method == .itemAutoApprovalReviewCompleted else {
            return false
        }

        guard let route = CodexNotificationMetadata.knownRoute(method: method, params: params) else {
            return false
        }
        if case .notice = route {
            return true
        }
        return false
    }
}
