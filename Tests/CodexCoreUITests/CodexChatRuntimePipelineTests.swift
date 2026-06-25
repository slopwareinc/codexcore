import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexChatRuntimePipelineTests: XCTestCase {
    func testMainChatSessionOwnsResidualNotificationFallbacksAndTurnCompletion() throws {
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            plan: [
                TurnPlanStep(step: "Use canonical state", status: .inProgress)
            ],
            planExplanation: "From store",
            diff: "diff --git a/Store.swift b/Store.swift\n+store"
        )
        let commandItem = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
            "status": .string("inProgress")
        ])
        let subagentItem = try transcriptThreadItem([
            "id": .string("agent-1"),
            "type": .string("collabAgentToolCall"),
            "status": .string("inProgress"),
            "title": .string("Spawn agent")
        ])

        var session = CodexMainChatSession()
        session.start(turnID: "turn-1")

        let started = session.apply(
            transcriptNotification(.turnStarted(TurnStartedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-1", status: .inProgress)
            ))),
            turnSnapshot: storeTurn,
            isSubagentItem: { _ in false }
        )
        XCTAssertEqual(session.currentPlan.map(\.step), ["Use canonical state"])
        XCTAssertEqual(started?.actions, [
            .activity(kind: .turn, title: "Codex is working", detail: "Turn started")
        ])

        let commandStarted = session.apply(
            transcriptNotification(.itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: commandItem))),
            turnSnapshot: nil,
            isSubagentItem: { _ in false }
        )
        XCTAssertEqual(commandStarted?.actions.first, .activity(kind: .tool, title: "Ran a command", detail: "swift test"))
        XCTAssertEqual(session.messages.first?.commandRun?.command, "swift test")

        let subagentStarted = session.apply(
            transcriptNotification(.itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: subagentItem))),
            turnSnapshot: nil,
            isSubagentItem: { $0.id == "agent-1" }
        )
        XCTAssertEqual(subagentStarted?.actions, [.subagentItemStarted(subagentItem)])

        let tokenUpdate = session.apply(
            transcriptNotification(.threadTokenUsageUpdated(ThreadTokenUsageUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                tokenUsage: ThreadTokenUsage(raw: ["used": .int(12), "limit": .int(100)])
            ))),
            turnSnapshot: nil,
            isSubagentItem: { _ in false }
        )
        XCTAssertEqual(tokenUpdate?.actions, [
            .activity(kind: .token, title: "Token usage updated", detail: "12 / 100 tokens")
        ])

        let completed = session.apply(
            transcriptNotification(.turnCompleted(TurnCompletedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-1", status: .completed)
            ))),
            turnSnapshot: storeTurn,
            isSubagentItem: { _ in false }
        )
        XCTAssertFalse(session.isSending)
        XCTAssertEqual(completed?.actions, [
            .activity(kind: .turn, title: "Turn complete", detail: "Codex finished"),
            .refreshRecentChats,
            .flushQueuedFollowUps
        ])

        let loginPayload = try CodexJSONValue.dictionary([
            "loginId": .string("login-1")
        ]).decode(AccountLoginCompletedNotification.self)
        let login = session.apply(
            transcriptNotification(.accountLoginCompleted(loginPayload)),
            turnSnapshot: nil,
            isSubagentItem: { _ in false }
        )
        XCTAssertEqual(login?.actions, [
            .activity(kind: .login, title: "Login completed", detail: "Authentication updated")
        ])
    }

    func testMainChatCompletionClearsStreamingTurnDiffChrome() throws {
        var session = CodexMainChatSession()
        session.start(turnID: "turn-visual")

        let diffUpdated = session.apply(
            transcriptNotification(.turnDiffUpdated(TurnDiffUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-visual",
                diff: "diff --git a/visual_qa_probe.txt b/visual_qa_probe.txt\n+Visual QA probe."
            ))),
            turnSnapshot: CodexTurnSnapshot(
                id: "turn-visual",
                status: .running,
                diff: "diff --git a/visual_qa_probe.txt b/visual_qa_probe.txt\n+Visual QA probe."
            ),
            isSubagentItem: { _ in false }
        )

        XCTAssertEqual(diffUpdated?.actions.first, .activity(kind: .tool, title: "Diff updated", detail: "1 file(s) changed"))
        XCTAssertTrue(session.isSending)
        XCTAssertEqual(session.messages.last?.fileChange?.status, "active")
        XCTAssertTrue(session.messages.last?.isStreaming ?? false)
        XCTAssertTrue(session.messages.last?.fileChange?.isStreaming ?? false)

        let completed = session.apply(
            transcriptNotification(.turnCompleted(TurnCompletedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-visual", status: .completed)
            ))),
            turnSnapshot: CodexTurnSnapshot(
                id: "turn-visual",
                status: .completed,
                diff: "diff --git a/visual_qa_probe.txt b/visual_qa_probe.txt\n+Visual QA probe."
            ),
            isSubagentItem: { _ in false }
        )

        XCTAssertEqual(completed?.actions, [
            .activity(kind: .turn, title: "Turn complete", detail: "Codex finished"),
            .refreshRecentChats,
            .flushQueuedFollowUps
        ])
        XCTAssertFalse(session.isSending)
        XCTAssertFalse(session.messages.contains(where: \.isStreaming))
        XCTAssertFalse(session.messages.contains { $0.fileChange?.isStreaming == true })
    }

    func testChatNotificationPipelineOwnsGlobalMainAndSubagentRouting() throws {
        let goal = ThreadGoal(
            threadId: "thread-1",
            objective: "Clean up state",
            status: .active,
            tokensUsed: 0,
            timeUsedSeconds: 0,
            createdAt: 1,
            updatedAt: 2
        )
        let storeTurn = CodexTurnSnapshot(
            id: "turn-goal",
            status: .running,
            plan: [TurnPlanStep(step: "Use the store-backed route", status: .inProgress)],
            planExplanation: "Pipeline snapshot",
            diff: nil
        )

        var mainSession = CodexMainChatSession()
        var goalSession = CodexGoalStateSession(activeGoal: goal, isPursuitEnabled: true)
        var mapper = CodexAgentStateMapper()
        var integrations = CodexIntegrationCatalogSession()

        let started = CodexChatNotificationPipeline.apply(
            transcriptNotification(.turnStarted(TurnStartedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-goal", status: .inProgress)
            ))),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in storeTurn }
        )

        XCTAssertEqual(goalSession.activeTurnID, "turn-goal")
        XCTAssertTrue(mainSession.isSending)
        XCTAssertEqual(mainSession.currentPlan.map(\.step), ["Use the store-backed route"])
        XCTAssertEqual(started?.syncMainTranscript, true)
        XCTAssertEqual(started?.activities.map(\.kind), [.turn])
        XCTAssertEqual(started?.activities.map(\.title), ["Codex is working"])
        XCTAssertEqual(started?.activities.map(\.detail), ["Turn started"])

        let spawn = try transcriptThreadItem([
            "id": .string("spawn-1"),
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "prompt": .string("Inspect duplicated state"),
            "receiverThreadIds": .array([.string("thread-agent")]),
            "agentsStates": .dictionary([
                "thread-agent": .dictionary(["status": .string("pendingInit")])
            ]),
            "status": .string("inProgress")
        ])

        let spawned = CodexChatNotificationPipeline.apply(
            transcriptNotification(.itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-goal", item: spawn))),
            mode: .mainTurnStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in nil }
        )

        XCTAssertEqual(spawned?.syncMainTranscript, true)
        XCTAssertEqual(spawned?.syncAgentState, true)
        XCTAssertEqual(mapper.subagents.map(\.id), ["thread-agent"])
        XCTAssertEqual(spawned?.activities.first?.title, "Subagent spawning")

        let childCommand = try transcriptThreadItem([
            "id": .string("cmd-child"),
            "type": .string("commandExecution"),
            "command": .string("raw swift test"),
            "status": .string("inProgress")
        ])
        let childStartStoreTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .running,
            items: [
                .commandExecution(
                    id: "cmd-child",
                    command: "store swift test",
                    output: "",
                    status: "active",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-child": .commandExecution(CodexCommandExecutionDetail(
                    command: "store swift test",
                    cwd: "/repo",
                    output: "",
                    status: "active",
                    exitCode: nil
                ))
            ]
        )
        let childRouted = CodexChatNotificationPipeline.apply(
            transcriptNotification(.itemStarted(ItemStartedNotification(threadId: "thread-agent", turnId: "turn-child", item: childCommand))),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { threadID, _ in
                threadID == "thread-agent" ? childStartStoreTurn : nil
            }
        )

        XCTAssertEqual(childRouted?.syncAgentState, true)
        XCTAssertEqual(childRouted?.activities.first?.title, "Subagent item started")
        let startedRun = mapper.subagents.first?.messages.first(where: { $0.commandRun?.itemID == "cmd-child" })?.commandRun
        XCTAssertEqual(startedRun?.command, "store swift test")
        XCTAssertEqual(startedRun?.cwd, "/repo")

        let childLiveStoreTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .running,
            items: [
                .commandExecution(
                    id: "cmd-child",
                    command: "store swift test",
                    output: "store accumulated output",
                    status: "active",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-child": .commandExecution(CodexCommandExecutionDetail(
                    command: "store swift test",
                    cwd: "/repo",
                    output: "store accumulated output",
                    status: "active",
                    exitCode: nil
                ))
            ]
        )
        let childLiveOutput = CodexChatNotificationPipeline.apply(
            transcriptNotification(.known(
                method: .itemCommandExecutionOutputDelta,
                params: [
                    "threadId": .string("thread-agent"),
                    "turnId": .string("turn-child"),
                    "itemId": .string("cmd-child"),
                    "delta": .string("raw delta")
                ]
            )),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { threadID, _ in
                threadID == "thread-agent" ? childLiveStoreTurn : nil
            }
        )

        XCTAssertEqual(childLiveOutput?.syncAgentState, true)
        let liveRun = mapper.subagents.first?.messages.first(where: { $0.commandRun?.itemID == "cmd-child" })?.commandRun
        XCTAssertEqual(liveRun?.output, "store accumulated output")

        let childToolStoreTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .running,
            items: [
                .mcpToolCall(
                    id: "tool-child",
                    server: "store-server",
                    tool: "store-tool",
                    status: "inProgress",
                    timestamp: Date(),
                    progress: ["store progress"]
                )
            ],
            itemDetails: [
                "tool-child": .toolCall(CodexToolCallDetail(
                    server: "store-server",
                    tool: "store-tool",
                    status: "inProgress",
                    progress: ["store progress"]
                ))
            ]
        )
        let childToolProgress = CodexChatNotificationPipeline.apply(
            transcriptNotification(.known(
                method: .itemMCPToolCallProgress,
                params: [
                    "threadId": .string("thread-agent"),
                    "turnId": .string("turn-child"),
                    "itemId": .string("tool-child"),
                    "message": .string("raw progress")
                ]
            )),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { threadID, _ in
                threadID == "thread-agent" ? childToolStoreTurn : nil
            }
        )

        XCTAssertEqual(childToolProgress?.syncAgentState, true)
        let liveTool = mapper.subagents.first?.messages.first(where: { $0.toolCall?.itemID == "tool-child" })?.toolCall
        XCTAssertEqual(liveTool?.server, "store-server")
        XCTAssertEqual(liveTool?.tool, "store-tool")
        XCTAssertEqual(liveTool?.progress, ["store progress"])

        let childPlanStoreTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .running,
            plan: [TurnPlanStep(step: "store child plan", status: .inProgress)],
            planExplanation: "store explanation"
        )
        let childPlanUpdated = CodexChatNotificationPipeline.apply(
            transcriptNotification(.turnPlanUpdated(TurnPlanUpdatedNotification(
                threadId: "thread-agent",
                turnId: "turn-child",
                plan: [TurnPlanStep(step: "raw child plan", status: .pending)],
                explanation: "raw explanation"
            ))),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { threadID, _ in
                threadID == "thread-agent" ? childPlanStoreTurn : nil
            }
        )

        XCTAssertEqual(childPlanUpdated?.syncAgentState, true)
        let childPlan = mapper.subagents.first?.messages.first(where: { $0.planUpdate?.itemID == "turn-plan-turn-child" })?.planUpdate
        XCTAssertEqual(childPlan?.steps.map(\.step), ["store child plan"])
        XCTAssertEqual(childPlan?.explanation, "store explanation")

        let childStoreTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .completed,
            items: [
                .commandExecution(
                    id: "cmd-child",
                    command: "swift test",
                    output: "store-backed output",
                    status: "completed",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-child": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test",
                    cwd: "/repo",
                    output: "store-backed output",
                    status: "completed",
                    exitCode: 0
                ))
            ]
        )
        let rawChildCompleted = try transcriptThreadItem([
            "id": .string("cmd-child"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
            "output": .string("raw notification output"),
            "status": .string("completed")
        ])
        let childCompleted = CodexChatNotificationPipeline.apply(
            transcriptNotification(.itemCompleted(ItemCompletedNotification(threadId: "thread-agent", turnId: "turn-child", item: rawChildCompleted))),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { threadID, _ in
                threadID == "thread-agent" ? childStoreTurn : nil
            }
        )

        XCTAssertEqual(childCompleted?.syncAgentState, true)
        let childRun = mapper.subagents.first?.messages.first(where: { $0.commandRun?.itemID == "cmd-child" })?.commandRun
        XCTAssertEqual(childRun?.output, "store-backed output")
        XCTAssertEqual(childRun?.exitCode, 0)

        let skillsChanged = CodexChatNotificationPipeline.apply(
            transcriptNotification(.unknown(method: CodexAppServerNotificationMethod.skillsChanged.rawValue, params: [:])),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in nil }
        )
        XCTAssertEqual(skillsChanged?.actions, [.refreshSlashCommands(forceReload: true)])

        let threadArchived = CodexChatNotificationPipeline.apply(
            transcriptNotification(.known(method: .threadArchived, params: [
                "threadId": .string("thread-1")
            ])),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in nil }
        )
        XCTAssertEqual(threadArchived?.actions, [.refreshRecentChats])

        let completed = CodexChatNotificationPipeline.apply(
            transcriptNotification(.turnCompleted(TurnCompletedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-goal", status: .completed)
            ))),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in storeTurn }
        )

        XCTAssertFalse(mainSession.isSending)
        XCTAssertEqual(completed?.actions, [.refreshRecentChats, .flushQueuedFollowUps])
        XCTAssertEqual(completed?.activities.map(\.kind), [.turn])
        XCTAssertEqual(completed?.activities.map(\.title), ["Turn complete"])
        XCTAssertEqual(completed?.activities.map(\.detail), ["Codex finished"])
    }

    func testGlobalStreamRoutesGuardianAndAutoApprovalToNoticeCards() {
        var mainSession = CodexMainChatSession()
        var goalSession = CodexGoalStateSession()
        var mapper = CodexAgentStateMapper()
        var integrations = CodexIntegrationCatalogSession()

        let guardianNotice = CodexChatNotificationPipeline.apply(
            transcriptNotification(.known(
                method: .guardianWarning,
                params: ["message": .string("Manual approval required")]
            )),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in nil }
        )
        XCTAssertEqual(guardianNotice?.syncMainTranscript, true)
        XCTAssertEqual(mainSession.messages.last?.role, .notice)
        XCTAssertEqual(mainSession.messages.last?.notice?.title, "Guardian warning")

        let reviewStarted = CodexChatNotificationPipeline.apply(
            transcriptNotification(.unknown(
                method: CodexAppServerNotificationMethod.itemAutoApprovalReviewStarted.rawValue,
                params: [
                    "reviewId": .string("review-1"),
                    "targetItemId": .string("item-1"),
                    "review": .dictionary([
                        "status": .string("approved"),
                        "rationale": .string("Safe command")
                    ]),
                    "action": .dictionary([
                        "type": .string("command"),
                        "command": .string("swift test")
                    ])
                ]
            )),
            mode: .globalStream,
            currentThreadID: "thread-1",
            mainChatSession: &mainSession,
            goalSession: &goalSession,
            agentStateMapper: &mapper,
            integrationCatalogSession: &integrations,
            turnSnapshot: { _, _ in nil }
        )
        XCTAssertEqual(reviewStarted?.syncMainTranscript, true)
        XCTAssertEqual(mainSession.messages.last?.role, .notice)
        XCTAssertEqual(mainSession.messages.last?.notice?.title, "Auto review approved")
        XCTAssertTrue(mainSession.messages.last?.notice?.isStreaming ?? false)
    }

    @MainActor
    func testChatRuntimeStateRoutesMainAndSideChatThroughStoreSnapshots() throws {
        let rawItem = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("raw command"),
            "status": .string("active")
        ])
        let mainTurn = CodexTurnSnapshot(
            id: "turn-main",
            items: [
                .commandExecution(
                    id: "cmd-1",
                    command: "store main command",
                    output: "",
                    status: "active",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "store main command",
                    cwd: "/repo/main",
                    output: "",
                    status: "active"
                ))
            ]
        )
        let sideTurn = CodexTurnSnapshot(
            id: "turn-side",
            items: [
                .commandExecution(
                    id: "cmd-1",
                    command: "store side command",
                    output: "",
                    status: "active",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "store side command",
                    cwd: "/repo/side",
                    output: "",
                    status: "active"
                ))
            ]
        )
        let store = CodexCoreStore(
            activeThread: CodexThreadSnapshot(id: "thread-main", turns: [mainTurn]),
            threadSnapshotsByID: [
                "thread-side": CodexThreadSnapshot(id: "thread-side", turns: [sideTurn])
            ]
        )

        var runtimeState = CodexChatRuntimeState()
        let mainResult = runtimeState.apply(
            transcriptNotification(.itemStarted(ItemStartedNotification(
                threadId: "thread-main",
                turnId: "turn-main",
                item: rawItem
            ))),
            mode: .mainTurnStream,
            currentThreadID: "thread-main",
            store: store
        )

        XCTAssertEqual(mainResult?.syncMainTranscript, true)
        XCTAssertEqual(runtimeState.messages.first?.commandRun?.command, "store main command")
        XCTAssertEqual(runtimeState.messages.first?.commandRun?.cwd, "/repo/main")

        let sideResult = runtimeState.applySideChat(
            transcriptNotification(.itemStarted(ItemStartedNotification(
                threadId: "thread-side",
                turnId: "turn-side",
                item: rawItem
            ))),
            store: store,
            currentThreadID: "thread-main"
        )

        XCTAssertEqual(sideResult?.activity?.detail, "store side command")
        XCTAssertEqual(runtimeState.sideChat?.messages.first?.commandRun?.command, "store side command")
        XCTAssertEqual(runtimeState.sideChat?.messages.first?.commandRun?.cwd, "/repo/side")
    }

    func testChatRuntimeStateOwnsTurnAndSideChatSubmissionState() throws {
        var runtimeState = CodexChatRuntimeState()
        var composer = CodexComposerStateSession()

        let turnSubmission = CodexComposerSubmission(prompt: "Inspect state")
        let beginTurn = runtimeState.beginTurnSubmission(turnSubmission)
        XCTAssertEqual(beginTurn.title, "You asked Codex")
        XCTAssertTrue(runtimeState.isSending)
        XCTAssertEqual(runtimeState.messages.last?.text, "Inspect state")

        let failedTurn = runtimeState.failTurnSubmission(message: "offline")
        XCTAssertEqual(failedTurn.title, "Turn failed to start")
        XCTAssertFalse(runtimeState.isSending)

        let followUp = runtimeState.prepareFollowUp(
            prompt: "Next",
            composerSession: &composer,
            followUpBehavior: .queue,
            canSteer: true
        )
        guard case .queued(let queuedPrompt, let queuedActivity) = followUp else {
            return XCTFail("Expected queued follow-up")
        }
        XCTAssertEqual(queuedPrompt, "Next")
        XCTAssertEqual(queuedActivity.title, "Follow-up queued")
        XCTAssertEqual(queuedActivity.detail, "Next")
        XCTAssertEqual(composer.queuedFollowUps, ["Next"])

        let queued = try XCTUnwrap(runtimeState.dequeueQueuedFollowUp(
            composerSession: &composer,
            isSending: false
        ))
        XCTAssertEqual(queued.prompt, "Next")
        XCTAssertTrue(runtimeState.isSending)

        let failedQueued = runtimeState.failQueuedFollowUp(
            queued,
            message: "still offline",
            composerSession: &composer
        )
        XCTAssertEqual(failedQueued.title, "Queued follow-up failed to start")
        XCTAssertEqual(composer.queuedFollowUps, ["Next"])
        XCTAssertFalse(runtimeState.isSending)

        let sideActivities = runtimeState.beginSideChatSubmission(prompt: "Side quest")
        XCTAssertEqual(sideActivities.map(\.title), ["Opened side chat", "Side chat asked"])
        XCTAssertTrue(runtimeState.isSideChatSending)
        XCTAssertEqual(runtimeState.sideChat?.messages.last?.text, "Side quest")

        let failedSide = runtimeState.failSideChatSubmission(message: "side offline")
        XCTAssertEqual(failedSide.title, "Side chat failed to start")
        XCTAssertFalse(runtimeState.isSideChatSending)
    }

    func testNotificationMetadataExtractsThreadAndTurnIDsFromTypedAndRawNotifications() {
        XCTAssertEqual(
            CodexNotificationMetadata.turnID(from: transcriptNotification(.turnCompleted(TurnCompletedNotification(
                threadId: "thread-1",
                turn: AppServerTurn(id: "turn-typed", status: .completed)
            )))),
            "turn-typed"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.threadID(from: transcriptNotification(.turnCompleted(TurnCompletedNotification(
                threadId: "thread-typed",
                turn: AppServerTurn(id: "turn-typed", status: .completed)
            )))),
            "thread-typed"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.turnID(from: transcriptNotification(.known(method: .turnCompleted, params: [
                "thread": .dictionary(["id": .string("thread-raw")]),
                "turn": .dictionary(["id": .string("turn-raw")])
            ]))),
            "turn-raw"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.threadID(from: transcriptNotification(.known(method: .turnCompleted, params: [
                "thread": .dictionary(["id": .string("thread-raw")]),
                "turn": .dictionary(["id": .string("turn-raw")])
            ]))),
            "thread-raw"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.noticeItemID(
                method: .itemAutoApprovalReviewStarted,
                params: ["reviewId": .string("review-1")]
            ),
            "review-review-1"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.noticeItemID(
                method: .warning,
                params: ["targetItemId": .string("item-1")]
            ),
            "\(CodexAppServerNotificationMethod.warning.rawValue)-item-1"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.turnErrorMessage(from: [
                "turn": .dictionary([
                    "id": .string("turn-failed"),
                    "error": .dictionary(["message": .string("model unavailable")])
                ])
            ]),
            "model unavailable"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.turnErrorMessage(from: [
                "error": .dictionary(["raw": .string("raw failure")])
            ]),
            "raw failure"
        )
        XCTAssertEqual(
            CodexNotificationMetadata.knownRoute(method: .itemCommandExecutionOutputDelta, params: [
                "threadId": .string("thread-route"),
                "turnId": .string("turn-route"),
                "itemId": .string("cmd-route"),
                "delta": .string("hello")
            ]),
            .commandOutputDelta(CodexKnownItemTextNotificationRoute(
                item: CodexKnownItemNotificationRoute(
                    threadID: "thread-route",
                    turnID: "turn-route",
                    itemID: "cmd-route"
                ),
                text: "hello"
            ))
        )
        XCTAssertEqual(
            CodexNotificationMetadata.knownRoute(method: .itemCommandExecutionTerminalInteraction, params: [
                "itemId": .string("cmd-route"),
                "stdin": .string("swift test")
            ]),
            .commandTerminalInteraction(CodexKnownItemTextNotificationRoute(
                item: CodexKnownItemNotificationRoute(
                    threadID: nil,
                    turnID: nil,
                    itemID: "cmd-route"
                ),
                text: "\n$ swift test"
            ))
        )
        XCTAssertEqual(
            CodexNotificationMetadata.knownRoute(method: .turnPlanUpdated, params: [
                "threadId": .string("thread-plan"),
                "turnId": .string("turn-plan"),
                "plan": .array([
                    .dictionary([
                        "step": .string("Refactor"),
                        "status": .string("inProgress")
                    ])
                ]),
                "explanation": .string("one path")
            ]),
            .turnPlanUpdated(CodexKnownTurnPlanNotificationRoute(
                threadID: "thread-plan",
                turnID: "turn-plan",
                plan: [TurnPlanStep(step: "Refactor", status: .inProgress)],
                explanation: "one path"
            ))
        )
        XCTAssertEqual(
            CodexNotificationMetadata.knownRoute(method: .warning, params: [
                "threadId": .string("thread-notice"),
                "itemId": .string("notice-item")
            ]),
            .notice(CodexKnownNoticeNotificationRoute(
                method: .warning,
                itemID: "\(CodexAppServerNotificationMethod.warning.rawValue)-notice-item",
                isStreaming: false
            ))
        )
    }

}
