import Foundation
import CodexCore

public struct CodexGlobalNotificationRouteContext: Equatable, Sendable {
    public var currentThreadID: String?
    public var hasActiveGoal: Bool
    public var activeGoalTurnID: String?

    public init(
        currentThreadID: String? = nil,
        hasActiveGoal: Bool = false,
        activeGoalTurnID: String? = nil
    ) {
        self.currentThreadID = currentThreadID
        self.hasActiveGoal = hasActiveGoal
        self.activeGoalTurnID = activeGoalTurnID
    }
}

public struct CodexGlobalNotificationRouteResult: Equatable, Sendable {
    public var action: CodexGlobalNotificationAction?

    public init(action: CodexGlobalNotificationAction? = nil) {
        self.action = action
    }
}

public enum CodexGlobalNotificationAction: Equatable, Sendable {
    case threadStartedMetadata(CodexThreadStartedMetadata)
    case threadListChanged
    case skillsChanged
    case threadCompacted(threadID: String?)
    case goalUpdated(goal: ThreadGoal, turnID: String?)
    case goalCleared(threadID: String?)
    case goalTurnStarted(turnID: String)
    case mcpServerStartupStatus(CodexMCPServerStartupStatus)
}

public struct CodexThreadStartedMetadata: Equatable, Sendable {
    public var threadID: String
    public var parentThreadID: String
    public var name: String?
    public var role: String?

    public init(threadID: String, parentThreadID: String, name: String? = nil, role: String? = nil) {
        self.threadID = threadID
        self.parentThreadID = parentThreadID
        self.name = name
        self.role = role
    }
}

public struct CodexMCPServerStartupStatus: Equatable, Sendable {
    public var name: String
    public var status: String
    public var error: String?

    public init(name: String, status: String, error: String? = nil) {
        self.name = name
        self.status = status
        self.error = error
    }
}

public enum CodexGlobalNotificationRouter {
    public static func apply(
        _ notification: CodexNotification,
        context: CodexGlobalNotificationRouteContext = CodexGlobalNotificationRouteContext()
    ) -> CodexGlobalNotificationRouteResult? {
        switch notification.payload {
        case .threadGoalUpdated(let payload):
            return handled(.goalUpdated(goal: payload.goal, turnID: payload.turnId))
        case .threadGoalCleared(let payload):
            return handled(.goalCleared(threadID: payload.threadId))
        case .turnStarted(let payload):
            guard shouldTrackGoalTurn(threadID: payload.threadId, turnID: payload.turn.id, context: context) else {
                return nil
            }
            return handled(.goalTurnStarted(turnID: payload.turn.id))
        case .known(let method, let params):
            return applyKnown(method, params: params, context: context)
        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else { return nil }
            return applyKnown(known, params: params, context: context)
        default:
            return nil
        }
    }

    private static func applyKnown(
        _ method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        context: CodexGlobalNotificationRouteContext
    ) -> CodexGlobalNotificationRouteResult? {
        switch method {
        case .threadStarted:
            return handled(threadStartedMetadata(from: params).map(CodexGlobalNotificationAction.threadStartedMetadata))
        case .threadArchived, .threadDeleted, .threadNameUpdated:
            return handled(.threadListChanged)
        case .skillsChanged:
            return handled(.skillsChanged)
        case .threadCompacted:
            return handled(.threadCompacted(threadID: CodexNotificationMetadata.threadID(from: params)))
        case .threadGoalUpdated:
            guard let payload = try? params.decode(ThreadGoalUpdatedNotification.self) else {
                return handled()
            }
            return handled(.goalUpdated(goal: payload.goal, turnID: payload.turnId))
        case .threadGoalCleared:
            return handled(.goalCleared(threadID: CodexNotificationMetadata.threadID(from: params)))
        case .turnStarted:
            guard let turnID = CodexNotificationMetadata.turnID(from: params),
                  shouldTrackGoalTurn(
                    threadID: CodexNotificationMetadata.threadID(from: params),
                    turnID: turnID,
                    context: context
                  ) else {
                return handled()
            }
            return handled(.goalTurnStarted(turnID: turnID))
        case .mcpServerStartupStatusUpdated:
            return handled(mcpServerStartupStatus(from: params).map(CodexGlobalNotificationAction.mcpServerStartupStatus))
        default:
            return nil
        }
    }

    private static func handled(_ action: CodexGlobalNotificationAction? = nil) -> CodexGlobalNotificationRouteResult {
        CodexGlobalNotificationRouteResult(action: action)
    }

    private static func shouldTrackGoalTurn(
        threadID: String?,
        turnID: String,
        context: CodexGlobalNotificationRouteContext
    ) -> Bool {
        guard context.hasActiveGoal, context.activeGoalTurnID == nil else { return false }
        guard let threadID else { return false }
        return threadID == context.currentThreadID
    }

    private static func threadStartedMetadata(from params: [String: CodexJSONValue]) -> CodexThreadStartedMetadata? {
        guard case .dictionary(let thread)? = params["thread"],
              let parentThreadID = string(from: thread["parentThreadId"]),
              let threadID = string(from: thread["id"]) else {
            return nil
        }

        let name = string(from: thread["agentNickname"]) ?? string(from: thread["name"])
        let role = string(from: thread["agentRole"])
        return CodexThreadStartedMetadata(threadID: threadID, parentThreadID: parentThreadID, name: name, role: role)
    }

    private static func mcpServerStartupStatus(from params: [String: CodexJSONValue]) -> CodexMCPServerStartupStatus? {
        guard let name = string(from: params["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let status = string(from: params["status"]) else {
            return nil
        }
        return CodexMCPServerStartupStatus(name: name, status: status, error: string(from: params["error"]))
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
}
