import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexGoalStateSessionTests: XCTestCase {
    func testApplyGoalOwnsPursuitModeTurnTrackingAndSummaries() {
        var session = CodexGoalStateSession()
        let firstGoal = goal(tokensUsed: 0, timeUsedSeconds: 0)

        let firstChange = session.apply(firstGoal, turnID: nil)

        XCTAssertEqual(session.activeGoal, firstGoal)
        XCTAssertTrue(session.isPursuitEnabled)
        XCTAssertNil(session.activeTurnID)
        XCTAssertNil(firstChange.activity)
        XCTAssertFalse(firstChange.endedActiveTurn)

        let progressGoal = goal(tokensUsed: 12, timeUsedSeconds: 3, tokenBudget: 100)
        let progressChange = session.apply(progressGoal, turnID: "turn-goal")

        XCTAssertEqual(session.activeTurnID, "turn-goal")
        XCTAssertEqual(progressChange.activity, CodexGoalStateActivity(
            title: "Goal progress",
            detail: "Clean up state · 12/100 tokens · 3s elapsed"
        ))
        XCTAssertFalse(progressChange.endedActiveTurn)
    }

    func testNonActiveGoalEndsTrackedTurnButKeepsGoalVisible() {
        var session = CodexGoalStateSession(activeGoal: goal(), isPursuitEnabled: true, activeTurnID: "turn-goal")
        let completedGoal = goal(status: .complete, tokensUsed: 40)

        let change = session.apply(completedGoal, turnID: "turn-goal")

        XCTAssertEqual(session.activeGoal, completedGoal)
        XCTAssertTrue(session.isPursuitEnabled)
        XCTAssertNil(session.activeTurnID)
        XCTAssertTrue(change.endedActiveTurn)
        XCTAssertEqual(change.activity, CodexGoalStateActivity(
            title: "Goal complete",
            detail: "Clean up state · 40 tokens"
        ))
    }

    func testClearOnlyResetsMatchingThreadGoal() {
        var session = CodexGoalStateSession(activeGoal: goal(), isPursuitEnabled: true, activeTurnID: "turn-goal")

        XCTAssertNil(session.clear(threadID: "other-thread", currentThreadID: "thread-1"))
        XCTAssertNotNil(session.activeGoal)
        XCTAssertEqual(session.activeTurnID, "turn-goal")

        let change = session.clear(threadID: "thread-1", currentThreadID: "thread-1")

        XCTAssertNil(session.activeGoal)
        XCTAssertFalse(session.isPursuitEnabled)
        XCTAssertNil(session.activeTurnID)
        XCTAssertEqual(change?.activity, CodexGoalStateActivity(
            title: "Goal cleared",
            detail: "Thread goal removed"
        ))
    }

    func testPursuitModeChangeDescribesLocalAndRemoteClearWork() {
        var idleSession = CodexGoalStateSession()

        XCTAssertEqual(idleSession.setPursuitEnabled(true), CodexGoalPursuitModeChange(activity: CodexGoalStateActivity(
            title: "Goal mode enabled",
            detail: "Next message becomes a goal"
        )))
        XCTAssertNil(idleSession.setPursuitEnabled(true))

        var activeSession = CodexGoalStateSession(activeGoal: goal(), isPursuitEnabled: true)
        XCTAssertEqual(activeSession.setPursuitEnabled(false), CodexGoalPursuitModeChange(shouldClearRemoteGoal: true))
        XCTAssertFalse(activeSession.isPursuitEnabled)

        activeSession.restorePursuitAfterClearFailure()
        XCTAssertTrue(activeSession.isPursuitEnabled)
    }

    func testRouteContextAndNotificationMatchingUseTrackedGoalTurn() {
        var session = CodexGoalStateSession(activeGoal: goal(), isPursuitEnabled: true)
        session.trackStartedTurn(id: "turn-goal")

        XCTAssertEqual(session.globalRouteContext(currentThreadID: "thread-1"), CodexGlobalNotificationRouteContext(
            currentThreadID: "thread-1",
            hasActiveGoal: true,
            activeGoalTurnID: "turn-goal"
        ))
        XCTAssertTrue(session.isActiveTurnNotification(notification(turnID: "turn-goal")))
        XCTAssertFalse(session.isActiveTurnNotification(notification(turnID: "turn-other")))
    }
}

private func goal(
    status: ThreadGoalStatus = .active,
    tokensUsed: Int = 0,
    timeUsedSeconds: Int = 0,
    tokenBudget: Int? = nil
) -> ThreadGoal {
    ThreadGoal(
        threadId: "thread-1",
        objective: "Clean up state",
        status: status,
        tokenBudget: tokenBudget,
        tokensUsed: tokensUsed,
        timeUsedSeconds: timeUsedSeconds,
        createdAt: 1,
        updatedAt: 2
    )
}

private func notification(turnID: String) -> CodexNotification {
    let payload = TurnStartedNotification(
        threadId: "thread-1",
        turn: AppServerTurn(id: turnID, status: .inProgress)
    )
    return CodexNotification(
        method: CodexAppServerNotificationMethod.turnStarted.rawValue,
        payload: .turnStarted(payload),
        rawParams: [
            "threadId": .string("thread-1"),
            "turn": .dictionary([
                "id": .string(turnID),
                "status": .string(TurnStatus.inProgress.rawValue)
            ])
        ]
    )
}
