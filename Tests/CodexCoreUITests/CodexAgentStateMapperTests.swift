import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexAgentStateMapperTests: XCTestCase {
    func testStartsAgentsFromRawSpawnArray() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "spawn-1",
          "type": "subAgentThreadSpawn",
          "text": "Created Chandrasekhar and Copernicus",
          "summary": "Created two side agents",
          "agents": [
            {
              "id": "agent-chandrasekhar",
              "name": "Chandrasekhar",
              "title": "Chat and composer inspection",
              "prompt": "Inspect chat/composer UX"
            },
            {
              "id": "agent-copernicus",
              "name": "Copernicus",
              "title": "Side-panel inspection",
              "prompt": "Inspect side panel UX"
            }
          ]
        }
        """#)

        var mapper = CodexAgentStateMapper()
        let update = mapper.itemStarted(item)

        XCTAssertEqual(update?.activityTitle, "Subagents started")
        XCTAssertEqual(mapper.lifecycleEvents.last?.status, .spawning)
        XCTAssertEqual(mapper.lifecycleEvents.last?.agentNames, ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(mapper.sideChat?.title, "Side chat")
        XCTAssertEqual(mapper.subagents.map(\.name), ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(mapper.subagents.map(\.status), [.running, .running])
        XCTAssertEqual(mapper.subagents[0].messages.first?.text, "Inspect chat/composer UX")
    }

    func testCompletesAgentFromRawResultPayload() throws {
        let started = try decodeThreadItem(#"""
        {
          "id": "review-1",
          "type": "subAgentReview",
          "agentName": "Guardian",
          "prompt": "Review the current diff"
        }
        """#)
        let completed = try decodeThreadItem(#"""
        {
          "id": "review-1",
          "type": "subAgentReview",
          "agentName": "Guardian",
          "status": "closed",
          "prompt": "Review the current diff",
          "result": "No blocking issues found."
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemStarted(started)
        let update = mapper.itemCompleted(completed)

        XCTAssertEqual(update?.activityTitle, "Subagents closed")
        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].name, "Guardian")
        XCTAssertEqual(mapper.subagents[0].status, .closed)
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .assistant)
        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "No blocking issues found.")
        XCTAssertEqual(mapper.lifecycleEvents.last?.status, .closed)
    }

    func testFindsNestedSourceThreadMetadata() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "fork-1",
          "type": "threadFork",
          "text": "Spawned Kepler to inspect architecture",
          "source": {
            "kind": "subAgentThreadSpawn",
            "thread": {
              "id": "thread-kepler",
              "title": "Kepler",
              "prompt": "Inspect architecture boundaries"
            }
          }
        }
        """#)

        var mapper = CodexAgentStateMapper()
        XCTAssertTrue(mapper.isSubagentItem(item))

        mapper.itemStarted(item)

        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].id, "thread-kepler")
        XCTAssertEqual(mapper.subagents[0].name, "Kepler")
        XCTAssertEqual(mapper.subagents[0].prompt, "Inspect architecture boundaries")
    }

    func testDoesNotTreatPlainAssistantTextAsSubagentItem() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "assistant-1",
          "type": "assistantMessage",
          "text": "I can create a subagent if you want one."
        }
        """#)

        var mapper = CodexAgentStateMapper()

        XCTAssertFalse(mapper.isSubagentItem(item))
        XCTAssertNil(mapper.itemStarted(item))
    }

    func testMapsRealCollabAgentToolCallsIntoSubagentState() throws {
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Run a script that prints the integers 1 through 3.",
          "receiverThreadIds": ["thread-one"],
          "agentsStates": {
            "thread-one": { "status": "pendingInit", "message": null }
          },
          "status": "completed"
        }
        """#)
        let wait = try decodeThreadItem(#"""
        {
          "id": "call_wait",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "receiverThreadIds": ["thread-one"],
          "agentsStates": {
            "thread-one": {
              "status": "completed",
              "message": "Command ran:\n\n```text\n1\n2\n3\n```"
            }
          },
          "status": "completed"
        }
        """#)
        let close = try decodeThreadItem(#"""
        {
          "id": "call_close",
          "type": "collabAgentToolCall",
          "tool": "closeAgent",
          "receiverThreadIds": ["thread-one"],
          "agentsStates": {
            "thread-one": {
              "status": "completed",
              "message": "Command ran:\n\n```text\n1\n2\n3\n```"
            }
          },
          "status": "completed"
        }
        """#)

        var mapper = CodexAgentStateMapper()

        XCTAssertTrue(mapper.isSubagentItem(spawn))
        XCTAssertEqual(mapper.itemCompleted(spawn)?.activityTitle, "Subagents started")
        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].id, "thread-one")
        XCTAssertEqual(mapper.subagents[0].name, "Agent 1")
        XCTAssertEqual(mapper.subagents[0].status, .running)
        XCTAssertEqual(mapper.subagents[0].prompt, "Run a script that prints the integers 1 through 3.")
        XCTAssertEqual(mapper.sideChat?.title, "Side chat")

        XCTAssertEqual(mapper.itemCompleted(wait)?.activityTitle, "Subagents completed")
        XCTAssertEqual(mapper.subagents[0].status, .completed)
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .assistant)
        XCTAssertTrue(mapper.subagents[0].messages.last?.text.contains("1\n2\n3") ?? false)

        XCTAssertEqual(mapper.itemCompleted(close)?.activityTitle, "Subagents closed")
        XCTAssertEqual(mapper.subagents[0].status, .closed)
        XCTAssertEqual(mapper.lifecycleEvents.last?.status, .closed)
    }

    func testRenamesGenericAgentsFromCoordinatorStatusMessage() throws {
        let first = try decodeThreadItem(#"""
        {
          "id": "call_spawn_1",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Run first task.",
          "receiverThreadIds": ["thread-one"],
          "agentsStates": { "thread-one": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)
        let second = try decodeThreadItem(#"""
        {
          "id": "call_spawn_2",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Run second task.",
          "receiverThreadIds": ["thread-two"],
          "agentsStates": { "thread-two": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemCompleted(first)
        mapper.itemCompleted(second)

        XCTAssertTrue(mapper.assistantMessageCompleted("Both side agents are running now: Pasteur has `1..3`, Hilbert has `20..22`."))
        XCTAssertEqual(mapper.subagents.map(\.name), ["Pasteur", "Hilbert"])
        XCTAssertEqual(mapper.lifecycleEvents.map(\.title), ["Spawned Pasteur", "Spawned Hilbert"])
        XCTAssertEqual(mapper.lifecycleEvents.flatMap(\.agentNames), ["Pasteur", "Hilbert"])
    }

    func testAppliesThreadMetadataToExistingCollabAgent() throws {
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Inspect the side panel.",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemCompleted(spawn)

        XCTAssertEqual(mapper.subagents[0].name, "Agent 1")
        XCTAssertTrue(mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer"))
        XCTAssertEqual(mapper.subagents[0].name, "Robie [explorer]")
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Spawned Robie [explorer]")
        XCTAssertEqual(mapper.lifecycleEvents.last?.agentNames, ["Robie [explorer]"])
    }

    func testCachesThreadMetadataBeforeCollabAgentAppears() throws {
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Inspect the side panel.",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)

        var mapper = CodexAgentStateMapper()

        XCTAssertFalse(mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer"))
        mapper.itemCompleted(spawn)

        XCTAssertEqual(mapper.subagents[0].name, "Robie [explorer]")
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Spawned Robie [explorer]")
    }

    func testStartedWaitAddsOfficialStyleLifecycleRow() throws {
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Inspect the side panel.",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)
        let waitStarted = try decodeThreadItem(#"""
        {
          "id": "call_wait",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "running" } },
          "status": "inProgress"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer")
        mapper.itemCompleted(spawn)

        XCTAssertEqual(mapper.itemStarted(waitStarted)?.activityTitle, "Waiting on subagents")
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Waiting for Robie [explorer]")
        XCTAssertEqual(mapper.subagents[0].status, .running)
    }

    func testLateStartedWaitDoesNotRegressCompletedWait() throws {
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Inspect the side panel.",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)
        let waitCompleted = try decodeThreadItem(#"""
        {
          "id": "call_wait",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": {
            "thread-robie": {
              "status": "completed",
              "message": "```text\n1\n2\n3\n```"
            }
          },
          "status": "completed"
        }
        """#)
        let waitStarted = try decodeThreadItem(#"""
        {
          "id": "call_wait",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": {},
          "status": "inProgress"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer")
        mapper.itemCompleted(spawn)
        mapper.itemCompleted(waitCompleted)

        XCTAssertEqual(mapper.subagents[0].status, .completed)
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Finished waiting")
        XCTAssertNil(mapper.itemStarted(waitStarted))
        XCTAssertEqual(mapper.subagents[0].status, .completed)
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Finished waiting")
    }

    func testRoutesKnownItemDeltasIntoSubagentTranscript() throws {
        let started = try decodeThreadItem(#"""
        {
          "id": "delta-1",
          "type": "subAgentOther",
          "agentName": "Vega",
          "prompt": "Inspect streaming behavior"
        }
        """#)
        let completed = try decodeThreadItem(#"""
        {
          "id": "delta-1",
          "type": "subAgentOther",
          "agentName": "Vega",
          "status": "completed",
          "result": "Final streaming findings"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemStarted(started)

        XCTAssertTrue(mapper.messageDelta("Partial", itemID: "delta-1"))
        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Partial")
        XCTAssertTrue(mapper.subagents[0].messages.last?.isStreaming ?? false)
        XCTAssertFalse(mapper.messageDelta("Parent", itemID: "parent-message"))

        mapper.itemCompleted(completed)

        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Final streaming findings")
        XCTAssertFalse(mapper.subagents[0].messages.last?.isStreaming ?? true)
    }

    func testRoutesChildThreadAssistantEventsIntoMatchingSubagent() throws {
        let completedMessage = try decodeThreadItem(#"""
        {
          "id": "child-message-1",
          "type": "agentMessage",
          "text": "Final child answer."
        }
        """#)
        let spawn = try decodeThreadItem(#"""
        {
          "id": "call_spawn",
          "type": "collabAgentToolCall",
          "tool": "spawnAgent",
          "prompt": "Inspect the live child transcript.",
          "receiverThreadIds": ["thread-robie"],
          "agentsStates": { "thread-robie": { "status": "pendingInit" } },
          "status": "completed"
        }
        """#)

        var mapper = CodexAgentStateMapper()

        XCTAssertFalse(mapper.subagentMessageDelta("Ignored", threadID: "unknown-thread", itemID: "child-message-1"))
        XCTAssertFalse(mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer"))
        XCTAssertTrue(mapper.hasSubagentThread(id: "thread-robie"))
        XCTAssertTrue(mapper.subagentMessageDelta("Partial", threadID: "thread-robie", itemID: "child-message-1"))
        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].name, "Robie [explorer]")
        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Partial")
        XCTAssertTrue(mapper.subagents[0].messages.last?.isStreaming ?? false)

        mapper.subagentItemCompleted(threadID: "thread-robie", item: completedMessage)

        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Final child answer.")
        XCTAssertFalse(mapper.subagents[0].messages.last?.isStreaming ?? true)
        XCTAssertEqual(mapper.subagents[0].status, .running)

        mapper.itemCompleted(spawn)

        XCTAssertEqual(mapper.subagents[0].prompt, "Inspect the live child transcript.")
        XCTAssertEqual(mapper.subagents[0].messages.first?.role, .user)
        XCTAssertEqual(mapper.subagents[0].messages.first?.text, "Inspect the live child transcript.")

        let update = mapper.subagentTurnCompleted(threadID: "thread-robie")

        XCTAssertEqual(update?.activityTitle, "Subagent completed")
        XCTAssertEqual(mapper.subagents[0].status, .completed)
        XCTAssertEqual(mapper.lifecycleEvents.last?.title, "Completed 1 agent")
        XCTAssertEqual(mapper.lifecycleEvents.last?.agentNames, ["Robie [explorer]"])
    }

    func testRoutesChildThreadCommandOutputIntoMatchingSubagent() throws {
        let commandStarted = try decodeThreadItem(#"""
        {
          "id": "child-command-1",
          "type": "commandExecution",
          "command": "printf '1\\n2\\n3\\n'",
          "cwd": "/tmp",
          "status": "active"
        }
        """#)
        let commandCompleted = try decodeThreadItem(#"""
        {
          "id": "child-command-1",
          "type": "commandExecution",
          "command": "printf '1\\n2\\n3\\n'",
          "cwd": "/tmp",
          "status": "completed",
          "aggregatedOutput": "1\n2\n3\n",
          "exitCode": 0
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "explorer")

        XCTAssertNotNil(mapper.subagentItemStarted(threadID: "thread-robie", item: commandStarted))
        XCTAssertTrue(mapper.subagentCommandOutputDelta("1\n", threadID: "thread-robie", itemID: "child-command-1"))
        XCTAssertTrue(mapper.subagentCommandOutputDelta("2\n", threadID: "thread-robie", itemID: "child-command-1"))
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .terminal)
        XCTAssertEqual(mapper.subagents[0].messages.last?.commandRun?.output, "1\n2\n")
        XCTAssertTrue(mapper.subagents[0].messages.last?.commandRun?.isStreaming ?? false)

        mapper.subagentItemCompleted(threadID: "thread-robie", item: commandCompleted)

        XCTAssertEqual(mapper.subagents[0].messages.last?.commandRun?.output, "1\n2\n3\n")
        XCTAssertEqual(mapper.subagents[0].messages.last?.commandRun?.status, "completed")
        XCTAssertEqual(mapper.subagents[0].messages.last?.commandRun?.exitCode, 0)
        XCTAssertFalse(mapper.subagents[0].messages.last?.commandRun?.isStreaming ?? true)
        XCTAssertFalse(mapper.subagents[0].messages.last?.isStreaming ?? true)
    }

    func testRoutesChildThreadFileChangeIntoMatchingSubagent() throws {
        let fileChangeStarted = try decodeThreadItem(#"""
        {
          "id": "child-file-1",
          "type": "fileChange",
          "path": "Sources/App.swift",
          "status": "active"
        }
        """#)
        let fileChangeCompleted = try decodeThreadItem(#"""
        {
          "id": "child-file-1",
          "type": "fileChange",
          "status": "completed",
          "changes": [
            {
              "path": "Sources/App.swift",
              "diff": "--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@\n-old\n+new\n",
              "kind": { "type": "update" }
            }
          ]
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "editor")

        XCTAssertNotNil(mapper.subagentItemStarted(threadID: "thread-robie", item: fileChangeStarted))
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .fileChange)
        XCTAssertEqual(mapper.subagents[0].messages.last?.fileChange?.displayPath, "Sources/App.swift")
        XCTAssertTrue(mapper.subagents[0].messages.last?.fileChange?.isStreaming ?? false)

        XCTAssertTrue(mapper.subagentFileChangeOutputDelta("applying patch\n", threadID: "thread-robie", itemID: "child-file-1"))
        let patchMessage = try XCTUnwrap(CodexChatTranscriptProjection.message(
            forRawItemID: "child-file-1",
            type: "fileChange",
            raw: [
                "threadId": .string("thread-robie"),
                "turnId": .string("child-turn-1"),
                "itemId": .string("child-file-1"),
                "changes": .array([
                    .dictionary([
                        "path": .string("Sources/App.swift"),
                        "diff": .string("--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@\n-old\n+new\n"),
                        "kind": .dictionary(["type": .string("update")])
                    ])
                ])
            ],
            fallbackStatus: "active"
        ))
        XCTAssertTrue(mapper.subagentProjectedItemUpdated(threadID: "thread-robie", itemID: "child-file-1", message: patchMessage))

        var streamedMessage = try XCTUnwrap(mapper.subagents[0].messages.last)
        XCTAssertEqual(streamedMessage.fileChange?.output, "applying patch\n")
        XCTAssertTrue(streamedMessage.fileChange?.diff.contains("+new") ?? false)
        XCTAssertEqual(streamedMessage.fileChange?.addedLineCount, 1)
        XCTAssertEqual(streamedMessage.fileChange?.removedLineCount, 1)

        mapper.subagentItemCompleted(threadID: "thread-robie", item: fileChangeCompleted)

        streamedMessage = try XCTUnwrap(mapper.subagents[0].messages.last)
        XCTAssertEqual(streamedMessage.fileChange?.status, "completed")
        XCTAssertEqual(streamedMessage.fileChange?.output, "applying patch\n")
        XCTAssertFalse(streamedMessage.fileChange?.isStreaming ?? true)
        XCTAssertFalse(streamedMessage.isStreaming)
    }

    func testRoutesChildThreadPlanUpdatesIntoMatchingSubagent() throws {
        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "planner")

        XCTAssertTrue(mapper.subagentPlanDelta("Initial plan text. ", threadID: "thread-robie", itemID: "child-plan-1"))
        XCTAssertTrue(mapper.subagentPlanDelta("More detail.", threadID: "thread-robie", itemID: "child-plan-1"))
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .plan)
        XCTAssertEqual(mapper.subagents[0].messages.last?.planUpdate?.text, "Initial plan text. More detail.")
        XCTAssertTrue(mapper.subagents[0].messages.last?.planUpdate?.isStreaming ?? false)

        let projectedPlan = try XCTUnwrap(CodexChatTranscriptProjection.turnPlanMessage(for: CodexTurnSnapshot(
            id: "child-turn-1",
            status: .running,
            plan: [
                TurnPlanStep(step: "Inspect files", status: .completed),
                TurnPlanStep(step: "Report findings", status: .inProgress)
            ],
            planExplanation: "Plan the child task."
        ))
        )
        XCTAssertTrue(mapper.subagentProjectedItemUpdated(
            threadID: "thread-robie",
            itemID: "turn-plan-child-turn-1",
            message: projectedPlan
        ))

        var planMessage = try XCTUnwrap(mapper.subagents[0].messages.last)
        XCTAssertEqual(planMessage.planUpdate?.explanation, "Plan the child task.")
        XCTAssertEqual(planMessage.planUpdate?.completedStepCount, 1)
        XCTAssertTrue(planMessage.planUpdate?.isStreaming ?? false)

        _ = mapper.subagentTurnCompleted(threadID: "thread-robie")

        planMessage = try XCTUnwrap(mapper.subagents[0].messages.last)
        XCTAssertFalse(planMessage.planUpdate?.isStreaming ?? true)
        XCTAssertFalse(planMessage.isStreaming)
    }

    func testRoutesChildThreadMCPToolProgressIntoMatchingSubagent() throws {
        let completedTool = try decodeThreadItem(#"""
        {
          "id": "child-mcp-1",
          "type": "mcpToolCall",
          "server": "filesystem",
          "tool": "read_file",
          "arguments": { "path": "Package.swift" },
          "status": "completed",
          "result": {
            "content": [
              { "type": "text", "text": "package contents" }
            ]
          },
          "durationMs": 12
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "researcher")

        XCTAssertTrue(mapper.subagentToolCallProgress("Reading Package.swift", threadID: "thread-robie", itemID: "child-mcp-1"))
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .tool)
        XCTAssertEqual(mapper.subagents[0].messages.last?.toolCall?.progress, ["Reading Package.swift"])
        XCTAssertTrue(mapper.subagents[0].messages.last?.toolCall?.isStreaming ?? false)

        mapper.subagentItemCompleted(threadID: "thread-robie", item: completedTool)

        let toolMessage = try XCTUnwrap(mapper.subagents[0].messages.last)
        XCTAssertEqual(toolMessage.toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(toolMessage.toolCall?.arguments, #"{"path":"Package.swift"}"#)
        XCTAssertEqual(toolMessage.toolCall?.progress, ["Reading Package.swift"])
        XCTAssertEqual(toolMessage.toolCall?.result, "package contents")
        XCTAssertEqual(toolMessage.toolCall?.durationMilliseconds, 12)
        XCTAssertFalse(toolMessage.toolCall?.isStreaming ?? true)
        XCTAssertFalse(toolMessage.isStreaming)
    }

    func testRoutesChildThreadNoticeIntoMatchingSubagent() throws {
        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "reviewer")

        let started = mapper.subagentNotice(
            method: .itemAutoApprovalReviewStarted,
            params: [
                "threadId": .string("thread-robie"),
                "turnId": .string("turn-child"),
                "reviewId": .string("auto-child"),
                "startedAtMs": .int(1_000),
                "targetItemId": .string("child-cmd"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("python3 script.py"),
                    "cwd": .string("/tmp/project"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("inProgress"),
                    "riskLevel": .string("medium"),
                    "rationale": .string("Reviewing child command.")
                ])
            ],
            threadID: "thread-robie",
            itemID: "review-auto-child",
            isStreaming: true
        )

        XCTAssertEqual(started?.activityTitle, "Auto review")
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .notice)
        XCTAssertEqual(mapper.subagents[0].messages.last?.notice?.detail, "python3 script.py")
        XCTAssertTrue(mapper.subagents[0].messages.last?.notice?.isStreaming ?? false)

        let completed = mapper.subagentNotice(
            method: .itemAutoApprovalReviewCompleted,
            params: [
                "threadId": .string("thread-robie"),
                "turnId": .string("turn-child"),
                "reviewId": .string("auto-child"),
                "startedAtMs": .int(1_000),
                "completedAtMs": .int(1_900),
                "decisionSource": .string("agent"),
                "targetItemId": .string("child-cmd"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("python3 script.py"),
                    "cwd": .string("/tmp/project"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("denied"),
                    "riskLevel": .string("medium"),
                    "rationale": .string("Command needs explicit confirmation.")
                ])
            ],
            threadID: "thread-robie",
            itemID: "review-auto-child",
            isStreaming: false
        )

        XCTAssertEqual(completed?.activityTitle, "Auto review denied")
        XCTAssertEqual(mapper.subagents[0].messages.filter { $0.role == .notice }.count, 1)
        XCTAssertEqual(mapper.subagents[0].messages.last?.notice?.status, "denied")
        XCTAssertEqual(mapper.subagents[0].messages.last?.notice?.severity, .danger)
        XCTAssertFalse(mapper.subagents[0].messages.last?.notice?.isStreaming ?? true)
    }

    func testAgentNotificationRouterRoutesChildThreadKnownNotifications() {
        var mapper = CodexAgentStateMapper()
        mapper.updateSubagentMetadata(id: "thread-robie", name: "Robie", role: "runner")

        let output = CodexAgentNotificationRouter.apply(
            agentNotification(.known(method: .itemCommandExecutionOutputDelta, params: [
                "threadId": .string("thread-robie"),
                "turnId": .string("turn-child"),
                "itemId": .string("cmd-child"),
                "delta": .string("1\n")
            ])),
            to: &mapper
        )
        let storeTurn = CodexTurnSnapshot(
            id: "turn-child",
            status: .running,
            items: [
                .commandExecution(
                    id: "cmd-store",
                    command: "python3 child.py",
                    output: "store terminal input",
                    status: "active",
                    timestamp: Date()
                )
            ],
            itemDetails: [
                "cmd-store": .commandExecution(CodexCommandExecutionDetail(
                    command: "python3 child.py",
                    output: "store terminal input",
                    status: "active"
                ))
            ]
        )
        let terminalInput = CodexAgentNotificationRouter.apply(
            agentNotification(.known(method: .itemCommandExecutionTerminalInteraction, params: [
                "threadId": .string("thread-robie"),
                "turnId": .string("turn-child"),
                "itemId": .string("cmd-store"),
                "stdin": .string("payload terminal input")
            ])),
            to: &mapper,
            turnSnapshot: { threadID, turnID in
                threadID == "thread-robie" && turnID == "turn-child" ? storeTurn : nil
            }
        )
        let warning = CodexAgentNotificationRouter.apply(
            agentNotification(.known(method: .warning, params: [
                "threadId": .string("thread-robie"),
                "turnId": .string("turn-child"),
                "message": .string("Child warning")
            ])),
            to: &mapper
        )
        let usage = CodexAgentNotificationRouter.apply(
            agentNotification(.threadTokenUsageUpdated(ThreadTokenUsageUpdatedNotification(
                threadId: "thread-robie",
                turnId: "turn-child",
                tokenUsage: ThreadTokenUsage(raw: [:])
            ))),
            to: &mapper
        )

        XCTAssertEqual(output?.didUpdateAgentState, true)
        XCTAssertNil(output?.activity)
        XCTAssertEqual(terminalInput?.didUpdateAgentState, true)
        XCTAssertNil(terminalInput?.activity)
        XCTAssertEqual(mapper.subagents[0].messages.first?.commandRun?.output, "1\n")
        XCTAssertEqual(
            mapper.subagents[0].messages.first(where: { $0.commandRun?.itemID == "cmd-store" })?.commandRun?.output,
            "store terminal input"
        )
        XCTAssertEqual(warning?.activity?.kind, .notice)
        XCTAssertEqual(warning?.activity?.title, "Warning")
        XCTAssertEqual(mapper.subagents[0].messages.last?.notice?.detail, "Child warning")
        XCTAssertEqual(usage?.didUpdateAgentState, false)
        XCTAssertNil(usage?.activity)
    }

    func testAgentNotificationRouterIgnoresParentNotifications() throws {
        let parentCommand = try decodeThreadItem(#"""
        {
          "id": "cmd-parent",
          "type": "commandExecution",
          "command": "swift test",
          "status": "active"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        let result = CodexAgentNotificationRouter.apply(
            agentNotification(.itemStarted(ItemStartedNotification(threadId: "thread-parent", turnId: "turn-parent", item: parentCommand))),
            to: &mapper
        )

        XCTAssertNil(result)
        XCTAssertTrue(mapper.subagents.isEmpty)
    }

    func testAgentItemParserExtractsNestedThreadDescriptor() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "fork-1",
          "type": "threadFork",
          "source": {
            "thread": {
              "id": "thread-kepler",
              "title": "Kepler",
              "prompt": "Inspect architecture boundaries"
            }
          }
        }
        """#)

        let descriptors = CodexAgentItemParser.subagentDescriptors(from: item)

        XCTAssertEqual(descriptors, [
            CodexSubagentDescriptor(
                id: "thread-kepler",
                name: "Kepler",
                title: "Kepler",
                prompt: "Inspect architecture boundaries"
            )
        ])
    }

    func testAgentItemParserReadsCollabPayloadReceiverIDsFromStatesFallback() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "call_wait",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "agentsStates": {
            "thread-two": { "status": "running" },
            "thread-one": { "status": "completed", "message": "done" }
          }
        }
        """#)

        let payload = try XCTUnwrap(CodexAgentItemParser.collabPayload(from: item))

        XCTAssertEqual(payload.tool, "wait")
        XCTAssertEqual(payload.receiverThreadIDs, ["thread-one", "thread-two"])
        XCTAssertEqual(payload.prompt, "Subagent task")
        XCTAssertEqual(payload.status(completed: true), .completed)
        XCTAssertEqual(CodexAgentItemParser.firstString(in: payload.states["thread-one"] ?? [:], keys: ["message"]), "done")
    }

    func testCollabPayloadCancelledStatusMapsToClosed() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "call_wait_cancelled",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "agentsStates": {
            "thread-one": { "status": "cancelled" },
            "thread-two": { "status": "canceled" }
          }
        }
        """#)

        let payload = try XCTUnwrap(CodexAgentItemParser.collabPayload(from: item))
        XCTAssertEqual(payload.status(completed: true), .closed)
        XCTAssertEqual(payload.status(completed: false), .closed)
    }

    func testCollabPayloadFailedStatusStillMapsToFailed() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "call_wait_failed",
          "type": "collabAgentToolCall",
          "tool": "wait",
          "agentsStates": {
            "thread-one": { "status": "error" }
          }
        }
        """#)

        let payload = try XCTUnwrap(CodexAgentItemParser.collabPayload(from: item))
        XCTAssertEqual(payload.status(completed: true), .failed)
    }

    // MARK: - Canonical status normalization

    func testStatusNormalizationCanonicalTable() {
        XCTAssertEqual(CodexSubagentState.Status.normalized("running"), .running)
        XCTAssertEqual(CodexSubagentState.Status.normalized("in-progress"), .running)
        XCTAssertEqual(CodexSubagentState.Status.normalized("succeeded"), .completed)
        // A cancelled subagent is deliberately stopped -> .closed, not .failed.
        XCTAssertEqual(CodexSubagentState.Status.normalized("cancelled"), .closed)
        XCTAssertEqual(CodexSubagentState.Status.normalized("canceled"), .closed)
        XCTAssertEqual(CodexSubagentState.Status.normalized("archived"), .closed)
        XCTAssertEqual(CodexSubagentState.Status.normalized("skipped"), .closed)
        // Only genuine error states map to .failed.
        XCTAssertEqual(CodexSubagentState.Status.normalized("error"), .failed)
        XCTAssertEqual(CodexSubagentState.Status.normalized("failed"), .failed)
        XCTAssertNil(CodexSubagentState.Status.normalized("bogus"))
    }

    func testSubagentStatusFallsBackToCompletedForUnknown() throws {
        let item = try decodeThreadItem(#"""
        { "id": "s1", "type": "subAgentThreadSpawn", "status": "wat" }
        """#)
        XCTAssertEqual(CodexAgentItemParser.subagentStatus(from: item), .completed)
    }
}

private func decodeThreadItem(_ json: String) throws -> ThreadItem {
    try JSONDecoder().decode(ThreadItem.self, from: Data(json.utf8))
}

private func agentNotification(_ payload: CodexNotificationPayload) -> CodexNotification {
    CodexNotification(
        method: payload.knownMethod?.rawValue ?? "unknown",
        payload: payload,
        rawParams: [:]
    )
}
