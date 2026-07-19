import Foundation

/// UI-local optimistic lifecycle state.
///
/// Durable turn truth is owned by `CodexSession`; this value only bridges the
/// interval between submitting a command and receiving the canonical update.
public struct CodexTurnLifecycleSession: Sendable {
    public private(set) var isSending: Bool
    public private(set) var activeTurnID: String?

    public var canSteer: Bool {
        isSending && activeTurnID != nil
    }

    public init() {
        self.isSending = false
        self.activeTurnID = nil
    }

    public mutating func startPending() {
        isSending = true
    }

    public mutating func start(turnID: String) {
        isSending = true
        activeTurnID = turnID
    }

    public mutating func failToStart() {
        isSending = false
        activeTurnID = nil
    }

    public mutating func reset() {
        isSending = false
        activeTurnID = nil
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

}
