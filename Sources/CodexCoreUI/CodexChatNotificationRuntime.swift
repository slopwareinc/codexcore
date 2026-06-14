import Foundation
import CodexCore

@MainActor
public enum CodexChatNotificationRuntime {
    @discardableResult
    public static func apply(
        _ notification: CodexNotification,
        mode: CodexChatNotificationPipelineMode,
        currentThreadID: String?,
        store: CodexCoreStore?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper,
        integrationCatalogSession: inout CodexIntegrationCatalogSession
    ) -> CodexChatNotificationPipelineResult? {
        CodexChatNotificationPipeline.apply(
            notification,
            mode: mode,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper,
            integrationCatalogSession: &integrationCatalogSession,
            turnSnapshot: { threadID, turnID in
                storeTurnSnapshot(
                    store: store,
                    currentThreadID: currentThreadID,
                    threadID: threadID,
                    turnID: turnID
                )
            }
        )
    }

    public static func applySideChat(
        _ notification: CodexNotification,
        store: CodexCoreStore?,
        currentThreadID: String?,
        sideChatSession: inout CodexSideChatSession
    ) -> CodexSideChatSessionUpdate? {
        sideChatSession.apply(
            notification,
            turnSnapshot: storeTurnSnapshot(
                store: store,
                currentThreadID: currentThreadID,
                threadID: CodexNotificationMetadata.threadID(from: notification),
                turnID: CodexNotificationMetadata.turnID(from: notification)
            )
        )
    }

    public static func finishMainTurn(
        id turnID: String?,
        currentThreadID: String?,
        mainChatSession: inout CodexMainChatSession,
        goalSession: inout CodexGoalStateSession,
        agentStateMapper: inout CodexAgentStateMapper
    ) -> CodexChatNotificationPipelineResult? {
        guard let update = mainChatSession.finishActiveTurn(id: turnID) else { return nil }
        return CodexChatNotificationPipeline.apply(
            update,
            currentThreadID: currentThreadID,
            mainChatSession: &mainChatSession,
            goalSession: &goalSession,
            agentStateMapper: &agentStateMapper
        )
    }

    public static func finishSideChatTurn(
        id turnID: String?,
        sideChatSession: inout CodexSideChatSession
    ) -> CodexSideChatSessionUpdate? {
        sideChatSession.finishTurn(id: turnID)
    }

    private static func storeTurnSnapshot(
        store: CodexCoreStore?,
        currentThreadID: String?,
        threadID: String?,
        turnID: String?
    ) -> CodexTurnSnapshot? {
        guard let store else { return nil }
        let threadID = threadID ?? currentThreadID
        guard let threadID else { return nil }
        return store.turnSnapshot(threadID: threadID, turnID: turnID)
    }
}
