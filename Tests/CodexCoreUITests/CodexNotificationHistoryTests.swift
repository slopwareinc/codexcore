import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexNotificationHistoryTests: XCTestCase {
    func testTurnLifecycleSessionTracksPendingCompletionAndMismatchedTurns() {
        var lifecycle = CodexTurnLifecycleSession()

        lifecycle.startPending()
        XCTAssertTrue(lifecycle.isSending)
        XCTAssertFalse(lifecycle.complete(turnID: "turn-without-handle"))
        XCTAssertTrue(lifecycle.complete(turnID: nil))
        XCTAssertFalse(lifecycle.isSending)

        lifecycle.start(turnID: "turn-1")
        XCTAssertEqual(lifecycle.activeTurnID, "turn-1")
        XCTAssertFalse(lifecycle.complete(turnID: "turn-2"))
        XCTAssertTrue(lifecycle.isSending)
        XCTAssertTrue(lifecycle.complete(turnID: "turn-1"))
        XCTAssertFalse(lifecycle.isSending)
        XCTAssertNil(lifecycle.activeTurnID)
    }

    func testTurnLifecycleSessionMatchesTypedKnownAndUnknownCompletionNotifications() {
        var lifecycle = CodexTurnLifecycleSession()
        lifecycle.start(turnID: "turn-1")

        XCTAssertTrue(lifecycle.isCompletion(transcriptNotification(.turnCompleted(TurnCompletedNotification(
            threadId: "thread-1",
            turn: AppServerTurn(id: "turn-1", status: .completed)
        )))))
        XCTAssertTrue(lifecycle.isCompletion(transcriptNotification(.known(method: .turnCompleted, params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1")
        ]))))
        XCTAssertTrue(lifecycle.isCompletion(transcriptNotification(.unknown(method: CodexAppServerNotificationMethod.turnCompleted.rawValue, params: [
            "threadId": .string("thread-1"),
            "turn": .dictionary(["id": .string("turn-1")])
        ]))))
        XCTAssertFalse(lifecycle.isCompletion(transcriptNotification(.turnCompleted(TurnCompletedNotification(
            threadId: "thread-1",
            turn: AppServerTurn(id: "turn-2", status: .completed)
        )))))
    }

    func testGlobalNotificationRouterMapsThreadMetadataAndSwallowsRecognizedNoOps() throws {
        let metadataResult = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.known(method: .threadStarted, params: [
            "thread": .dictionary([
                "id": .string("child-thread"),
                "parentThreadId": .string("parent-thread"),
                "agentNickname": .string("Ada"),
                "agentRole": .string("Reviewer")
            ])
        ]))))

        XCTAssertEqual(metadataResult.action, .threadStartedMetadata(CodexThreadStartedMetadata(
            threadID: "child-thread",
            parentThreadID: "parent-thread",
            name: "Ada",
            role: "Reviewer"
        )))

        let parentThreadStarted = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.known(method: .threadStarted, params: [
            "thread": .dictionary([
                "id": .string("parent-thread"),
                "name": .string("Main")
            ])
        ]))))
        XCTAssertNil(parentThreadStarted.action)
    }

    func testGlobalNotificationRouterMapsGoalAndGoalTurnNotifications() throws {
        let goal = ThreadGoal(
            threadId: "thread-1",
            objective: "Clean up state",
            status: .active,
            tokensUsed: 10,
            timeUsedSeconds: 1,
            createdAt: 1,
            updatedAt: 2
        )

        let typedGoalResult = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.threadGoalUpdated(ThreadGoalUpdatedNotification(
            threadId: "thread-1",
            turnId: "turn-goal",
            goal: goal
        )))))
        XCTAssertEqual(typedGoalResult.action, .goalUpdated(goal: goal, turnID: "turn-goal"))

        let rawCleared = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.unknown(method: CodexAppServerNotificationMethod.threadGoalCleared.rawValue, params: [
            "threadId": .string("thread-1")
        ]))))
        XCTAssertEqual(rawCleared.action, .goalCleared(threadID: "thread-1"))

        let trackedTurn = try XCTUnwrap(CodexGlobalNotificationRouter.apply(
            transcriptNotification(.turnStarted(TurnStartedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-1", status: .inProgress)
            ))),
            context: CodexGlobalNotificationRouteContext(currentThreadID: "thread-1", hasActiveGoal: true)
        ))
        XCTAssertEqual(trackedTurn.action, CodexGlobalNotificationAction.goalTurnStarted(turnID: "turn-1"))

        XCTAssertNil(CodexGlobalNotificationRouter.apply(
            transcriptNotification(.turnStarted(TurnStartedNotification(
                threadId: "other-thread",
                turn: AppServerTurn(id: "turn-2", status: .inProgress)
            ))),
            context: CodexGlobalNotificationRouteContext(currentThreadID: "thread-1", hasActiveGoal: true)
        ))
    }

    func testGlobalNotificationRouterMapsSkillsCompactionAndMCPStartup() throws {
        let skills = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.unknown(
            method: CodexAppServerNotificationMethod.skillsChanged.rawValue,
            params: [:]
        ))))
        XCTAssertEqual(skills.action, .skillsChanged)

        let compacted = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.known(method: .threadCompacted, params: [
            "thread": .dictionary(["id": .string("thread-1")])
        ]))))
        XCTAssertEqual(compacted.action, .threadCompacted(threadID: "thread-1"))

        let startup = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.unknown(method: CodexAppServerNotificationMethod.mcpServerStartupStatusUpdated.rawValue, params: [
            "name": .string("filesystem"),
            "status": .string("failed"),
            "error": .string("node missing")
        ]))))
        XCTAssertEqual(startup.action, .mcpServerStartupStatus(CodexMCPServerStartupStatus(
            name: "filesystem",
            status: "failed",
            error: "node missing"
        )))

        let malformedStartup = try XCTUnwrap(CodexGlobalNotificationRouter.apply(transcriptNotification(.known(method: .mcpServerStartupStatusUpdated, params: [
            "status": .string("started")
        ]))))
        XCTAssertNil(malformedStartup.action)
    }

    func testThreadHistorySnapshotRestoresChildSubagentThreadHistory() throws {
        let parent: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-parent"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-parent"),
                        "startedAt": .int(1_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("spawn-1"),
                                "type": .string("collabAgentToolCall"),
                                "tool": .string("spawnAgent"),
                                "prompt": .string("Run child script"),
                                "receiverThreadIds": .array([.string("thread-child")]),
                                "agentsStates": .dictionary([
                                    "thread-child": .dictionary([
                                        "status": .string("running"),
                                        "agentNickname": .string("Ada"),
                                        "agentRole": .string("coder")
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let child: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-child"),
                "agentNickname": .string("Ada"),
                "agentRole": .string("coder"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-child"),
                        "status": .string("completed"),
                        "startedAt": .int(1_010),
                        "completedAt": .int(1_020),
                        "items": .array([
                            .dictionary([
                                "id": .string("child-user"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .dictionary([
                                        "type": .string("text"),
                                        "text": .string("Run child script")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("child-command"),
                                "type": .string("commandExecution"),
                                "command": .array([.string("printf"), .string("42")]),
                                "aggregatedOutput": .string("42"),
                                "status": .string("completed"),
                                "exitCode": .int(0)
                            ]),
                            .dictionary([
                                "id": .string("child-answer"),
                                "type": .string("agentMessage"),
                                "text": .string("The script printed 42.")
                            ])
                        ])
                    ])
                ])
            ])
        ])

        var snapshot = CodexThreadHistorySnapshot(raw: parent)
        XCTAssertEqual(snapshot.subagentThreadIDs, ["thread-child"])

        XCTAssertTrue(snapshot.applyChildThread(raw: child))

        let subagent = try XCTUnwrap(snapshot.subagents.first)
        XCTAssertEqual(subagent.id, "thread-child")
        XCTAssertEqual(subagent.name, "Ada [coder]")
        XCTAssertEqual(subagent.status, .completed)
        XCTAssertEqual(subagent.messages.map(\.role), [.user, .terminal, .assistant])
        XCTAssertEqual(subagent.messages[0].text, "Run child script")
        XCTAssertEqual(subagent.messages[1].commandRun?.command, "printf 42")
        XCTAssertEqual(subagent.messages[1].commandRun?.output, "42")
        XCTAssertEqual(subagent.messages[2].text, "The script printed 42.")
    }

    func testThreadHistorySessionLoadsChildThreadsAndAppliesSnapshot() async throws {
        let parent: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-parent"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-parent"),
                        "startedAt": .int(1_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("user-1"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .dictionary(["type": .string("text"), "text": .string("Inspect state")])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("spawn-1"),
                                "type": .string("collabAgentToolCall"),
                                "tool": .string("spawnAgent"),
                                "prompt": .string("Inspect child state"),
                                "receiverThreadIds": .array([.string("thread-child")]),
                                "agentsStates": .dictionary([
                                    "thread-child": .dictionary(["status": .string("running")])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let child: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-child"),
                "agentNickname": .string("Ada"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-child"),
                        "status": .string("completed"),
                        "items": .array([
                            .dictionary([
                                "id": .string("child-answer"),
                                "type": .string("agentMessage"),
                                "text": .string("Child state is clean.")
                            ])
                        ])
                    ])
                ])
            ])
        ])
        var requestedThreadIDs: [String] = []

        let result = await CodexThreadHistorySession.restore(parentRaw: parent) { childThreadID in
            requestedThreadIDs.append(childThreadID)
            return child
        }

        XCTAssertEqual(requestedThreadIDs, ["thread-child"])
        XCTAssertEqual(result.restoredChildThreadCount, 1)
        XCTAssertEqual(result.messageCount, 1)

        var mainSession = CodexMainChatSession()
        mainSession.appendMessage(.system, "stale")
        var mapper = CodexAgentStateMapper()
        var sideSession = CodexSideChatSession()
        sideSession.open()

        let activity = CodexThreadHistorySession.apply(
            result,
            mainChatSession: &mainSession,
            agentStateMapper: &mapper,
            sideChatSession: &sideSession
        )

        XCTAssertEqual(activity.title, "Loaded transcript")
        XCTAssertEqual(activity.detail, "1 messages restored, 1 agents restored")
        XCTAssertEqual(mainSession.messages.map(\.text), ["Inspect state"])
        XCTAssertEqual(mapper.subagents.first?.name, "Ada")
        XCTAssertEqual(mapper.subagents.first?.messages.map(\.text), ["Inspect child state", "Child state is clean."])
        XCTAssertNil(sideSession.sideChat)
    }

}
