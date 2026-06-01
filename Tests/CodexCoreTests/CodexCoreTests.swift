import XCTest
@testable import CodexCore

final class CodexCoreTests: XCTestCase {

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

    // MARK: - Store & Reducer Pipeline Tests

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

        let turn = store.activeThread?.turns.first
        XCTAssertEqual(turn?.items.count, 1)

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

        // 4. Finalize Item
        let serverItem = CodexServerItem(id: "item-a", type: "assistantMessage", status: "done", raw: ["text": .string("Swift is awesome!")])
        store.dispatch(.itemCompleted(threadId: "thread-abc", turnId: "turn-1", item: serverItem))

        // 5. Complete Turn
        store.dispatch(.turnCompleted(threadId: "thread-abc", turnId: "turn-1", error: nil))
        XCTAssertFalse(store.isThinking)
        XCTAssertEqual(store.activeThread?.turns.first?.status, .completed)
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
