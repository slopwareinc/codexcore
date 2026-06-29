import Foundation
import CodexCore

public struct CodexMainChatUpdate: Equatable, Sendable {
    public var actions: [CodexMainChatAction]

    public init(actions: [CodexMainChatAction] = []) {
        self.actions = actions
    }
}

public enum CodexMainChatAction: Equatable, Sendable {
    case activity(kind: CodexActivity.Kind, title: String, detail: String)
    case assistantMessageCompleted(String)
    case subagentItemStarted(ThreadItem)
    case subagentItemCompleted(ThreadItem)
    case goalUpdated(goal: ThreadGoal, turnID: String?)
    case goalCleared(threadID: String?)
    case refreshRecentChats
    case flushQueuedFollowUps
}

public struct CodexAgentMessageDeltaRoute: Equatable, Sendable {
    public var itemID: String
    public var delta: String

    public init(itemID: String, delta: String) {
        self.itemID = itemID
        self.delta = delta
    }
}

public struct CodexMainChatSession: Sendable {
    private var transcriptSession: CodexChatTranscriptSession
    private var turnLifecycle: CodexTurnLifecycleSession

    public var messages: [CodexChatMessage] {
        transcriptSession.messages
    }

    public var currentPlan: [TurnPlanStep] {
        transcriptSession.currentPlan
    }

    public var currentPlanExplanation: String? {
        transcriptSession.currentPlanExplanation
    }

    public var currentDiff: String? {
        transcriptSession.currentDiff
    }

    public var isSending: Bool {
        turnLifecycle.isSending
    }

    public var activeTurnID: String? {
        turnLifecycle.activeTurnID
    }

    public var activeTurn: CodexTurnHandle? {
        turnLifecycle.activeTurn
    }

    public init(
        transcriptSession: CodexChatTranscriptSession = CodexChatTranscriptSession(),
        turnLifecycle: CodexTurnLifecycleSession = CodexTurnLifecycleSession()
    ) {
        self.transcriptSession = transcriptSession
        self.turnLifecycle = turnLifecycle
    }

    public mutating func reset(messages: [CodexChatMessage] = []) {
        transcriptSession.reset(messages: messages)
        turnLifecycle.reset()
    }

    public mutating func resetTranscript(messages: [CodexChatMessage] = []) {
        transcriptSession.reset(messages: messages)
    }

    public mutating func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        transcriptSession.appendMessage(role, text, detail: detail)
    }

    public mutating func append(_ message: CodexChatMessage) {
        transcriptSession.append(message)
    }

    public mutating func beginTurnSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        startPending()
        appendMessage(.user, submission.prompt, detail: submission.skillDetail)
        return CodexActivity(
            kind: .turn,
            title: "You asked Codex",
            detail: submission.skillDetail.map { "\($0) · \(submission.prompt)" } ?? submission.prompt
        )
    }

    public mutating func failTurnSubmission(message: String) -> CodexActivity {
        failToStart()
        return CodexActivity(kind: .turn, title: "Turn failed to start", detail: message)
    }

    public mutating func beginQueuedFollowUp(_ prompt: String) -> CodexActivity {
        startPending()
        return CodexActivity(kind: .turn, title: "Sending queued follow-up", detail: prompt)
    }

    public mutating func failQueuedFollowUp(message: String) -> CodexActivity {
        failToStart()
        return CodexActivity(kind: .turn, title: "Queued follow-up failed to start", detail: message)
    }

    public mutating func beginGoalSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        startPending()
        appendMessage(.user, submission.prompt, detail: submission.goalDetail)
        return CodexActivity(kind: .turn, title: "Pursuing goal", detail: submission.prompt)
    }

    public mutating func failGoalSubmission(message: String) -> CodexActivity {
        failToStart()
        return CodexActivity(kind: .turn, title: "Goal failed to start", detail: message)
    }

    public mutating func appendQueuedFollowUp(_ prompt: String) -> CodexActivity {
        appendMessage(.user, prompt, detail: "Queued")
        return CodexActivity(kind: .turn, title: "Follow-up queued", detail: prompt)
    }

    public mutating func appendSteeredFollowUp(_ prompt: String) -> CodexActivity {
        appendMessage(.user, prompt, detail: "Steered")
        return CodexActivity(kind: .turn, title: "Steering turn", detail: prompt)
    }

    public mutating func startPending() {
        turnLifecycle.startPending()
    }

    public mutating func start(turnID: String) {
        turnLifecycle.start(turnID: turnID)
    }

    public mutating func start(_ handle: CodexTurnHandle) {
        turnLifecycle.start(handle)
    }

    public mutating func failToStart() {
        turnLifecycle.failToStart()
    }

    public func isCompletion(_ notification: CodexNotification) -> Bool {
        turnLifecycle.isCompletion(notification)
    }

    public static func agentMessageDelta(from notification: CodexNotification) -> CodexAgentMessageDeltaRoute? {
        guard case .agentMessageDelta(let delta) = notification.payload else { return nil }
        return CodexAgentMessageDeltaRoute(itemID: delta.itemId, delta: delta.delta)
    }

    public mutating func apply(
        _ notification: CodexNotification,
        turnSnapshot: CodexTurnSnapshot?,
        isSubagentItem: (ThreadItem) -> Bool
    ) -> CodexMainChatUpdate? {
        if let transcriptResult = transcriptSession.apply(
            notification,
            activeTurnID: turnLifecycle.activeTurnID,
            turnSnapshot: turnSnapshot
        ) {
            return update(from: transcriptResult)
        }

        switch notification.payload {
        case .itemStarted(let payload):
            if isSubagentItem(payload.item) {
                return CodexMainChatUpdate(actions: [.subagentItemStarted(payload.item)])
            }
            return activity(.tool, title: "Working", detail: CodexNotificationPresentation.itemTypeTitle(payload.item.type))

        case .itemCompleted(let payload):
            if isSubagentItem(payload.item) {
                return CodexMainChatUpdate(actions: [.subagentItemCompleted(payload.item)])
            }
            return activity(.tool, title: CodexNotificationPresentation.itemTypeTitle(payload.item.type), detail: "Completed")

        case .threadTokenUsageUpdated(let payload):
            return activity(.token, title: "Token usage updated", detail: CodexNotificationPresentation.tokenUsageSummary(payload.tokenUsage))

        case .turnStarted:
            transcriptSession.syncTurnChrome(from: turnSnapshot, resetWhenMissing: true)
            return activity(.turn, title: "Codex is working", detail: "Turn started")

        case .turnCompleted(let payload):
            transcriptSession.syncTurnChrome(from: turnSnapshot)
            return finishActiveTurn(id: payload.turn.id)

        case .threadGoalUpdated(let payload):
            return CodexMainChatUpdate(actions: [.goalUpdated(goal: payload.goal, turnID: payload.turnId)])

        case .threadGoalCleared(let payload):
            return CodexMainChatUpdate(actions: [.goalCleared(threadID: payload.threadId)])

        case .accountLoginCompleted:
            return activity(.login, title: "Login completed", detail: "Authentication updated")

        case .known(let method, let params):
            if method == .turnCompleted {
                let turnID = CodexNotificationMetadata.turnID(from: params)
                transcriptSession.syncTurnChrome(from: turnSnapshot)
                return finishActiveTurn(id: turnID)
            }
            return activity(.notice, title: CodexNotificationPresentation.methodTitle(method.rawValue), detail: "App-server notification")

        case .unknown(let method, _):
            return activity(.notice, title: CodexNotificationPresentation.methodTitle(method), detail: "Notification")

        default:
            return nil
        }
    }

    @discardableResult
    public mutating func finishActiveTurn(id turnID: String?) -> CodexMainChatUpdate? {
        guard turnLifecycle.complete(turnID: turnID) else { return nil }
        transcriptSession.finishStreamingMessages()
        return CodexMainChatUpdate(actions: [
            .activity(kind: .turn, title: "Turn complete", detail: "Codex finished"),
            .refreshRecentChats,
            .flushQueuedFollowUps
        ])
    }

    private func update(from result: CodexChatTranscriptRouteResult) -> CodexMainChatUpdate {
        var actions: [CodexMainChatAction] = []
        if let text = result.completedAssistantText {
            actions.append(.assistantMessageCompleted(text))
        }
        if let activity = result.activity {
            actions.append(.activity(kind: activity.kind, title: activity.title, detail: activity.detail))
        }
        return CodexMainChatUpdate(actions: actions)
    }

    private func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexMainChatUpdate {
        CodexMainChatUpdate(actions: [.activity(kind: kind, title: title, detail: detail)])
    }

}
