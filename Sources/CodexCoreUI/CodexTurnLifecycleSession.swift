import Foundation
import CodexCore

public struct CodexTurnLifecycleSession: Sendable {
    public private(set) var isSending: Bool
    public private(set) var activeTurnID: String?

    private var activeTurnHandle: CodexTurnHandle?

    public var activeTurn: CodexTurnHandle? {
        activeTurnHandle
    }

    public var canSteer: Bool {
        isSending && activeTurnHandle != nil
    }

    public init() {
        self.isSending = false
        self.activeTurnID = nil
        self.activeTurnHandle = nil
    }

    public mutating func startPending() {
        isSending = true
    }

    public mutating func start(turnID: String) {
        isSending = true
        activeTurnID = turnID
        activeTurnHandle = nil
    }

    public mutating func start(_ handle: CodexTurnHandle) {
        isSending = true
        activeTurnID = handle.id
        activeTurnHandle = handle
    }

    public mutating func failToStart() {
        isSending = false
        activeTurnID = nil
        activeTurnHandle = nil
    }

    public mutating func reset() {
        isSending = false
        activeTurnID = nil
        activeTurnHandle = nil
    }

    @discardableResult
    public mutating func complete(turnID: String?) -> Bool {
        if let activeTurnID {
            guard turnID == nil || activeTurnID == turnID else { return false }
        } else if turnID != nil {
            return false
        }

        guard isSending || activeTurnID != nil else { return false }
        reset()
        return true
    }

    public func isCompletion(_ notification: CodexNotification) -> Bool {
        guard isTurnCompletion(notification),
              let activeTurnID,
              CodexNotificationMetadata.turnID(from: notification) == activeTurnID else {
            return false
        }
        return true
    }

    private func isTurnCompletion(_ notification: CodexNotification) -> Bool {
        switch notification.payload {
        case .turnCompleted:
            return true
        default:
            return notification.payload.normalizedKnownPayload?.method == .turnCompleted
        }
    }
}
