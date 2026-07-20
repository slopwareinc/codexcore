import Foundation
import CodexCore

public struct CodexGoalStateActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct CodexGoalStateChange: Equatable, Sendable {
    public var activity: CodexGoalStateActivity?
    public var endedActiveTurn: Bool

    public init(activity: CodexGoalStateActivity? = nil, endedActiveTurn: Bool = false) {
        self.activity = activity
        self.endedActiveTurn = endedActiveTurn
    }
}

public struct CodexGoalPursuitModeChange: Equatable, Sendable {
    public var activity: CodexGoalStateActivity?
    public var shouldClearRemoteGoal: Bool

    public init(activity: CodexGoalStateActivity? = nil, shouldClearRemoteGoal: Bool = false) {
        self.activity = activity
        self.shouldClearRemoteGoal = shouldClearRemoteGoal
    }
}

public struct CodexGoalStateSession: Equatable, Sendable {
    public private(set) var activeGoal: ThreadGoal?
    public private(set) var isPursuitEnabled: Bool
    public private(set) var activeTurnID: String?

    public init(
        activeGoal: ThreadGoal? = nil,
        isPursuitEnabled: Bool = false,
        activeTurnID: String? = nil
    ) {
        self.activeGoal = activeGoal
        self.isPursuitEnabled = isPursuitEnabled
        self.activeTurnID = activeTurnID
    }

    public var hasActiveGoal: Bool {
        activeGoal != nil
    }

    public func canSendFollowUp(canSteer: Bool) -> Bool {
        canSteer || activeTurnID != nil
    }

    @discardableResult
    public mutating func setPursuitEnabled(_ enabled: Bool) -> CodexGoalPursuitModeChange? {
        guard enabled != isPursuitEnabled else { return nil }
        isPursuitEnabled = enabled

        if enabled {
            return CodexGoalPursuitModeChange(activity: CodexGoalStateActivity(
                title: "Goal mode enabled",
                detail: activeGoal.map { displayObjective($0.objective) } ?? "Next message becomes a goal"
            ))
        }

        if activeGoal != nil {
            return CodexGoalPursuitModeChange(shouldClearRemoteGoal: true)
        }

        return CodexGoalPursuitModeChange(activity: CodexGoalStateActivity(
            title: "Goal mode disabled",
            detail: "Composer returned to chat mode"
        ))
    }

    public mutating func restorePursuitAfterClearFailure() {
        isPursuitEnabled = true
    }

    @discardableResult
    public mutating func apply(
        _ goal: ThreadGoal,
        turnID: String?,
        shouldAnnounce: Bool = true
    ) -> CodexGoalStateChange {
        let isUpdate = activeGoal != nil
        activeGoal = goal
        isPursuitEnabled = true
        if let turnID {
            activeTurnID = turnID
        }

        let endedActiveTurn = goal.status != .active
        if endedActiveTurn {
            activeTurnID = nil
        }

        let activity: CodexGoalStateActivity?
        if shouldAnnounce, isUpdate {
            activity = CodexGoalStateActivity(
                title: goal.status == .active ? "Goal progress" : "Goal \(goal.status.rawValue)",
                detail: summary(for: goal)
            )
        } else {
            activity = nil
        }

        return CodexGoalStateChange(activity: activity, endedActiveTurn: endedActiveTurn)
    }

    @discardableResult
    public mutating func clear(threadID: String?, currentThreadID: String?) -> CodexGoalStateChange? {
        guard threadID == nil || threadID == currentThreadID else { return nil }
        guard activeGoal != nil else { return nil }
        reset()
        return CodexGoalStateChange(activity: CodexGoalStateActivity(
            title: "Goal cleared",
            detail: "Thread goal removed"
        ))
    }

    public mutating func reset() {
        activeGoal = nil
        activeTurnID = nil
        isPursuitEnabled = false
    }

    public mutating func trackStartedTurn(id turnID: String) {
        activeTurnID = turnID
    }

    public func summary(for goal: ThreadGoal) -> String {
        var parts = [displayObjective(goal.objective)]
        if let budget = goal.tokenBudget, budget > 0 {
            parts.append("\(goal.tokensUsed)/\(budget) tokens")
        } else if goal.tokensUsed > 0 {
            parts.append("\(goal.tokensUsed) tokens")
        }
        if goal.timeUsedSeconds > 0 {
            parts.append("\(goal.timeUsedSeconds)s elapsed")
        }
        return parts.joined(separator: " · ")
    }

    private func displayObjective(_ objective: String) -> String {
        CodexFileReferencePromptCodec.visibleRequest(from: objective)
    }
}
