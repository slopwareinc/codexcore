import Foundation
import CodexCore

public struct CodexChatTranscriptSession: Sendable, Equatable {
    private var transcript: CodexChatTranscriptState

    public private(set) var currentPlan: [TurnPlanStep]
    public private(set) var currentPlanExplanation: String?
    public private(set) var currentDiff: String?

    public var messages: [CodexChatMessage] {
        transcript.messages
    }

    public init(messages: [CodexChatMessage] = []) {
        self.transcript = CodexChatTranscriptState(messages: messages)
        self.currentPlan = []
        self.currentPlanExplanation = nil
        self.currentDiff = nil
    }

    public mutating func reset(messages: [CodexChatMessage] = []) {
        transcript.reset(messages: messages)
        currentPlan = []
        currentPlanExplanation = nil
        currentDiff = nil
    }

    public mutating func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        transcript.appendMessage(role, text, detail: detail)
    }

    public mutating func append(_ message: CodexChatMessage) {
        transcript.append(message)
    }

    public mutating func finishStreamingMessages() {
        transcript.finishStreamingMessages()
    }

    @discardableResult
    public mutating func syncTurnChrome(
        from snapshot: CodexTurnSnapshot?,
        resetWhenMissing: Bool = false
    ) -> Bool {
        guard let snapshot else {
            guard resetWhenMissing else { return false }
            currentPlan = []
            currentPlanExplanation = nil
            currentDiff = nil
            return true
        }

        currentPlan = snapshot.plan ?? []
        currentPlanExplanation = snapshot.planExplanation
        currentDiff = nonBlank(snapshot.diff)
        return true
    }

    @discardableResult
    public mutating func apply(
        _ notification: CodexNotification,
        activeTurnID: String? = nil,
        turnSnapshot: CodexTurnSnapshot? = nil,
        activityPrefix: String = "",
        includesTurnDiff: Bool = true
    ) -> CodexChatTranscriptRouteResult? {
        let result = CodexChatTranscriptNotificationRouter.apply(
            notification,
            to: &transcript,
            context: CodexChatTranscriptRouteContext(
                activityPrefix: activityPrefix,
                activeTurnID: activeTurnID,
                includesTurnDiff: includesTurnDiff,
                turnSnapshot: turnSnapshot
            )
        )

        if result != nil, isTurnChromeNotification(notification) {
            syncTurnChrome(from: turnSnapshot)
        }

        return result
    }

    private func isTurnChromeNotification(_ notification: CodexNotification) -> Bool {
        switch notification.payload {
        case .turnPlanUpdated, .turnDiffUpdated:
            return true
        case .known(let method, _):
            return method == .turnPlanUpdated || method == .turnDiffUpdated
        case .unknown(let method, _):
            return method == CodexAppServerNotificationMethod.turnPlanUpdated.rawValue
                || method == CodexAppServerNotificationMethod.turnDiffUpdated.rawValue
        default:
            return false
        }
    }

    private func nonBlank(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return string
    }
}
