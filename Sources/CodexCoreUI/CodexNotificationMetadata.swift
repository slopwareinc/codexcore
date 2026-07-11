import Foundation
import CodexCore

public struct CodexKnownItemNotificationRoute: Equatable, Sendable {
    public var threadID: String?
    public var turnID: String?
    public var itemID: String

    public init(threadID: String?, turnID: String?, itemID: String) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }
}

public struct CodexKnownItemTextNotificationRoute: Equatable, Sendable {
    public var item: CodexKnownItemNotificationRoute
    public var text: String

    public init(item: CodexKnownItemNotificationRoute, text: String) {
        self.item = item
        self.text = text
    }
}

public struct CodexKnownTurnPlanNotificationRoute: Equatable, Sendable {
    public var threadID: String?
    public var turnID: String
    public var plan: [TurnPlanStep]?
    public var explanation: String?

    public init(threadID: String?, turnID: String, plan: [TurnPlanStep]?, explanation: String?) {
        self.threadID = threadID
        self.turnID = turnID
        self.plan = plan
        self.explanation = explanation
    }
}

public struct CodexKnownTurnDiffNotificationRoute: Equatable, Sendable {
    public var threadID: String?
    public var turnID: String
    public var diff: String?

    public init(threadID: String?, turnID: String, diff: String?) {
        self.threadID = threadID
        self.turnID = turnID
        self.diff = diff
    }
}

public struct CodexKnownNoticeNotificationRoute: Equatable, Sendable {
    public var method: CodexAppServerNotificationMethod
    public var itemID: String
    public var isStreaming: Bool

    public init(method: CodexAppServerNotificationMethod, itemID: String, isStreaming: Bool) {
        self.method = method
        self.itemID = itemID
        self.isStreaming = isStreaming
    }
}

public enum CodexKnownNotificationRoute: Equatable, Sendable {
    case commandOutputDelta(CodexKnownItemTextNotificationRoute)
    case commandTerminalInteraction(CodexKnownItemTextNotificationRoute)
    case fileChangeOutputDelta(CodexKnownItemTextNotificationRoute)
    case fileChangePatchUpdated(CodexKnownItemNotificationRoute)
    case turnDiffUpdated(CodexKnownTurnDiffNotificationRoute)
    case planDelta(CodexKnownItemTextNotificationRoute)
    case turnPlanUpdated(CodexKnownTurnPlanNotificationRoute)
    case mcpToolCallProgress(CodexKnownItemTextNotificationRoute)
    case notice(CodexKnownNoticeNotificationRoute)
    case reasoningTextDelta(CodexKnownItemTextNotificationRoute)
    case reasoningSummaryTextDelta(CodexKnownItemTextNotificationRoute)
    case turnCompleted(threadID: String?, error: String?)
    case turnStarted(threadID: String?)
}

public enum CodexNotificationMetadata {
    public static func threadID(from notification: CodexNotification) -> String? {
        switch notification.payload {
        case .itemStarted(let payload):
            return payload.threadId
        case .itemCompleted(let payload):
            return payload.threadId
        case .agentMessageDelta(let payload):
            return payload.threadId
        case .threadTokenUsageUpdated(let payload):
            return payload.threadId
        case .threadGoalUpdated(let payload):
            return payload.threadId
        case .threadGoalCleared(let payload):
            return payload.threadId
        case .turnStarted(let payload):
            return payload.threadId
        case .turnCompleted(let payload):
            return payload.threadId
        case .turnPlanUpdated(let payload):
            return payload.threadId
        case .turnDiffUpdated(let payload):
            return payload.threadId
        case .known(_, let params), .unknown(_, let params):
            return threadID(from: params)
        case .accountLoginCompleted:
            return nil
        }
    }

    public static func turnID(from notification: CodexNotification) -> String? {
        switch notification.payload {
        case .itemStarted(let payload):
            return payload.turnId
        case .itemCompleted(let payload):
            return payload.turnId
        case .agentMessageDelta(let payload):
            return payload.turnId
        case .threadTokenUsageUpdated(let payload):
            return payload.turnId
        case .threadGoalUpdated(let payload):
            return payload.turnId
        case .turnStarted(let payload):
            return payload.turn.id
        case .turnCompleted(let payload):
            return payload.turn.id
        case .turnPlanUpdated(let payload):
            return payload.turnId
        case .turnDiffUpdated(let payload):
            return payload.turnId
        case .known(_, let params), .unknown(_, let params):
            return turnID(from: params)
        case .threadGoalCleared, .accountLoginCompleted:
            return nil
        }
    }

    public static func threadID(from params: [String: CodexJSONValue]) -> String? {
        if let direct = string(from: params["threadId"]) { return direct }
        if case .dictionary(let thread)? = params["thread"], let nested = string(from: thread["id"]) {
            return nested
        }
        return nil
    }

    public static func turnID(from params: [String: CodexJSONValue]) -> String? {
        if let direct = string(from: params["turnId"]) { return direct }
        if case .dictionary(let turn)? = params["turn"], let nested = string(from: turn["id"]) {
            return nested
        }
        return nil
    }

    public static func noticeItemID(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue]
    ) -> String {
        if let reviewID = string(from: params["reviewId"]) {
            return "review-\(reviewID)"
        }
        if let itemID = string(from: params["itemId"]) ?? string(from: params["targetItemId"]) {
            return "\(method.rawValue)-\(itemID)"
        }
        let threadPart = threadID(from: params) ?? "global"
        let turnPart = turnID(from: params) ?? UUID().uuidString
        return "\(method.rawValue)-\(threadPart)-\(turnPart)-\(UUID().uuidString)"
    }

    public static func turnErrorMessage(from params: [String: CodexJSONValue]) -> String? {
        if case .dictionary(let turn)? = params["turn"] {
            if case .dictionary(let error)? = turn["error"] {
                return string(from: error["message"]) ?? string(from: error["raw"])
            }
            if let error = string(from: turn["error"]) {
                return error
            }
        }
        if case .dictionary(let error)? = params["error"] {
            return string(from: error["message"]) ?? string(from: error["raw"])
        }
        return string(from: params["error"])
    }

    public static func knownRoute(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue]
    ) -> CodexKnownNotificationRoute? {
        switch method {
        case .itemCommandExecutionOutputDelta:
            return itemTextRoute(params: params, textKey: "delta").map(CodexKnownNotificationRoute.commandOutputDelta)
        case .itemCommandExecutionTerminalInteraction:
            guard let route = itemTextRoute(params: params, textKey: "stdin"), !route.text.isEmpty else {
                return nil
            }
            return .commandTerminalInteraction(CodexKnownItemTextNotificationRoute(
                item: route.item,
                text: "\n$ \(route.text)"
            ))
        case .itemFileChangeOutputDelta:
            return itemTextRoute(params: params, textKey: "delta").map(CodexKnownNotificationRoute.fileChangeOutputDelta)
        case .itemFileChangePatchUpdated:
            return itemRoute(params: params).map(CodexKnownNotificationRoute.fileChangePatchUpdated)
        case .turnDiffUpdated:
            guard let turnID = turnID(from: params) else { return nil }
            return .turnDiffUpdated(CodexKnownTurnDiffNotificationRoute(
                threadID: threadID(from: params),
                turnID: turnID,
                diff: string(from: params["diff"])
            ))
        case .itemPlanDelta:
            return itemTextRoute(params: params, textKey: "delta").map(CodexKnownNotificationRoute.planDelta)
        case .turnPlanUpdated:
            guard let turnID = turnID(from: params) else { return nil }
            let payload = try? params.decode(TurnPlanUpdatedNotification.self)
            return .turnPlanUpdated(CodexKnownTurnPlanNotificationRoute(
                threadID: threadID(from: params),
                turnID: turnID,
                plan: payload?.plan,
                explanation: payload?.explanation
            ))
        case .itemMCPToolCallProgress:
            return itemTextRoute(params: params, textKey: "message", verbatim: false).map(CodexKnownNotificationRoute.mcpToolCallProgress)
        case .itemReasoningTextDelta:
            return itemTextRoute(params: params, textKey: "delta").map(CodexKnownNotificationRoute.reasoningTextDelta)
        case .itemReasoningSummaryTextDelta:
            return itemTextRoute(params: params, textKey: "delta").map(CodexKnownNotificationRoute.reasoningSummaryTextDelta)
        case .modelRerouted, .modelVerification, .warning, .guardianWarning, .deprecationNotice, .configWarning, .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            return .notice(CodexKnownNoticeNotificationRoute(
                method: method,
                itemID: noticeItemID(method: method, params: params),
                isStreaming: method == .itemAutoApprovalReviewStarted
            ))
        case .turnCompleted:
            return .turnCompleted(threadID: threadID(from: params), error: turnErrorMessage(from: params))
        case .turnStarted:
            return .turnStarted(threadID: threadID(from: params))
        default:
            return nil
        }
    }

    private static func itemRoute(params: [String: CodexJSONValue]) -> CodexKnownItemNotificationRoute? {
        guard let itemID = string(from: params["itemId"]) else { return nil }
        return CodexKnownItemNotificationRoute(
            threadID: threadID(from: params),
            turnID: turnID(from: params),
            itemID: itemID
        )
    }

    private static func itemTextRoute(
        params: [String: CodexJSONValue],
        textKey: String,
        verbatim: Bool = true
    ) -> CodexKnownItemTextNotificationRoute? {
        guard let item = itemRoute(params: params) else { return nil }
        let text = verbatim ? verbatimString(from: params[textKey]) : string(from: params[textKey])
        guard let text else { return nil }
        return CodexKnownItemTextNotificationRoute(item: item, text: text)
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: return nil
        }
    }

    private static func verbatimString(from value: CodexJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
}
