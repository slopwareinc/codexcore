import Foundation

public struct CodexMainChatUpdate: Equatable, Sendable {
    public var actions: [CodexMainChatAction]

    public init(actions: [CodexMainChatAction] = []) {
        self.actions = actions
    }
}

public enum CodexMainChatAction: Equatable, Sendable {
    case activity(kind: CodexActivity.Kind, title: String, detail: String)
    case refreshRecentChats
    case flushQueuedFollowUps
}

/// UI-local optimistic state for composer submission. Protocol-derived plan,
/// diff, activity and completion state come from the canonical projection.
public struct CodexMainChatSession: Sendable {
    private var turnLifecycle: CodexTurnLifecycleSession

    public var isSending: Bool {
        turnLifecycle.isSending
    }

    public var activeTurnID: String? {
        turnLifecycle.activeTurnID
    }

    public var canSteer: Bool {
        turnLifecycle.canSteer
    }

    public init(
        turnLifecycle: CodexTurnLifecycleSession = CodexTurnLifecycleSession()
    ) {
        self.turnLifecycle = turnLifecycle
    }

    public mutating func reset() {
        turnLifecycle.reset()
    }

    public mutating func beginTurnSubmission(_ submission: CodexComposerSubmission) -> CodexActivity {
        startPending()
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
        return CodexActivity(kind: .turn, title: "Pursuing goal", detail: submission.prompt)
    }

    public mutating func failGoalSubmission(message: String) -> CodexActivity {
        failToStart()
        return CodexActivity(kind: .turn, title: "Goal failed to start", detail: message)
    }

    public mutating func appendQueuedFollowUp(_ prompt: String) -> CodexActivity {
        return CodexActivity(kind: .turn, title: "Follow-up queued", detail: prompt)
    }

    public mutating func appendSteeredFollowUp(_ prompt: String) -> CodexActivity {
        return CodexActivity(kind: .turn, title: "Steering turn", detail: prompt)
    }

    public mutating func startPending() {
        turnLifecycle.startPending()
    }

    public mutating func start(turnID: String) {
        turnLifecycle.start(turnID: turnID)
    }

    public mutating func failToStart() {
        turnLifecycle.failToStart()
    }

    @discardableResult
    public mutating func finishActiveTurn(id turnID: String?) -> CodexMainChatUpdate? {
        guard turnLifecycle.complete(turnID: turnID) else { return nil }
        return CodexMainChatUpdate(actions: [
            .activity(kind: .turn, title: "Turn complete", detail: "Codex finished"),
            .refreshRecentChats,
            .flushQueuedFollowUps
        ])
    }

}
