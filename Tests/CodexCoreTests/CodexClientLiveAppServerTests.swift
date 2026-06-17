import XCTest
@testable import CodexCore

extension CodexClientTerminalTests {
    func testRealCodexAppServerTurnLifecycle() async throws {
        guard let binaryURL = try? Codex.resolveCodexBinary() else {
            print("[CodexClientTerminalTests] Skipping: Codex binary not found")
            return
        }

        let transport = CodexStdioTransport(
            executableURL: binaryURL,
            arguments: ["app-server"]
        )

        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)

        // 1. Connect — real initialize handshake with codex app-server
        try await client.connect()
        let connected = await transport.isConnected
        XCTAssertTrue(connected)
        print("✓ Connected")

        // 2. Create a thread
        let threadId = try await client.createThread(cwd: NSHomeDirectory())
        XCTAssertFalse(threadId.isEmpty)
        var thread = await store.activeThread
        XCTAssertEqual(thread?.id, threadId)
        print("✓ Thread created: \(threadId)")

        // 3. Start a turn — this triggers an actual model call
        let turnId = try await client.startTurn(threadId: threadId, userPrompt: "Reply with exactly one word: Hello")
        XCTAssertFalse(turnId.isEmpty)
        thread = await store.activeThread
        XCTAssertEqual(thread?.turns.last?.id, turnId)
        let thinking = await store.isThinking
        XCTAssertTrue(thinking)
        print("✓ Turn started: \(turnId)")

        // 4. Wait for the turn to complete (poll store)
        var turnCompleted = false
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            let current = await store.activeThread
            if let turn = current?.turns.first(where: { $0.id == turnId }), turn.status == .completed || turn.status == .failed {
                turnCompleted = true
                print("✓ Turn \(turn.status == .completed ? "completed" : "failed")")
                if let lastItem = turn.items.last {
                    switch lastItem {
                    case .assistantMessage(_, let text, _, _):
                        print("  Response: \"\(text)\"")
                    case .userMessage(_, let text, _):
                        print("  Prompt: \"\(text)\"")
                    default:
                        print("  Last item: \(lastItem.id)")
                    }
                }
                break
            }
        }
        XCTAssertTrue(turnCompleted, "Turn should complete within 60s")

        // 5. Verify items were created in the store
        let finalThread = await store.activeThread
        let turnItems = finalThread?.turns.first(where: { $0.id == turnId })?.items ?? []
        XCTAssertGreaterThan(turnItems.count, 0, "Turn should have at least one item")

        let hasUserMessage = turnItems.contains { if case .userMessage = $0 { return true }; return false }
        let hasAssistantMessage = turnItems.contains { if case .assistantMessage = $0 { return true }; return false }
        XCTAssertTrue(hasUserMessage, "Should have a userMessage item")
        XCTAssertTrue(hasAssistantMessage, "Should have an assistantMessage item")

        print("✓ Turn items: \(turnItems.count) (user: \(hasUserMessage), assistant: \(hasAssistantMessage))")

        // 6. Clean up
        await client.disconnect()
        let disconnected = await transport.isConnected
        XCTAssertFalse(disconnected)
        print("✓ Disconnected")
    }

    func testRealCodexAppServerProcessSession() async throws {
        guard let binaryURL = try? Codex.resolveCodexBinary() else {
            print("[CodexClientTerminalTests] Skipping: Codex binary not found")
            return
        }

        let transport = CodexStdioTransport(
            executableURL: binaryURL,
            arguments: ["app-server"]
        )

        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)

        try await client.connect()

        let session = try await client.spawnProcess(
            command: ["/bin/zsh", "-f"],
            cwd: NSHomeDirectory(),
            initialSize: PTYSize(rows: 24, cols: 80)
        )

        let outputExpectation = expectation(description: "real process output received")
        let exitExpectation = expectation(description: "real process exited")

        Task {
            for await delta in session.outputStream {
                if let text = String(data: delta.data, encoding: .utf8), text.contains("SPAWN_OK") {
                    outputExpectation.fulfill()
                    break
                }
            }
        }

        Task {
            for await _ in session.exitStream {
                exitExpectation.fulfill()
                break
            }
        }

        try await Task.sleep(for: .milliseconds(500))
        try await session.write(data: "echo SPAWN_OK\n".data(using: .utf8)!)

        await fulfillment(of: [outputExpectation], timeout: 5.0)

        try await session.kill()
        await fulfillment(of: [exitExpectation], timeout: 5.0)

        XCTAssertTrue(session.hasExited)
        await client.disconnect()
        let disconnected = await transport.isConnected
        XCTAssertFalse(disconnected)

        print("✓ Real process/spawn + stdin + outputDelta + kill verified")
    }}
