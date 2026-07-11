import CodexCore

public struct CodexAgentNotificationRouteResult: Equatable, Sendable {
    public var didUpdateAgentState: Bool
    public var activity: CodexActivity?
    public init(didUpdateAgentState: Bool = true, activity: CodexActivity? = nil) {
        self.didUpdateAgentState = didUpdateAgentState; self.activity = activity
    }
}

public enum CodexAgentNotificationRouter {
    public static func apply(
        _ notification: CodexNotification,
        to mapper: inout CodexAgentStateMapper,
        turnSnapshot _: (String, String?) -> CodexTurnSnapshot? = { _, _ in nil }
    ) -> CodexAgentNotificationRouteResult? {
        switch notification.payload {
        case .itemStarted(let payload):
            guard let update = mapper.subagentItemStarted(threadID: payload.threadId, item: payload.item) else { return nil }
            return .init(activity: .init(kind: .tool, title: update.activityTitle, detail: update.activityDetail))
        case .itemCompleted(let payload):
            guard let update = mapper.subagentItemCompleted(threadID: payload.threadId, item: payload.item) else { return nil }
            return .init(activity: .init(kind: .tool, title: update.activityTitle, detail: update.activityDetail))
        default: return nil
        }
    }
}
