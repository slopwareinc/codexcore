import Foundation

public struct CodexNotification: Sendable, Equatable {
    public let method: String
    public let payload: CodexNotificationPayload
    public let rawParams: [String: CodexJSONValue]

    public var knownMethod: CodexAppServerNotificationMethod? {
        CodexAppServerNotificationMethod(rawValue: method)
    }

    public var schemaDefinition: CodexAppServerMethodSchemaDefinition? {
        knownMethod?.schemaDefinition
    }

    public var schemaValue: CodexAppServerSchemaValue {
        CodexAppServerSchemaValue(.dictionary(rawParams))
    }
}

public enum CodexNotificationPayload: Sendable, Equatable {
    case itemStarted(ItemStartedNotification)
    case itemCompleted(ItemCompletedNotification)
    case agentMessageDelta(AgentMessageDeltaNotification)
    case threadTokenUsageUpdated(ThreadTokenUsageUpdatedNotification)
    case turnStarted(TurnStartedNotification)
    case turnCompleted(TurnCompletedNotification)
    case accountLoginCompleted(AccountLoginCompletedNotification)
    case known(method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue])
    case unknown(method: String, params: [String: CodexJSONValue])

    public var knownMethod: CodexAppServerNotificationMethod? {
        switch self {
        case .itemStarted:
            return .itemStarted
        case .itemCompleted:
            return .itemCompleted
        case .agentMessageDelta:
            return .itemAgentMessageDelta
        case .threadTokenUsageUpdated:
            return .threadTokenUsageUpdated
        case .turnStarted:
            return .turnStarted
        case .turnCompleted:
            return .turnCompleted
        case .accountLoginCompleted:
            return .accountLoginCompleted
        case .known(let method, _):
            return method
        case .unknown:
            return nil
        }
    }
}

public actor CodexNotificationRouter {
    private var globalContinuations: [UUID: AsyncStream<CodexNotification>.Continuation] = [:]

    private var registeredTurns: Set<String> = []
    private var turnContinuations: [String: [UUID: AsyncStream<CodexNotification>.Continuation]] = [:]
    private var pendingTurnNotifications: [String: [CodexNotification]] = [:]

    private var registeredLogins: Set<String> = []
    private var loginContinuations: [String: [UUID: AsyncStream<CodexNotification>.Continuation]] = [:]
    private var pendingLoginNotifications: [String: [CodexNotification]] = [:]

    public init() {}

    public nonisolated func globalNotifications() -> AsyncStream<CodexNotification> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addGlobalContinuation(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeGlobalContinuation(id: id) }
            }
        }
    }

    public nonisolated func turnNotifications(turnId: String) -> AsyncStream<CodexNotification> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addTurnContinuation(id: id, turnId: turnId, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeTurnContinuation(id: id, turnId: turnId) }
            }
        }
    }

    public nonisolated func loginNotifications(loginId: String) -> AsyncStream<CodexNotification> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addLoginContinuation(id: id, loginId: loginId, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeLoginContinuation(id: id, loginId: loginId) }
            }
        }
    }

    public func registerTurn(_ turnId: String) {
        registeredTurns.insert(turnId)
    }

    public func unregisterTurn(_ turnId: String) {
        registeredTurns.remove(turnId)
        pendingTurnNotifications.removeValue(forKey: turnId)
        if let continuations = turnContinuations.removeValue(forKey: turnId) {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
    }

    public func registerLogin(_ loginId: String) {
        registeredLogins.insert(loginId)
    }

    public func unregisterLogin(_ loginId: String) {
        registeredLogins.remove(loginId)
        pendingLoginNotifications.removeValue(forKey: loginId)
        if let continuations = loginContinuations.removeValue(forKey: loginId) {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
    }

    public func route(_ notification: JSONRPCNotification) {
        let params = notification.params ?? [:]
        let routed = CodexNotification(
            method: notification.method,
            payload: Self.payload(method: notification.method, params: params),
            rawParams: params
        )

        for continuation in globalContinuations.values {
            continuation.yield(routed)
        }

        if let loginId = Self.loginId(from: routed) {
            routeLogin(routed, loginId: loginId)
            return
        }

        if let turnId = Self.turnId(from: routed) {
            routeTurn(routed, turnId: turnId)
            return
        }

    }

    private func addGlobalContinuation(id: UUID, continuation: AsyncStream<CodexNotification>.Continuation) {
        globalContinuations[id] = continuation
    }

    private func removeGlobalContinuation(id: UUID) {
        globalContinuations.removeValue(forKey: id)
    }

    private func addTurnContinuation(id: UUID, turnId: String, continuation: AsyncStream<CodexNotification>.Continuation) {
        registeredTurns.insert(turnId)
        turnContinuations[turnId, default: [:]][id] = continuation
        let pending = pendingTurnNotifications.removeValue(forKey: turnId) ?? []
        for notification in pending {
            continuation.yield(notification)
            if notification.method == CodexAppServerNotificationMethod.turnCompleted.rawValue {
                continuation.finish()
                break
            }
        }
    }

    private func removeTurnContinuation(id: UUID, turnId: String) {
        turnContinuations[turnId]?.removeValue(forKey: id)
        if turnContinuations[turnId]?.isEmpty == true {
            turnContinuations.removeValue(forKey: turnId)
        }
    }

    private func addLoginContinuation(id: UUID, loginId: String, continuation: AsyncStream<CodexNotification>.Continuation) {
        registeredLogins.insert(loginId)
        loginContinuations[loginId, default: [:]][id] = continuation
        let pending = pendingLoginNotifications.removeValue(forKey: loginId) ?? []
        for notification in pending {
            continuation.yield(notification)
            if notification.method == CodexAppServerNotificationMethod.accountLoginCompleted.rawValue {
                continuation.finish()
                break
            }
        }
    }

    private func removeLoginContinuation(id: UUID, loginId: String) {
        loginContinuations[loginId]?.removeValue(forKey: id)
        if loginContinuations[loginId]?.isEmpty == true {
            loginContinuations.removeValue(forKey: loginId)
        }
    }

    private func routeTurn(_ notification: CodexNotification, turnId: String) {
        if let continuations = turnContinuations[turnId], !continuations.isEmpty {
            for continuation in continuations.values {
                continuation.yield(notification)
                if notification.method == CodexAppServerNotificationMethod.turnCompleted.rawValue {
                    continuation.finish()
                }
            }
        } else if registeredTurns.contains(turnId) {
            pendingTurnNotifications[turnId, default: []].append(notification)
        } else if notification.method != CodexAppServerNotificationMethod.turnCompleted.rawValue {
            pendingTurnNotifications[turnId, default: []].append(notification)
        }

        if notification.method == CodexAppServerNotificationMethod.turnCompleted.rawValue {
            registeredTurns.remove(turnId)
            turnContinuations.removeValue(forKey: turnId)
        }
    }

    private func routeLogin(_ notification: CodexNotification, loginId: String) {
        if let continuations = loginContinuations[loginId], !continuations.isEmpty {
            for continuation in continuations.values {
                continuation.yield(notification)
                if notification.method == CodexAppServerNotificationMethod.accountLoginCompleted.rawValue {
                    continuation.finish()
                }
            }
        } else if registeredLogins.contains(loginId) {
            pendingLoginNotifications[loginId, default: []].append(notification)
        } else if notification.method != CodexAppServerNotificationMethod.accountLoginCompleted.rawValue {
            pendingLoginNotifications[loginId, default: []].append(notification)
        }

        if notification.method == CodexAppServerNotificationMethod.accountLoginCompleted.rawValue {
            registeredLogins.remove(loginId)
            loginContinuations.removeValue(forKey: loginId)
        }
    }

    private static func payload(method: String, params: [String: CodexJSONValue]) -> CodexNotificationPayload {
        let knownMethod = CodexAppServerNotificationMethod(rawValue: method)

        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? params.decode(type)
        }

        func knownFallback() -> CodexNotificationPayload {
            if let knownMethod {
                return .known(method: knownMethod, params: params)
            }
            return .unknown(method: method, params: params)
        }

        switch method {
        case CodexAppServerNotificationMethod.itemStarted.rawValue:
            return decode(ItemStartedNotification.self).map(CodexNotificationPayload.itemStarted) ?? knownFallback()
        case CodexAppServerNotificationMethod.itemCompleted.rawValue:
            return decode(ItemCompletedNotification.self).map(CodexNotificationPayload.itemCompleted) ?? knownFallback()
        case CodexAppServerNotificationMethod.itemAgentMessageDelta.rawValue:
            return decode(AgentMessageDeltaNotification.self).map(CodexNotificationPayload.agentMessageDelta) ?? knownFallback()
        case CodexAppServerNotificationMethod.threadTokenUsageUpdated.rawValue:
            return decode(ThreadTokenUsageUpdatedNotification.self).map(CodexNotificationPayload.threadTokenUsageUpdated) ?? knownFallback()
        case CodexAppServerNotificationMethod.turnStarted.rawValue:
            return decode(TurnStartedNotification.self).map(CodexNotificationPayload.turnStarted) ?? knownFallback()
        case CodexAppServerNotificationMethod.turnCompleted.rawValue:
            return decode(TurnCompletedNotification.self).map(CodexNotificationPayload.turnCompleted) ?? knownFallback()
        case CodexAppServerNotificationMethod.accountLoginCompleted.rawValue:
            return decode(AccountLoginCompletedNotification.self).map(CodexNotificationPayload.accountLoginCompleted) ?? knownFallback()
        default:
            return knownFallback()
        }
    }

    private static func loginId(from notification: CodexNotification) -> String? {
        if case .accountLoginCompleted(let payload) = notification.payload {
            return payload.loginId
        }
        if case .string(let loginId)? = notification.rawParams["loginId"] {
            return loginId
        }
        return nil
    }

    private static func turnId(from notification: CodexNotification) -> String? {
        switch notification.payload {
        case .itemStarted(let payload): return payload.turnId
        case .itemCompleted(let payload): return payload.turnId
        case .agentMessageDelta(let payload): return payload.turnId
        case .threadTokenUsageUpdated(let payload): return payload.turnId
        case .turnStarted(let payload): return payload.turn.id
        case .turnCompleted(let payload): return payload.turn.id
        default: break
        }

        if case .string(let turnId)? = notification.rawParams["turnId"] {
            return turnId
        }
        if case .dictionary(let turn)? = notification.rawParams["turn"], case .string(let turnId)? = turn["id"] {
            return turnId
        }
        return nil
    }
}
