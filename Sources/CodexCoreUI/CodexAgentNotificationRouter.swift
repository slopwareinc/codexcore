import Foundation
import CodexCore

public struct CodexAgentNotificationRouteResult: Equatable, Sendable {
    public var didUpdateAgentState: Bool
    public var activity: CodexActivity?

    public init(didUpdateAgentState: Bool = true, activity: CodexActivity? = nil) {
        self.didUpdateAgentState = didUpdateAgentState
        self.activity = activity
    }
}

public enum CodexAgentNotificationRouter {
    public static func apply(
        _ notification: CodexNotification,
        to mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot? = { _, _ in nil }
    ) -> CodexAgentNotificationRouteResult? {
        switch notification.payload {
        case .turnStarted(let payload):
            guard let threadID = payload.threadId,
                  let update = mapper.subagentTurnStarted(threadID: threadID) else {
                return nil
            }
            return result(.turn, update)

        case .itemStarted(let payload):
            if let projected = projectedItemStarted(
                threadID: payload.threadId,
                turnID: payload.turnId,
                itemID: payload.item.id,
                itemType: payload.item.type,
                mapper: &mapper,
                turnSnapshot: turnSnapshot
            ) {
                return projected
            }
            guard let update = mapper.subagentItemStarted(threadID: payload.threadId, item: payload.item) else {
                return nil
            }
            return result(.tool, update)

        case .agentMessageDelta(let delta):
            return applyStoreFirstTextItemUpdate(
                threadID: delta.threadId,
                turnID: delta.turnId,
                itemID: delta.itemId,
                text: delta.delta,
                mapper: &mapper,
                turnSnapshot: turnSnapshot,
                rawApply: { text, threadID, itemID, mapper in
                    mapper.subagentMessageDelta(text, threadID: threadID, itemID: itemID)
                }
            )

        case .itemCompleted(let payload):
            if let projected = projectedItemCompleted(
                threadID: payload.threadId,
                turnID: payload.turnId,
                itemID: payload.item.id,
                itemType: payload.item.type,
                mapper: &mapper,
                turnSnapshot: turnSnapshot
            ) {
                return projected
            }
            guard let update = mapper.subagentItemCompleted(threadID: payload.threadId, item: payload.item) else {
                return nil
            }
            return result(.tool, update)

        case .turnPlanUpdated(let payload):
            if let projected = projectedTurnPlanUpdated(
                threadID: payload.threadId,
                turnID: payload.turnId,
                mapper: &mapper,
                turnSnapshot: turnSnapshot
            ) {
                return projected
            }
            let message = CodexChatTranscriptProjection.turnPlanMessage(for: CodexTurnSnapshot(
                id: payload.turnId,
                status: .running,
                plan: payload.plan,
                planExplanation: payload.explanation
            ))
            guard let message,
                  mapper.subagentProjectedItemUpdated(
                    threadID: payload.threadId,
                    itemID: message.planUpdate?.itemID ?? "turn-plan-\(payload.turnId)",
                    message: message
                  ) else {
                return nil
            }
            return CodexAgentNotificationRouteResult()

        case .turnCompleted(let payload):
            guard let update = mapper.subagentTurnCompleted(threadID: payload.threadId, error: payload.turn.error?.message) else {
                return nil
            }
            return result(.turn, update)

        case .threadTokenUsageUpdated(let payload):
            guard mapper.hasSubagentThread(id: payload.threadId) else { return nil }
            return CodexAgentNotificationRouteResult(didUpdateAgentState: false)

        case .known(let method, let params):
            return applyKnown(method, params: params, to: &mapper, turnSnapshot: turnSnapshot)

        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else { return nil }
            return applyKnown(known, params: params, to: &mapper, turnSnapshot: turnSnapshot)

        default:
            return nil
        }
    }

    private static func applyKnown(
        _ method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        to mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?
    ) -> CodexAgentNotificationRouteResult? {
        guard let route = CodexNotificationMetadata.knownRoute(method: method, params: params) else {
            return nil
        }
        switch route {
        case .commandOutputDelta(let update):
            return applyStoreFirstTextItemUpdate(
                update,
                mapper: &mapper,
                turnSnapshot: turnSnapshot,
                rawApply: { text, threadID, itemID, mapper in
                    mapper.subagentCommandOutputDelta(text, threadID: threadID, itemID: itemID)
                }
            )

        case .commandTerminalInteraction(let update):
            return applyStoreFirstTextItemUpdate(
                update,
                mapper: &mapper,
                turnSnapshot: turnSnapshot,
                rawApply: { text, threadID, itemID, mapper in
                    mapper.subagentCommandOutputDelta(text, threadID: threadID, itemID: itemID)
                }
            )

        case .fileChangeOutputDelta(let update):
            return applyStoreFirstTextItemUpdate(
                update,
                mapper: &mapper,
                turnSnapshot: turnSnapshot,
                rawApply: { text, threadID, itemID, mapper in
                    mapper.subagentFileChangeOutputDelta(text, threadID: threadID, itemID: itemID)
                }
            )

        case .fileChangePatchUpdated(let update):
            guard let threadID = update.threadID else { return nil }
            if let projected = projectedItemUpdated(
                threadID: threadID,
                turnID: update.turnID,
                itemID: update.itemID,
                mapper: &mapper,
                turnSnapshot: turnSnapshot
            ) {
                return projected
            }
            guard let message = CodexChatTranscriptProjection.message(
                forRawItemID: update.itemID,
                type: "fileChange",
                raw: params,
                fallbackStatus: "active"
            ),
                  mapper.subagentProjectedItemUpdated(threadID: threadID, itemID: update.itemID, message: message) else {
                return nil
            }
            return CodexAgentNotificationRouteResult()

        case .planDelta(let update):
            guard let threadID = update.item.threadID,
                  mapper.subagentPlanDelta(update.text, threadID: threadID, itemID: update.item.itemID) else {
                return nil
            }
            return CodexAgentNotificationRouteResult()

        case .turnPlanUpdated(let update):
            guard let threadID = update.threadID else { return nil }
            if let projected = projectedTurnPlanUpdated(
                threadID: threadID,
                turnID: update.turnID,
                mapper: &mapper,
                turnSnapshot: turnSnapshot
            ) {
                return projected
            }
            guard let message = CodexChatTranscriptProjection.turnPlanMessage(for: CodexTurnSnapshot(
                id: update.turnID,
                status: .running,
                plan: update.plan,
                planExplanation: update.explanation
            )),
                  let itemID = message.planUpdate?.itemID,
                  mapper.subagentProjectedItemUpdated(threadID: threadID, itemID: itemID, message: message) else {
                return nil
            }
            return CodexAgentNotificationRouteResult()

        case .mcpToolCallProgress(let update):
            return applyStoreFirstTextItemUpdate(
                update,
                mapper: &mapper,
                turnSnapshot: turnSnapshot,
                rawApply: { text, threadID, itemID, mapper in
                    mapper.subagentToolCallProgress(text, threadID: threadID, itemID: itemID)
                }
            )

        case .notice(let update):
            guard let threadID = CodexNotificationMetadata.threadID(from: params),
                  let update = mapper.subagentNotice(
                    method: update.method,
                    params: params,
                    threadID: threadID,
                    itemID: update.itemID,
                    isStreaming: update.isStreaming
                  ) else {
                return nil
            }
            return result(.notice, update)

        case .turnCompleted(let threadID, let error):
            guard let threadID,
                  let update = mapper.subagentTurnCompleted(
                    threadID: threadID,
                    error: error
                  ) else {
                return nil
            }
            return result(.turn, update)

        case .turnStarted(let threadID):
            guard let threadID,
                  let update = mapper.subagentTurnStarted(threadID: threadID) else {
                return nil
            }
            return result(.turn, update)

        default:
            return nil
        }
    }

    private static func result(_ kind: CodexActivity.Kind, _ update: CodexAgentItemUpdate) -> CodexAgentNotificationRouteResult {
        CodexAgentNotificationRouteResult(
            activity: CodexActivity(kind: kind, title: update.activityTitle, detail: update.activityDetail)
        )
    }

    private static func applyStoreFirstTextItemUpdate(
        _ update: CodexKnownItemTextNotificationRoute,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?,
        rawApply: (String, String, String, inout CodexAgentStateMapper) -> Bool
    ) -> CodexAgentNotificationRouteResult? {
        guard let threadID = update.item.threadID else { return nil }
        return applyStoreFirstTextItemUpdate(
            threadID: threadID,
            turnID: update.item.turnID,
            itemID: update.item.itemID,
            text: update.text,
            mapper: &mapper,
            turnSnapshot: turnSnapshot,
            rawApply: rawApply
        )
    }

    private static func applyStoreFirstTextItemUpdate(
        threadID: String,
        turnID: String?,
        itemID: String,
        text: String,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?,
        rawApply: (String, String, String, inout CodexAgentStateMapper) -> Bool
    ) -> CodexAgentNotificationRouteResult? {
        if let projected = projectedItemUpdated(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            mapper: &mapper,
            turnSnapshot: turnSnapshot
        ) {
            return projected
        }
        guard rawApply(text, threadID, itemID, &mapper) else { return nil }
        return CodexAgentNotificationRouteResult()
    }

    private static func projectedItemStarted(
        threadID: String,
        turnID: String?,
        itemID: String,
        itemType: String,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?
    ) -> CodexAgentNotificationRouteResult? {
        guard let snapshot = turnSnapshot(threadID, turnID),
              let message = CodexChatTranscriptProjection.message(forItemID: itemID, in: snapshot),
              isStoreBackedStartedMessage(message),
              let update = mapper.subagentProjectedItemStarted(
                threadID: threadID,
                itemID: itemID,
                message: message,
                itemType: itemType
              ) else {
            return nil
        }
        return result(.tool, update)
    }

    private static func projectedItemCompleted(
        threadID: String,
        turnID: String?,
        itemID: String,
        itemType: String,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?
    ) -> CodexAgentNotificationRouteResult? {
        guard let snapshot = turnSnapshot(threadID, turnID),
              let message = CodexChatTranscriptProjection.message(forItemID: itemID, in: snapshot),
              let update = mapper.subagentProjectedItemCompleted(
                threadID: threadID,
                itemID: itemID,
                message: message,
                itemType: itemType
              ) else {
            return nil
        }
        return result(.tool, update)
    }

    private static func projectedItemUpdated(
        threadID: String,
        turnID: String?,
        itemID: String,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?
    ) -> CodexAgentNotificationRouteResult? {
        guard let snapshot = turnSnapshot(threadID, turnID),
              let message = CodexChatTranscriptProjection.message(forItemID: itemID, in: snapshot),
              isStoreBackedLiveMessage(message),
              mapper.subagentProjectedItemUpdated(threadID: threadID, itemID: itemID, message: message) else {
            return nil
        }
        return CodexAgentNotificationRouteResult()
    }

    private static func projectedTurnPlanUpdated(
        threadID: String,
        turnID: String,
        mapper: inout CodexAgentStateMapper,
        turnSnapshot: (String, String?) -> CodexTurnSnapshot?
    ) -> CodexAgentNotificationRouteResult? {
        guard let snapshot = turnSnapshot(threadID, turnID),
              let message = CodexChatTranscriptProjection.turnPlanMessage(for: snapshot),
              let itemID = message.planUpdate?.itemID,
              mapper.subagentProjectedItemUpdated(threadID: threadID, itemID: itemID, message: message) else {
            return nil
        }
        return CodexAgentNotificationRouteResult()
    }

    private static func isStoreBackedStartedMessage(_ message: CodexChatMessage) -> Bool {
        switch message.role {
        case .terminal, .fileChange, .tool:
            return true
        case .assistant, .plan, .notice, .system, .user:
            return false
        }
    }

    private static func isStoreBackedLiveMessage(_ message: CodexChatMessage) -> Bool {
        switch message.role {
        case .assistant, .terminal, .fileChange, .tool:
            return true
        case .plan, .notice, .system, .user:
            return false
        }
    }

}
