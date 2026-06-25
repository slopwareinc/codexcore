import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexChatTranscriptTests: XCTestCase {
    func testTranscriptTimelineInsertsOperationAggregateBeforeConsecutiveOperationMessages() throws {
        let start = Date(timeIntervalSince1970: 100)
        let messages = [
            CodexChatMessage(role: .user, text: "Inspect and test", createdAt: start),
            commandMessage("ls", createdAt: start.addingTimeInterval(1)),
            readMessage("README.md", createdAt: start.addingTimeInterval(2)),
            fileChangeMessage(path: "README.md", added: 2, removed: 1, createdAt: start.addingTimeInterval(3)),
            commandMessage("npm test", duration: "1s", createdAt: start.addingTimeInterval(4)),
            CodexChatMessage(role: .assistant, text: "Done.", createdAt: start.addingTimeInterval(5))
        ]

        let timeline = CodexTranscriptTimelineBuilder.build(messages: messages, lifecycleEvents: [])

        let aggregateIndex = try XCTUnwrap(timeline.firstIndex { item in
            if case .operationAggregate = item { return true }
            return false
        })
        guard case .operationAggregate(_, let rows) = timeline[aggregateIndex] else {
            return XCTFail("Expected operation aggregate item")
        }
        let operationMessageIndices = timeline.indices.filter { index in
            if case .message(let message) = timeline[index], [.terminal, .tool, .fileChange].contains(message.role) {
                return true
            }
            return false
        }

        XCTAssertEqual(rows.map(\.title), [
            "Listed files",
            "Read 1 file",
            "Edited 1 file",
            "Ran npm test for 1s"
        ])
        XCTAssertEqual(operationMessageIndices.count, 4)
        XCTAssertLessThan(aggregateIndex, try XCTUnwrap(operationMessageIndices.first))
    }

    func testTranscriptTimelineDoesNotAggregateSingleOperationMessage() {
        let start = Date(timeIntervalSince1970: 100)
        let messages = [
            CodexChatMessage(role: .user, text: "Run status", createdAt: start),
            commandMessage("git status --short", createdAt: start.addingTimeInterval(1))
        ]

        let timeline = CodexTranscriptTimelineBuilder.build(messages: messages, lifecycleEvents: [])

        XCTAssertFalse(timeline.contains { item in
            if case .operationAggregate = item { return true }
            return false
        })
    }

    func testTranscriptTimelineInsertsAggregateBeforeConsecutiveFileChanges() throws {
        let start = Date(timeIntervalSince1970: 100)
        let messages = [
            CodexChatMessage(role: .user, text: "Update files", createdAt: start),
            fileChangeMessage(path: "README.md", added: 2, removed: 1, createdAt: start.addingTimeInterval(1)),
            fileChangeMessage(path: "Sources/App.swift", added: 4, removed: 0, createdAt: start.addingTimeInterval(2)),
            CodexChatMessage(role: .assistant, text: "Done.", createdAt: start.addingTimeInterval(3))
        ]

        let timeline = CodexTranscriptTimelineBuilder.build(messages: messages, lifecycleEvents: [])

        let aggregateIndex = try XCTUnwrap(timeline.firstIndex { item in
            if case .fileChangeAggregate = item { return true }
            return false
        })
        let fileMessageIndices = timeline.indices.filter { index in
            if case .message(let message) = timeline[index], message.role == .fileChange { return true }
            return false
        }
        guard case .fileChangeAggregate(_, let changes) = timeline[aggregateIndex] else {
            return XCTFail("Expected aggregate file-change item")
        }

        XCTAssertEqual(changes.map(\.path), ["README.md", "Sources/App.swift"])
        XCTAssertEqual(fileMessageIndices.count, 2)
        XCTAssertLessThan(aggregateIndex, try XCTUnwrap(fileMessageIndices.first))
    }

    func testTranscriptTimelineDoesNotAggregateSingleFileChange() {
        let start = Date(timeIntervalSince1970: 100)
        let messages = [
            CodexChatMessage(role: .user, text: "Update one file", createdAt: start),
            fileChangeMessage(path: "README.md", added: 2, removed: 1, createdAt: start.addingTimeInterval(1))
        ]

        let timeline = CodexTranscriptTimelineBuilder.build(messages: messages, lifecycleEvents: [])

        XCTAssertFalse(timeline.contains { item in
            if case .fileChangeAggregate = item { return true }
            return false
        })
        XCTAssertEqual(timeline.filter {
            if case .message(let message) = $0, message.role == .fileChange { return true }
            return false
        }.count, 1)
    }

    func testTranscriptTimelineCapsAssistantLifecycleGroupsForLazyScrolling() {
        let start = Date(timeIntervalSince1970: 100)
        let messages = (0..<8).map { index in
            CodexChatMessage(
                role: .assistant,
                text: "Assistant message \(index)",
                createdAt: start.addingTimeInterval(Double(index * 4))
            )
        }
        let events = (0..<40).map { index in
            CodexAgentLifecycleEvent(
                status: index == 39 ? .completed : .running,
                title: "Lifecycle \(index)",
                agentNames: ["Agent \(index % 3)"],
                createdAt: start.addingTimeInterval(Double(index))
            )
        }

        let timeline = CodexTranscriptTimelineBuilder.build(messages: messages, lifecycleEvents: events)
        let assistantHeaders = timeline.filter {
            if case .assistantTurnHeader = $0 { return true }
            return false
        }
        let lifecycleGroups = timeline.compactMap {
            if case .assistantLifecycle(_, let events) = $0 { return events }
            return nil
        }
        let assistantBlocks = timeline.filter {
            if case .assistantBlock = $0 { return true }
            return false
        }

        XCTAssertGreaterThan(lifecycleGroups.count, 1)
        XCTAssertEqual(assistantHeaders.count, messages.count)
        XCTAssertEqual(assistantBlocks.count, messages.count)
        XCTAssertEqual(lifecycleGroups.reduce(0) { $0 + $1.count }, events.count)
        XCTAssertTrue(lifecycleGroups.allSatisfy { $0.count <= CodexTranscriptTimelineBuilder.maxGroupedLifecycleEvents })
    }

    func testLargeTranscriptTimelinePreservesBoundedGroupingAndAggregates() {
        let fixture = largeTranscriptFixture(turnCount: 80)

        let timeline = CodexTranscriptTimelineBuilder.build(messages: fixture.messages, lifecycleEvents: fixture.lifecycleEvents)
        let assistantHeaders = timeline.filter {
            if case .assistantTurnHeader = $0 { return true }
            return false
        }
        let assistantBlocks = timeline.filter {
            if case .assistantBlock = $0 { return true }
            return false
        }
        let lifecycleGroups = timeline.compactMap {
            if case .assistantLifecycle(_, let events) = $0 { return events }
            return nil
        }
        let operationAggregates = timeline.filter {
            if case .operationAggregate = $0 { return true }
            return false
        }
        let fileChangeAggregates = timeline.filter {
            if case .fileChangeAggregate = $0 { return true }
            return false
        }
        let detailedMessages = timeline.filter {
            if case .message = $0 { return true }
            return false
        }

        XCTAssertEqual(fixture.messages.count, 480)
        XCTAssertEqual(fixture.lifecycleEvents.count, 240)
        XCTAssertEqual(assistantHeaders.count, fixture.turnCount)
        XCTAssertEqual(assistantBlocks.count, fixture.turnCount)
        XCTAssertEqual(operationAggregates.count, fixture.turnCount)
        XCTAssertEqual(fileChangeAggregates.count, fixture.turnCount)
        XCTAssertEqual(detailedMessages.count, fixture.turnCount * 5)
        XCTAssertEqual(lifecycleGroups.reduce(0) { $0 + $1.count }, fixture.lifecycleEvents.count)
        XCTAssertTrue(lifecycleGroups.allSatisfy { $0.count <= CodexTranscriptTimelineBuilder.maxGroupedLifecycleEvents })
        XCTAssertLessThanOrEqual(timeline.count, fixture.messages.count + fixture.lifecycleEvents.count + fixture.turnCount * 4)
    }

    func testChatTranscriptProjectionMapsRawItemsThroughTimelineMapper() throws {
        let commandValue: CodexJSONValue = .dictionary([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .array([.string("swift"), .string("test")]),
            "aggregatedOutput": .string("ok\n"),
            "status": .string("completed"),
            "exitCode": .int(0)
        ])
        let fileValue: CodexJSONValue = .dictionary([
            "id": .string("patch-1"),
            "type": .string("fileChange"),
            "changes": .array([
                .dictionary([
                    "path": .string("Sources/App.swift"),
                    "kind": .dictionary(["type": .string("update")]),
                    "diff": .string("+new")
                ])
            ])
        ])
        let toolValue: CodexJSONValue = .dictionary([
            "id": .string("tool-1"),
            "type": .string("mcpToolCall"),
            "server": .string("filesystem"),
            "tool": .string("read_file"),
            "result": .dictionary([
                "content": .array([
                    .dictionary(["type": .string("text"), "text": .string("package contents")])
                ])
            ])
        ])

        let command = try commandValue.decode(ThreadItem.self)
        let file = try fileValue.decode(ThreadItem.self)
        let tool = try toolValue.decode(ThreadItem.self)

        XCTAssertEqual(CodexChatTranscriptProjection.message(for: command, fallbackStatus: "completed")?.commandRun?.command, "swift test")
        XCTAssertEqual(CodexChatTranscriptProjection.message(for: command, fallbackStatus: "completed")?.commandRun?.output, "ok\n")
        XCTAssertEqual(CodexChatTranscriptProjection.message(for: file, fallbackStatus: "completed")?.fileChange?.path, "Sources/App.swift")
        XCTAssertEqual(CodexChatTranscriptProjection.message(for: tool, fallbackStatus: "completed")?.toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(CodexChatTranscriptProjection.message(for: tool, fallbackStatus: "completed")?.toolCall?.result, "package contents")
    }

    func testChatTranscriptProjectionMapsStoreTurnSnapshots() throws {
        let timestamp = Date(timeIntervalSince1970: 42)
        let turn = CodexTurnSnapshot(
            id: "turn-1",
            items: [
                .userMessage(id: "user-1", text: "Run the tests", timestamp: timestamp),
                .assistantMessage(id: "assistant-1", text: "On it.", timestamp: timestamp, isStreaming: false),
                .commandExecution(id: "cmd-1", command: "placeholder", output: "", status: "completed", timestamp: timestamp),
                .fileChange(id: "file-1", path: "", patch: "", status: "completed", timestamp: timestamp),
                .mcpToolCall(id: "tool-1", server: "", tool: "", status: "completed", timestamp: timestamp, progress: [])
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test",
                    cwd: "/repo",
                    output: "ok\n",
                    status: "completed",
                    exitCode: 0
                )),
                "file-1": .fileChange(CodexFileChangeDetail(
                    path: "Sources/App.swift",
                    kind: "update",
                    diff: "+new",
                    status: "completed"
                )),
                "tool-1": .toolCall(CodexToolCallDetail(
                    server: "filesystem",
                    tool: "read_file",
                    status: "completed",
                    result: "package contents"
                ))
            ],
            plan: [
                TurnPlanStep(step: "Inspect store", status: .completed),
                TurnPlanStep(step: "Wire projection", status: .inProgress)
            ],
            planExplanation: "Use store snapshots",
            diff: "diff --git a/Sources/App.swift b/Sources/App.swift\n+new"
        )

        let messages = CodexChatTranscriptProjection.messages(for: turn)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .terminal, .fileChange, .tool, .plan, .fileChange])
        XCTAssertEqual(messages[2].commandRun?.command, "swift test")
        XCTAssertEqual(messages[2].commandRun?.cwd, "/repo")
        XCTAssertEqual(messages[2].commandRun?.output, "ok\n")
        XCTAssertEqual(messages[2].commandRun?.exitCode, 0)
        XCTAssertEqual(messages[3].fileChange?.path, "Sources/App.swift")
        XCTAssertEqual(messages[4].toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(messages[4].toolCall?.result, "package contents")
        XCTAssertEqual(messages[5].planUpdate?.summary, "1/2 complete")
        XCTAssertEqual(messages[6].fileChange?.itemID, "turn-diff-turn-1")
        XCTAssertEqual(messages[6].fileChange?.diff, "diff --git a/Sources/App.swift b/Sources/App.swift\n+new")
    }

    func testChatTranscriptStateOwnsLiveMessageIdentityAndMerging() throws {
        let startedCommandValue: CodexJSONValue = .dictionary([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .array([.string("swift"), .string("test")]),
            "status": .string("active")
        ])
        let completedCommandValue: CodexJSONValue = .dictionary([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .array([.string("swift"), .string("test")]),
            "status": .string("completed"),
            "exitCode": .int(0)
        ])

        var transcript = CodexChatTranscriptState()
        transcript.appendAssistantDelta("Hel", itemID: "assistant-1")
        transcript.appendAssistantDelta("lo", itemID: "assistant-1")
        transcript.startItem(try startedCommandValue.decode(ThreadItem.self))
        transcript.appendCommandOutput("ok", itemID: "cmd-1")
        transcript.completeItem(try completedCommandValue.decode(ThreadItem.self))

        XCTAssertEqual(transcript.messages.map(\.role), [.assistant, .terminal])
        XCTAssertEqual(transcript.messages[0].text, "Hello")
        XCTAssertEqual(transcript.messages[1].commandRun?.command, "swift test")
        XCTAssertEqual(transcript.messages[1].commandRun?.output, "ok")
        XCTAssertEqual(transcript.messages[1].commandRun?.exitCode, 0)
    }

    func testChatTranscriptNotificationRouterOwnsLiveCommandAndAssistantRouting() throws {
        let startedCommand = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .array([.string("swift"), .string("test")]),
            "status": .string("active")
        ])
        let completedCommand = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .array([.string("swift"), .string("test")]),
            "status": .string("completed"),
            "exitCode": .int(0)
        ])
        let completedAssistant = try transcriptThreadItem([
            "id": .string("assistant-1"),
            "type": .string("assistantMessage"),
            "text": .string("Hello from Codex"),
            "phase": .string("final_answer")
        ])

        var transcript = CodexChatTranscriptState()
        let commandStart = routeTranscriptNotification(
            .itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: startedCommand)),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .itemCommandExecutionOutputDelta, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "delta": .string("ok\n")
            ]),
            to: &transcript
        )
        routeTranscriptNotification(
            .itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: completedCommand)),
            to: &transcript
        )
        routeTranscriptNotification(
            .agentMessageDelta(AgentMessageDeltaNotification(threadId: "thread-1", turnId: "turn-1", itemId: "assistant-1", delta: "Hel")),
            to: &transcript
        )
        routeTranscriptNotification(
            .agentMessageDelta(AgentMessageDeltaNotification(threadId: "thread-1", turnId: "turn-1", itemId: "assistant-1", delta: "lo")),
            to: &transcript
        )
        let assistantCompletion = routeTranscriptNotification(
            .itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: completedAssistant)),
            to: &transcript
        )

        XCTAssertEqual(commandStart?.activity?.title, "Ran a command")
        XCTAssertEqual(transcript.messages.map(\.role), [.terminal, .assistant])
        XCTAssertEqual(transcript.messages[0].commandRun?.command, "swift test")
        XCTAssertEqual(transcript.messages[0].commandRun?.output, "ok\n")
        XCTAssertEqual(transcript.messages[0].commandRun?.exitCode, 0)
        XCTAssertEqual(transcript.messages[0].isStreaming, false)
        XCTAssertEqual(transcript.messages[1].text, "Hello from Codex")
        XCTAssertEqual(transcript.messages[1].isStreaming, false)
        XCTAssertEqual(assistantCompletion?.completedAssistantText, "Hello from Codex")
    }

    func testChatTranscriptNotificationRouterMapsPlanDiffPatchNoticeAndToolEvents() throws {
        let startedTool = try transcriptThreadItem([
            "id": .string("tool-1"),
            "type": .string("mcpToolCall"),
            "server": .string("filesystem"),
            "tool": .string("read_file"),
            "status": .string("inProgress")
        ])
        let completedTool = try transcriptThreadItem([
            "id": .string("tool-1"),
            "type": .string("mcpToolCall"),
            "server": .string("filesystem"),
            "tool": .string("read_file"),
            "status": .string("completed"),
            "result": .dictionary([
                "content": .array([
                    .dictionary(["type": .string("text"), "text": .string("package contents")])
                ])
            ])
        ])

        var transcript = CodexChatTranscriptState()
        routeTranscriptNotification(
            .known(method: .turnPlanUpdated, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "explanation": .string("Inspect, edit, verify."),
                "plan": .array([
                    .dictionary(["step": .string("Inspect"), "status": .string("completed")]),
                    .dictionary(["step": .string("Verify"), "status": .string("inProgress")])
                ])
            ]),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1")
        )
        routeTranscriptNotification(
            .known(method: .turnDiffUpdated, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "diff": .string("diff --git a/A.swift b/A.swift\n+new")
            ]),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1")
        )
        routeTranscriptNotification(
            .known(method: .itemFileChangePatchUpdated, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("patch-1"),
                "changes": .array([
                    .dictionary([
                        "path": .string("Sources/App.swift"),
                        "kind": .dictionary(["type": .string("update")]),
                        "diff": .string("+new")
                    ])
                ])
            ]),
            to: &transcript
        )
        routeTranscriptNotification(
            .itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: startedTool)),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .itemMCPToolCallProgress, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("tool-1"),
                "message": .string("Reading Package.swift")
            ]),
            to: &transcript
        )
        routeTranscriptNotification(
            .itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: completedTool)),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .warning, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "message": .string("Model changed behavior")
            ]),
            to: &transcript
        )

        XCTAssertEqual(transcript.messages.map(\.role), [.plan, .fileChange, .fileChange, .tool, .notice])
        XCTAssertEqual(transcript.messages[0].planUpdate?.summary, "1/2 complete")
        XCTAssertEqual(transcript.messages[1].fileChange?.itemID, "turn-diff-turn-1")
        XCTAssertEqual(transcript.messages[2].fileChange?.path, "Sources/App.swift")
        XCTAssertEqual(transcript.messages[3].toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(transcript.messages[3].toolCall?.progress, ["Reading Package.swift"])
        XCTAssertEqual(transcript.messages[3].toolCall?.result, "package contents")
        XCTAssertEqual(transcript.messages[4].notice?.title, "Warning")
        XCTAssertEqual(transcript.messages[4].notice?.detail, "Model changed behavior")
    }

    func testChatTranscriptNotificationRouterPrefersStoreSnapshotForTypedTurnChrome() throws {
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            plan: [
                TurnPlanStep(step: "Store-owned step", status: .inProgress)
            ],
            planExplanation: "From store",
            diff: "diff --git a/Store.swift b/Store.swift\n+store"
        )

        var transcript = CodexChatTranscriptState()
        routeTranscriptNotification(
            .turnPlanUpdated(TurnPlanUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                plan: [TurnPlanStep(step: "Payload-only step", status: .pending)],
                explanation: "From payload"
            )),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1", turnSnapshot: storeTurn)
        )
        routeTranscriptNotification(
            .turnDiffUpdated(TurnDiffUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                diff: "diff --git a/Payload.swift b/Payload.swift\n+payload"
            )),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1", turnSnapshot: storeTurn)
        )

        XCTAssertEqual(transcript.messages.map(\.role), [.plan, .fileChange])
        XCTAssertEqual(transcript.messages[0].planUpdate?.steps.first?.step, "Store-owned step")
        XCTAssertEqual(transcript.messages[0].planUpdate?.explanation, "From store")
        XCTAssertEqual(transcript.messages[1].fileChange?.diff, "diff --git a/Store.swift b/Store.swift\n+store")
    }

    func testChatTranscriptNotificationRouterPrefersStoreSnapshotForCompletedItems() throws {
        let timestamp = Date(timeIntervalSince1970: 123)
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            items: [
                .commandExecution(id: "cmd-1", command: "store placeholder", output: "", status: "completed", timestamp: timestamp)
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test",
                    cwd: "/repo",
                    output: "store output\n",
                    status: "completed",
                    exitCode: 0
                ))
            ]
        )
        let payloadItem = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("payload command"),
            "output": .string("payload output"),
            "status": .string("completed")
        ])

        var transcript = CodexChatTranscriptState()
        routeTranscriptNotification(
            .itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: payloadItem)),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1", turnSnapshot: storeTurn)
        )

        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages[0].commandRun?.command, "swift test")
        XCTAssertEqual(transcript.messages[0].commandRun?.cwd, "/repo")
        XCTAssertEqual(transcript.messages[0].commandRun?.output, "store output\n")
        XCTAssertEqual(transcript.messages[0].commandRun?.exitCode, 0)
    }

    func testChatTranscriptNotificationRouterPrefersStoreSnapshotForStartedItems() throws {
        let timestamp = Date(timeIntervalSince1970: 456)
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            items: [
                .commandExecution(id: "cmd-1", command: "store placeholder", output: "", status: "active", timestamp: timestamp)
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test --filter StoreBacked",
                    cwd: "/repo",
                    output: "",
                    status: "active"
                ))
            ]
        )
        let payloadItem = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("payload command"),
            "status": .string("inProgress")
        ])

        var transcript = CodexChatTranscriptState()
        let result = routeTranscriptNotification(
            .itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: payloadItem)),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activeTurnID: "turn-1", turnSnapshot: storeTurn)
        )

        XCTAssertEqual(result?.activity?.detail, "swift test --filter StoreBacked")
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages[0].commandRun?.command, "swift test --filter StoreBacked")
        XCTAssertEqual(transcript.messages[0].commandRun?.cwd, "/repo")
        XCTAssertTrue(transcript.messages[0].commandRun?.isStreaming == true)
    }

    func testChatTranscriptNotificationRouterPrefersStoreSnapshotForKnownLiveItems() {
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            items: [
                .commandExecution(
                    id: "cmd-1",
                    command: "swift test",
                    output: "store command output",
                    status: "active",
                    timestamp: Date()
                ),
                .fileChange(
                    id: "patch-1",
                    path: "Sources/Store.swift",
                    patch: "diff --git a/Sources/Store.swift b/Sources/Store.swift\n+store",
                    status: "active",
                    timestamp: Date()
                ),
                .mcpToolCall(
                    id: "tool-1",
                    server: "filesystem",
                    tool: "read_file",
                    status: "inProgress",
                    timestamp: Date(),
                    progress: ["store progress"]
                ),
                .assistantMessage(
                    id: "assistant-1",
                    text: "store assistant text",
                    timestamp: Date(),
                    isStreaming: true
                )
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test",
                    output: "store command output",
                    status: "active"
                )),
                "patch-1": .fileChange(CodexFileChangeDetail(
                    path: "Sources/Store.swift",
                    kind: "update",
                    diff: "diff --git a/Sources/Store.swift b/Sources/Store.swift\n+store",
                    output: "",
                    status: "active"
                )),
                "tool-1": .toolCall(CodexToolCallDetail(
                    server: "filesystem",
                    tool: "read_file",
                    status: "inProgress",
                    progress: ["store progress"]
                )),
                "assistant-1": .assistantMessage(CodexAssistantMessageDetail(
                    phase: "commentary"
                ))
            ]
        )

        var transcript = CodexChatTranscriptState()
        let context = CodexChatTranscriptRouteContext(activeTurnID: "turn-1", turnSnapshot: storeTurn)
        routeTranscriptNotification(
            .known(method: .itemCommandExecutionOutputDelta, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "delta": .string("raw command output")
            ]),
            to: &transcript,
            context: context
        )
        let patchActivity = routeTranscriptNotification(
            .known(method: .itemFileChangePatchUpdated, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("patch-1"),
                "path": .string("Payload.swift"),
                "diff": .string("+payload")
            ]),
            to: &transcript,
            context: context
        )
        routeTranscriptNotification(
            .known(method: .itemMCPToolCallProgress, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("tool-1"),
                "message": .string("payload progress")
            ]),
            to: &transcript,
            context: context
        )
        routeTranscriptNotification(
            .agentMessageDelta(AgentMessageDeltaNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                itemId: "assistant-1",
                delta: "payload assistant text"
            )),
            to: &transcript,
            context: context
        )

        XCTAssertEqual(transcript.messages.map(\.role), [.terminal, .fileChange, .tool, .assistant])
        XCTAssertEqual(transcript.messages[0].commandRun?.output, "store command output")
        XCTAssertEqual(transcript.messages[1].fileChange?.displayPath, "Sources/Store.swift")
        XCTAssertEqual(transcript.messages[1].fileChange?.diff, "diff --git a/Sources/Store.swift b/Sources/Store.swift\n+store")
        XCTAssertEqual(patchActivity?.activity?.detail, "Sources/Store.swift")
        XCTAssertEqual(transcript.messages[2].toolCall?.progress, ["store progress"])
        XCTAssertEqual(transcript.messages[3].text, "store assistant text")
        XCTAssertEqual(transcript.messages[3].detail, "commentary")
    }

    func testChatTranscriptNotificationRouterLetsSideChatIgnoreMainTurnDiffs() {
        var transcript = CodexChatTranscriptState()
        let result = routeTranscriptNotification(
            .known(method: .turnDiffUpdated, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "diff": .string("diff --git a/A.swift b/A.swift\n+new")
            ]),
            to: &transcript,
            context: CodexChatTranscriptRouteContext(activityPrefix: "Side chat", activeTurnID: "turn-1", includesTurnDiff: false)
        )

        XCTAssertNil(result)
        XCTAssertTrue(transcript.messages.isEmpty)
    }

    func testChatTranscriptSessionKeepsTranscriptAndTurnChromeStoreBacked() {
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            plan: [
                TurnPlanStep(step: "Use the store", status: .inProgress)
            ],
            planExplanation: "Canonical state",
            diff: "diff --git a/Store.swift b/Store.swift\n+store"
        )

        var session = CodexChatTranscriptSession()
        session.apply(
            transcriptNotification(.turnPlanUpdated(TurnPlanUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                plan: [TurnPlanStep(step: "Use payload", status: .pending)],
                explanation: "Payload state"
            ))),
            activeTurnID: "turn-1",
            turnSnapshot: storeTurn
        )
        session.apply(
            transcriptNotification(.turnDiffUpdated(TurnDiffUpdatedNotification(
                threadId: "thread-1",
                turnId: "turn-1",
                diff: "diff --git a/Payload.swift b/Payload.swift\n+payload"
            ))),
            activeTurnID: "turn-1",
            turnSnapshot: storeTurn
        )

        XCTAssertEqual(session.currentPlan.map(\.step), ["Use the store"])
        XCTAssertEqual(session.currentPlanExplanation, "Canonical state")
        XCTAssertEqual(session.currentDiff, "diff --git a/Store.swift b/Store.swift\n+store")
        XCTAssertEqual(session.messages.map(\.role), [.plan, .fileChange])
        XCTAssertEqual(session.messages[0].planUpdate?.steps.first?.step, "Use the store")
        XCTAssertEqual(session.messages[1].fileChange?.diff, "diff --git a/Store.swift b/Store.swift\n+store")

        XCTAssertTrue(session.syncTurnChrome(from: nil, resetWhenMissing: true))
        XCTAssertTrue(session.currentPlan.isEmpty)
        XCTAssertNil(session.currentPlanExplanation)
        XCTAssertNil(session.currentDiff)
    }

    func testChatTranscriptSessionPrefersStoreSnapshotForCompletedItems() throws {
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            status: .running,
            items: [
                .commandExecution(id: "cmd-1", command: "placeholder", output: "", status: "completed", timestamp: Date(timeIntervalSince1970: 123))
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test",
                    cwd: "/repo",
                    output: "store output\n",
                    status: "completed",
                    exitCode: 0
                ))
            ]
        )
        let payloadItem = try transcriptThreadItem([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("payload command"),
            "output": .string("payload output"),
            "status": .string("completed")
        ])

        var session = CodexChatTranscriptSession()
        session.apply(
            transcriptNotification(.itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: payloadItem))),
            activeTurnID: "turn-1",
            turnSnapshot: storeTurn
        )

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].commandRun?.command, "swift test")
        XCTAssertEqual(session.messages[0].commandRun?.cwd, "/repo")
        XCTAssertEqual(session.messages[0].commandRun?.output, "store output\n")
    }

    func testReasoningAndCommandStreamingRoutesIntoTranscript() throws {
        let startedReasoning = try transcriptThreadItem([
            "id": .string("reason-1"),
            "type": .string("reasoning"),
            "text": .string(""),
            "status": .string("inProgress")
        ])
        let completedReasoning = try transcriptThreadItem([
            "id": .string("reason-1"),
            "type": .string("reasoning"),
            "text": .string("Need to inspect the failing test first."),
            "status": .string("completed")
        ])

        var transcript = CodexChatTranscriptState()
        routeTranscriptNotification(
            .itemStarted(ItemStartedNotification(threadId: "thread-1", turnId: "turn-1", item: startedReasoning)),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .itemReasoningTextDelta, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("reason-1"),
                "delta": .string("Need to inspect")
            ]),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .itemReasoningSummaryTextDelta, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("reason-1"),
                "delta": .string(" the failing test.")
            ]),
            to: &transcript
        )
        routeTranscriptNotification(
            .itemCompleted(ItemCompletedNotification(threadId: "thread-1", turnId: "turn-1", item: completedReasoning)),
            to: &transcript
        )
        routeTranscriptNotification(
            .known(method: .itemCommandExecutionOutputDelta, params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "delta": .string("Build succeeded\n")
            ]),
            to: &transcript
        )

        XCTAssertEqual(transcript.messages.map(\.role), [.reasoning, .terminal])
        XCTAssertEqual(transcript.messages[0].reasoningBlock?.text, "Need to inspect the failing test first.")
        XCTAssertEqual(transcript.messages[0].reasoningBlock?.isSummary, true)
        XCTAssertEqual(transcript.messages[0].reasoningBlock?.isStreaming, false)
        XCTAssertEqual(transcript.messages[1].commandRun?.output, "Build succeeded\n")
        XCTAssertTrue(transcript.messages[1].commandRun?.isStreaming == true)
    }

    private func fileChangeMessage(path: String, added: Int, removed: Int, createdAt: Date) -> CodexChatMessage {
        CodexChatMessage(
            role: .fileChange,
            text: path,
            createdAt: createdAt,
            fileChange: CodexChatMessage.fileChange(
                itemID: path,
                path: path,
                diff: diff(path: path, added: added, removed: removed),
                kind: "update",
                status: "completed",
                isStreaming: false
            )
        )
    }

    private func commandMessage(_ command: String, duration: String? = nil, createdAt: Date) -> CodexChatMessage {
        CodexChatMessage(
            role: .terminal,
            text: command,
            createdAt: createdAt,
            commandRun: CodexChatMessage.CommandRun(
                itemID: command,
                command: command,
                output: duration.map { "duration=\($0)" } ?? "",
                status: "completed",
                exitCode: 0,
                isStreaming: false
            )
        )
    }

    private func readMessage(_ path: String, createdAt: Date) -> CodexChatMessage {
        CodexChatMessage(
            role: .tool,
            text: "Read \(path)",
            createdAt: createdAt,
            toolCall: CodexChatMessage.ToolCall(
                itemID: path,
                server: "filesystem",
                tool: "read_file",
                progress: ["Read \(path)"],
                result: path,
                isStreaming: false
            )
        )
    }

    private func largeTranscriptFixture(turnCount: Int) -> (turnCount: Int, messages: [CodexChatMessage], lifecycleEvents: [CodexAgentLifecycleEvent]) {
        let start = Date(timeIntervalSince1970: 1_000)
        var messages: [CodexChatMessage] = []
        var lifecycleEvents: [CodexAgentLifecycleEvent] = []

        for turn in 0..<turnCount {
            let base = start.addingTimeInterval(Double(turn * 20))
            messages.append(CodexChatMessage(role: .user, text: "Turn \(turn)", createdAt: base))
            messages.append(commandMessage("swift test --filter Turn\(turn)", duration: "1s", createdAt: base.addingTimeInterval(1)))
            messages.append(readMessage("Sources/File\(turn).swift", createdAt: base.addingTimeInterval(2)))
            messages.append(fileChangeMessage(path: "Sources/File\(turn).swift", added: 2, removed: 1, createdAt: base.addingTimeInterval(3)))
            messages.append(fileChangeMessage(path: "Tests/File\(turn)Tests.swift", added: 3, removed: 0, createdAt: base.addingTimeInterval(4)))
            messages.append(CodexChatMessage(role: .assistant, text: "Completed turn \(turn).", createdAt: base.addingTimeInterval(10)))

            for eventOffset in 0..<3 {
                lifecycleEvents.append(CodexAgentLifecycleEvent(
                    status: eventOffset == 2 ? .completed : .running,
                    title: "Turn \(turn) lifecycle \(eventOffset)",
                    agentNames: ["Agent \(eventOffset)"],
                    createdAt: base.addingTimeInterval(Double(5 + eventOffset))
                ))
            }
        }

        return (turnCount, messages, lifecycleEvents)
    }

    private func diff(path: String, added: Int, removed: Int) -> String {
        var lines = [
            "diff --git a/\(path) b/\(path)",
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -1 +1 @@"
        ]
        lines.append(contentsOf: Array(repeating: "-old", count: removed))
        lines.append(contentsOf: Array(repeating: "+new", count: added))
        return lines.joined(separator: "\n")
    }
}
