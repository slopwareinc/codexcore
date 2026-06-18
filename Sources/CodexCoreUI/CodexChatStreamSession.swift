import Foundation
import CodexCore

@MainActor
public final class CodexChatStreamSession {
    private var mainTurnTask: Task<Void, Never>?
    private var sideChatTurnTask: Task<Void, Never>?
    private var globalNotificationTask: Task<Void, Never>?

    public init() {}

    public func consumeMainTurnStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        onNotification: @escaping @MainActor (CodexNotification) -> Void,
        onFinish: @escaping @MainActor (String) -> Void
    ) {
        mainTurnTask?.cancel()
        mainTurnTask = Task { @MainActor in
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                onNotification(notification)
            }
            guard !Task.isCancelled else { return }
            onFinish(turnID)
        }
    }

    public func consumeMainTurnResultStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        routeNotification: @escaping @MainActor (CodexNotification) -> CodexChatNotificationPipelineResult?,
        finishTurn: @escaping @MainActor (String) -> CodexChatNotificationPipelineResult?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        consumeMainTurnStream(
            id: turnID,
            notifications: notifications,
            onNotification: { notification in
                guard let result = routeNotification(notification) else { return }
                applyResult(result)
            },
            onFinish: { turnID in
                guard let result = finishTurn(turnID) else { return }
                applyResult(result)
            }
        )
    }

    public func consumeSideChatTurnStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        onNotification: @escaping @MainActor (CodexNotification) -> Void,
        onFinish: @escaping @MainActor (String) -> Void
    ) {
        sideChatTurnTask?.cancel()
        sideChatTurnTask = Task { @MainActor in
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                onNotification(notification)
            }
            guard !Task.isCancelled else { return }
            onFinish(turnID)
        }
    }

    public func consumeSideChatTurnUpdateStream(
        id turnID: String,
        notifications: AsyncStream<CodexNotification>,
        routeNotification: @escaping @MainActor (CodexNotification) -> CodexSideChatSessionUpdate?,
        finishTurn: @escaping @MainActor (String) -> CodexSideChatSessionUpdate?,
        applyUpdate: @escaping @MainActor (CodexSideChatSessionUpdate) -> Void
    ) {
        consumeSideChatTurnStream(
            id: turnID,
            notifications: notifications,
            onNotification: { notification in
                guard let update = routeNotification(notification) else { return }
                applyUpdate(update)
            },
            onFinish: { turnID in
                guard let update = finishTurn(turnID) else { return }
                applyUpdate(update)
            }
        )
    }

    public func consumeGlobalNotificationStream(
        _ notifications: AsyncStream<CodexNotification>,
        onNotification: @escaping @MainActor (CodexNotification) -> Void
    ) {
        globalNotificationTask?.cancel()
        globalNotificationTask = Task { @MainActor in
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                onNotification(notification)
            }
        }
    }

    public func consumeGlobalNotificationResultStream(
        _ notifications: AsyncStream<CodexNotification>,
        routeNotification: @escaping @MainActor (CodexNotification) -> CodexChatNotificationPipelineResult?,
        applyResult: @escaping @MainActor (CodexChatNotificationPipelineResult) -> Void
    ) {
        consumeGlobalNotificationStream(notifications) { notification in
            guard let result = routeNotification(notification) else { return }
            applyResult(result)
        }
    }

    public func cancelTurnStreams() {
        mainTurnTask?.cancel()
        sideChatTurnTask?.cancel()
        mainTurnTask = nil
        sideChatTurnTask = nil
    }

    public func cancelGlobalNotifications() {
        globalNotificationTask?.cancel()
        globalNotificationTask = nil
    }

    public func reset() {
        cancelTurnStreams()
        cancelGlobalNotifications()
    }
}
