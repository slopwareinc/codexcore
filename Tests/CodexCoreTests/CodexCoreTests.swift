import XCTest
@testable import CodexCore

final class CodexCoreTests: XCTestCase {

    // MARK: - Runtime Resolution Tests

    func testResolveCodexBinaryUsesExplicitExecutableOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let resolved = try Codex.resolveCodexBinary(config: CodexConfig(codexBinaryPath: binaryURL.path))

        XCTAssertEqual(resolved.path, binaryURL.path)
    }

    func testResolveCodexBinaryRejectsInvalidExplicitOverride() {
        XCTAssertThrowsError(
            try Codex.resolveCodexBinary(config: CodexConfig(codexBinaryPath: "/definitely/not/a/codex/runtime"))
        )
    }

    // MARK: - Protocol & Decoders Tests

    func testJSONValueDecoding() throws {
        let jsonStr = """
        {
            "s": "text",
            "i": 42,
            "d": 3.14,
            "b": true,
            "n": null
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let map = try JSONDecoder().decode([String: CodexJSONValue].self, from: data)

        XCTAssertEqual(map["s"], .string("text"))
        XCTAssertEqual(map["i"], .int(42))
        XCTAssertEqual(map["d"], .double(3.14))
        XCTAssertEqual(map["b"], .bool(true))
        XCTAssertEqual(map["n"], .null)
    }

    func testServerItemDecoding() throws {
        let jsonStr = """
        {
            "id": "item-123",
            "type": "assistantMessage",
            "status": "completed",
            "label": "Guide",
            "text": "Hello, world!"
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let item = try JSONDecoder().decode(CodexServerItem.self, from: data)

        XCTAssertEqual(item.id, "item-123")
        XCTAssertEqual(item.type, "assistantMessage")
        XCTAssertEqual(item.status, "completed")
        XCTAssertEqual(item.label, "Guide")
        XCTAssertEqual(item.raw["text"], .string("Hello, world!"))
    }

    func testTimelineItemMapperParsesRawTurnPlanItems() throws {
        let detail = try XCTUnwrap(CodexTimelineItemMapper.turnPlan(from: [
            "explanation": .string("Keep the reducer canonical."),
            "plan": .array([
                .dictionary([
                    "step": .string("Move plan parsing"),
                    "status": .string("completed")
                ]),
                .dictionary([
                    "title": .string("Verify history projection"),
                    "status": .string("inProgress")
                ])
            ])
        ]))

        XCTAssertEqual(detail.explanation, "Keep the reducer canonical.")
        XCTAssertEqual(detail.plan, [
            TurnPlanStep(step: "Move plan parsing", status: .completed),
            TurnPlanStep(step: "Verify history projection", status: .inProgress)
        ])
    }

    // MARK: - Store & Reducer Pipeline Tests

    @MainActor
    func testStorePlanAndDiffUpdates() throws {
        let store = CodexCoreStore()
        store.dispatch(.threadStarted(threadId: "thread-pd", name: nil, status: "active"))
        store.dispatch(.turnStarted(threadId: "thread-pd", turnId: "turn-1"))

        store.dispatch(.turnPlanUpdated(
            threadId: "thread-pd",
            turnId: "turn-1",
            plan: [
                TurnPlanStep(step: "Survey the code", status: .completed),
                TurnPlanStep(step: "Apply the fix", status: .inProgress)
            ],
            explanation: "Two-step fix"
        ))
        store.dispatch(.turnDiffUpdated(threadId: "thread-pd", turnId: "turn-1", diff: "diff --git a/x b/x\n+1"))

        let turn = store.activeThread?.turns.first
        XCTAssertEqual(turn?.plan?.count, 2)
        XCTAssertEqual(turn?.plan?.last?.status, .inProgress)
        XCTAssertEqual(turn?.planExplanation, "Two-step fix")
        XCTAssertEqual(turn?.diff, "diff --git a/x b/x\n+1")
    }

    @MainActor
    func testStoreReducerWorkflow() throws {
        let store = CodexCoreStore()
        XCTAssertNil(store.activeThread)

        // 1. Start Thread
        store.dispatch(.threadStarted(threadId: "thread-abc", name: "Notebook Session", status: "active"))
        XCTAssertNotNil(store.activeThread)
        XCTAssertEqual(store.activeThread?.id, "thread-abc")
        XCTAssertEqual(store.activeThread?.status, .active)

        // 2. Start Turn
        store.dispatch(.turnStarted(threadId: "thread-abc", turnId: "turn-1"))
        XCTAssertTrue(store.isThinking)
        XCTAssertEqual(store.activeThread?.turns.count, 1)
        XCTAssertEqual(store.activeThread?.turns.first?.id, "turn-1")
        XCTAssertEqual(store.activeThread?.turns.first?.status, .running)

        // 3. Dispatch Assistant Delta Stream
        store.dispatch(.messageDelta(threadId: "thread-abc", turnId: "turn-1", itemId: "item-a", delta: "Swift "))
        store.dispatch(.messageDelta(threadId: "thread-abc", turnId: "turn-1", itemId: "item-a", delta: "is awesome!"))
        store.dispatch(.commandOutputDelta(
            threadId: "thread-abc",
            turnId: "turn-1",
            itemId: "cmd-a",
            delta: "build started"
        ))
        store.dispatch(.commandOutputDelta(
            threadId: "thread-abc",
            turnId: "turn-1",
            itemId: "cmd-a",
            delta: "\n$ swift test"
        ))
        store.dispatch(.fileChangePatchUpdated(
            threadId: "thread-abc",
            turnId: "turn-1",
            itemId: "patch-a",
            path: "Sources/App.swift",
            patch: """
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            """
        ))
        store.dispatch(.mcpToolCallProgress(
            threadId: "thread-abc",
            turnId: "turn-1",
            itemId: "mcp-a",
            message: "Reading available tools"
        ))
        store.dispatch(.mcpToolCallProgress(
            threadId: "thread-abc",
            turnId: "turn-1",
            itemId: "mcp-a",
            message: "Calling filesystem.read_file"
        ))

        let turn = store.activeThread?.turns.first
        XCTAssertEqual(turn?.items.count, 4)

        if let item = turn?.items.first {
            switch item {
            case .assistantMessage(let id, let text, _, let streaming):
                XCTAssertEqual(id, "item-a")
                XCTAssertEqual(text, "Swift is awesome!")
                XCTAssertTrue(streaming)
            default:
                XCTFail("Incorrect item type mapped")
            }
        }

        if let item = turn?.items.last {
            switch item {
            case .mcpToolCall(let id, let server, let tool, let status, _, let progress):
                XCTAssertEqual(id, "mcp-a")
                XCTAssertEqual(server, "MCP")
                XCTAssertEqual(tool, "Tool")
                XCTAssertEqual(status, "inProgress")
                XCTAssertEqual(progress, ["Reading available tools", "Calling filesystem.read_file"])
            default:
                XCTFail("Incorrect MCP tool-call item type mapped")
            }
        }

        if let item = turn?.items.first(where: { $0.id == "patch-a" }) {
            switch item {
            case .fileChange(let id, let path, let patch, let status, _):
                XCTAssertEqual(id, "patch-a")
                XCTAssertEqual(path, "Sources/App.swift")
                XCTAssertTrue(patch.contains("+new"))
                XCTAssertEqual(status, "active")
            default:
                XCTFail("Incorrect file change item type mapped")
            }
        }
        if case .fileChange(let detail)? = turn?.itemDetails["patch-a"] {
            XCTAssertEqual(detail.path, "Sources/App.swift")
            XCTAssertTrue(detail.output.isEmpty)
            XCTAssertTrue(detail.diff.contains("+new"))
            XCTAssertEqual(detail.status, "active")
        } else {
            XCTFail("Missing typed file-change detail")
        }
        if case .commandExecution(let detail)? = turn?.itemDetails["cmd-a"] {
            XCTAssertEqual(detail.command, "Running...")
            XCTAssertEqual(detail.output, "build started\n$ swift test")
            XCTAssertEqual(detail.status, "active")
        } else {
            XCTFail("Missing typed command detail")
        }
        if case .toolCall(let detail)? = turn?.itemDetails["mcp-a"] {
            XCTAssertEqual(detail.server, "MCP")
            XCTAssertEqual(detail.tool, "Tool")
            XCTAssertEqual(detail.status, "inProgress")
            XCTAssertEqual(detail.progress, ["Reading available tools", "Calling filesystem.read_file"])
        } else {
            XCTFail("Missing typed tool-call detail")
        }

        // 4. Finalize Item
        let serverItem = CodexServerItem(id: "item-a", type: "assistantMessage", status: "done", raw: ["text": .string("Swift is awesome!")])
        store.dispatch(.itemCompleted(threadId: "thread-abc", turnId: "turn-1", item: serverItem))
        XCTAssertNil(store.activeThread?.turns.first?.itemDetails["item-a"])

        // 5. Complete Turn
        store.dispatch(.turnCompleted(threadId: "thread-abc", turnId: "turn-1", error: nil))
        XCTAssertFalse(store.isThinking)
        XCTAssertEqual(store.activeThread?.turns.first?.status, .completed)
    }

    @MainActor
    func testStoreIndexesNonActiveThreadSnapshotsWithoutHijackingActiveThread() throws {
        let store = CodexCoreStore()
        store.dispatch(.threadStarted(threadId: "thread-main", name: nil, status: "active"))
        store.dispatch(.turnStarted(threadId: "thread-main", turnId: "turn-main"))
        store.dispatch(.threadStarted(threadId: "thread-child", name: nil, status: "active"))
        store.dispatch(.turnStarted(threadId: "thread-child", turnId: "turn-child"))
        store.dispatch(.itemCompleted(
            threadId: "thread-child",
            turnId: "turn-child",
            item: CodexServerItem(
                id: "cmd-child",
                type: "commandExecution",
                status: "completed",
                raw: [
                    "command": .string("swift test"),
                    "output": .string("ok"),
                    "exitCode": .int(0)
                ]
            )
        ))

        XCTAssertEqual(store.activeThread?.id, "thread-main")
        let childTurn = store.turnSnapshot(threadID: "thread-child", turnID: "turn-child")
        XCTAssertEqual(childTurn?.items.map(\.id), ["cmd-child"])
        if case .commandExecution(let detail)? = childTurn?.itemDetails["cmd-child"] {
            XCTAssertEqual(detail.command, "swift test")
            XCTAssertEqual(detail.output, "ok")
            XCTAssertEqual(detail.exitCode, 0)
        } else {
            XCTFail("Missing typed child command detail")
        }
    }

    func testThreadHistoryHydratorBuildsStoreSnapshotsAndChildThreads() async throws {
        let parent: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-parent"),
                "cwd": .string("/tmp/CodexCore"),
                "model": .string("gpt-test"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-parent"),
                        "status": .string("completed"),
                        "startedAt": .int(1_000),
                        "completedAt": .int(1_100),
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
                                "receiverThreadIds": .array([.string("thread-child")]),
                                "prompt": .string("Inspect child state"),
                                "agentsStates": .dictionary([
                                    "thread-child": .dictionary(["status": .string("running")])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("cmd-1"),
                                "type": .string("commandExecution"),
                                "command": .array([.string("swift"), .string("test")]),
                                "aggregatedOutput": .string("ok"),
                                "status": .string("completed"),
                                "exitCode": .int(0)
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
        let result = await CodexThreadHistoryHydrator.hydrate(parentRaw: parent) { childThreadID in
            XCTAssertEqual(childThreadID, "thread-child")
            return child
        }

        XCTAssertEqual(result.parent.snapshot.id, "thread-parent")
        XCTAssertEqual(result.parent.snapshot.cwd, "/tmp/CodexCore")
        XCTAssertEqual(result.parent.snapshot.model, "gpt-test")
        XCTAssertEqual(result.parent.childThreadIDs, ["thread-child"])
        XCTAssertEqual(result.parent.snapshot.childThreads, [
            CodexChildThreadReference(
                threadID: "thread-child",
                itemID: "spawn-1",
                prompt: "Inspect child state",
                status: "running"
            )
        ])
        XCTAssertEqual(result.parent.snapshot.turns.first?.items.map(\.id), ["user-1", "cmd-1"])
        if case .commandExecution(let detail)? = result.parent.snapshot.turns.first?.itemDetails["cmd-1"] {
            XCTAssertEqual(detail.command, "swift test")
            XCTAssertEqual(detail.output, "ok")
            XCTAssertEqual(detail.exitCode, 0)
        } else {
            XCTFail("Missing hydrated command detail")
        }

        XCTAssertEqual(result.childThreads.map(\.snapshot.id), ["thread-child"])
        XCTAssertEqual(result.childThreads.first?.agentName, "Ada")
        XCTAssertEqual(result.childThreads.first?.agentRole, "coder")

        await MainActor.run {
            let store = CodexCoreStore()
            store.hydrate(result)
            XCTAssertEqual(store.activeThread?.id, "thread-parent")
            XCTAssertEqual(store.turnSnapshot(threadID: "thread-child", turnID: "turn-child")?.items.map(\.id), ["child-answer"])
        }
    }

    func testThreadResumeWithHistoryCanHydrateWithoutThreadRead() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        let resume = try await codex.threadResumeWithHistory(
            "thread-resumed",
            approvalMode: .autoReview,
            cwd: "/tmp",
            sandbox: .workspaceWrite
        )
        let parentRaw = try resume.rawResponse()
        let hydration = await CodexThreadHistoryHydrator.hydrate(parentRaw: parentRaw) { childThreadID in
            XCTFail("Resume response should hydrate this fixture without reading child thread \(childThreadID)")
            return .dictionary(["thread": .dictionary(["id": .string(childThreadID), "turns": .array([])])])
        }

        XCTAssertEqual(resume.thread.id, "thread-resumed")
        XCTAssertEqual(hydration.parent.snapshot.id, "thread-resumed")
        XCTAssertEqual(hydration.parent.snapshot.turns.first?.items.map { $0.id }, ["user-resumed", "agent-resumed"])

        let sentMethods = await transport.sentPayloadsSnapshot().compactMap { payload -> String? in
            guard case .string(let method)? = payload["method"] else { return nil }
            return method
        }
        XCTAssertEqual(sentMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertFalse(sentMethods.contains("thread/read"), "Successful resume hydration must not refetch the parent transcript")
        await codex.close()
    }

    // MARK: - Exploration Merging & Retention Tests

    func testExplorationMerging() throws {
        let items: [CodexTimelineItem] = [
            .userMessage(id: "u-1", text: "Check workspace status", timestamp: Date()),
            .commandExecution(id: "expl-1", command: "git status", output: "Clean", status: "completed", timestamp: Date()),
            .commandExecution(id: "expl-2", command: "pwd", output: "/Users/dev", status: "completed", timestamp: Date()),
            .assistantMessage(id: "a-1", text: "Everything is clean.", timestamp: Date(), isStreaming: false)
        ]

        let projected = CodexTimelineProjection.project(items)
        XCTAssertEqual(projected.count, 3)

        // First is user message
        if case .item(let item) = projected[0] {
            XCTAssertEqual(item.id, "u-1")
        } else {
            XCTFail()
        }

        // Second is merged exploration group
        if case .exploration(let id, let expItems) = projected[1] {
            XCTAssertTrue(id.hasPrefix("exploration-"))
            XCTAssertEqual(expItems.count, 2)
            XCTAssertEqual(expItems[0].id, "expl-1")
            XCTAssertEqual(expItems[1].id, "expl-2")
        } else {
            XCTFail()
        }

        // Third is assistant message
        if case .item(let item) = projected[2] {
            XCTAssertEqual(item.id, "a-1")
        } else {
            XCTFail()
        }
    }

    func testLiveDetailRetentionPolicy() throws {
        let items: [CodexTimelineItem] = [
            .assistantMessage(id: "a-1", text: "Finished step 1", timestamp: Date(), isStreaming: false),
            .commandExecution(id: "c-1", command: "build", output: "Success", status: "completed", timestamp: Date()),
            .assistantMessage(id: "a-2", text: "Starting step 2...", timestamp: Date(), isStreaming: true)
        ]

        let retained = CodexLiveDetailRetentionPolicy.retainedRichDetailItemIDs(for: items)
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.contains("a-2")) // Active streaming retained
        XCTAssertTrue(retained.contains("c-1")) // Latest completed item retained
        XCTAssertFalse(retained.contains("a-1")) // Older prunable item removed
    }

    // MARK: - MessageParser & MessageContentBridge Tests

    func testExtractPlainSegments() throws {
        let blocks = MessageContentBridge.assistantRenderBlocks("Hello, world!")
        XCTAssertEqual(blocks.count, 1)
        if case .markdown(let text) = blocks[0] {
            XCTAssertEqual(text, "Hello, world!")
        } else {
            XCTFail()
        }
    }

    func testExtractCodeBlockSegments() throws {
        let text = "Before\n```python\nprint('hi')\n```\nAfter"
        let blocks = MessageContentBridge.assistantRenderBlocks(text)
        XCTAssertEqual(blocks.count, 3)

        if case .markdown(let t) = blocks[0] {
            XCTAssertEqual(t, "Before\n")
        } else { XCTFail() }

        if case .codeBlock(let language, let code) = blocks[1] {
            XCTAssertEqual(language, "python")
            XCTAssertEqual(code, "print('hi')")
        } else { XCTFail() }

        if case .markdown(let t) = blocks[2] {
            XCTAssertEqual(t, "\nAfter")
        } else { XCTFail() }
    }

    func testExtractInlineImageSegments() throws {
        let pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        let text = "Before image ![alt](data:image/png;base64,\(pngB64)) after image"

        let blocks = MessageContentBridge.assistantRenderBlocks(text)
        XCTAssertEqual(blocks.count, 3)

        if case .markdown(let t) = blocks[0] {
            XCTAssertEqual(t, "Before image ")
        } else { XCTFail() }

        if case .inlineImage(let data) = blocks[1] {
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47])) // PNG magic bytes
        } else { XCTFail() }

        if case .markdown(let t) = blocks[2] {
            XCTAssertEqual(t, " after image")
        } else { XCTFail() }
    }

    func testParseCodeReviewJSON() throws {
        let jsonStr = """
        {
            "findings": [
                {
                    "title": "[P1] Fall back to turn/start when queue sync fails",
                    "body": "A queued follow-up can get stuck indefinitely.",
                    "confidence_score": 0.97,
                    "priority": 1,
                    "code_location": {
                        "absolute_file_path": "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs",
                        "line_range": { "start": 799, "end": 815 }
                    }
                }
            ],
            "overall_correctness": "incorrect",
            "overall_explanation": "There are blocking issues.",
            "overall_confidence_score": 0.92
        }
        """

        let payload = MessageContentBridge.parseCodeReview(text: jsonStr)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.findings.count, 1)
        XCTAssertEqual(payload?.findings[0].title, "Fall back to turn/start when queue sync fails")
        XCTAssertEqual(payload?.findings[0].priority, 1)
        XCTAssertEqual(payload?.findings[0].codeLocation?.absoluteFilePath, "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs")
        XCTAssertEqual(payload?.findings[0].codeLocation?.lineRange?.start, 799)
        XCTAssertEqual(payload?.findings[0].codeLocation?.lineRange?.end, 815)
        XCTAssertEqual(payload?.overallCorrectness, "incorrect")

        let fencedPayload = MessageContentBridge.parseCodeReview(text: """
        Ignore this shell example:
        ```bash
        echo "{}"
        ```

        ```json
        \(jsonStr)
        ```
        """)
        XCTAssertEqual(fencedPayload?.findings.first?.title, "Fall back to turn/start when queue sync fails")
    }

    func testParseToolCallsMarkdown() throws {
        let md = """
        ### Command Execution
        status: completed
        duration: 2.3s
        cwd: /tmp/project
        command: ```bash
        swift build
        ```
        """

        let cards = MessageContentBridge.parseToolCalls(text: md)
        XCTAssertEqual(cards.count, 1)

        let card = cards[0]
        XCTAssertEqual(card.kind, .commandExecution)
        XCTAssertEqual(card.status, .completed)
        XCTAssertEqual(card.duration, "2.3s")
        XCTAssertEqual(card.commandContext?.command, "swift build")
        XCTAssertEqual(card.commandContext?.directory, "/tmp/project")
    }
}
