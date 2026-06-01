import XCTest
import SwiftUI
@testable import CodexCore

// MARK: - Mock Transport for Testing

actor MockTransport: CodexTransport {
    var isConnected = false
    var onMessage: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var sentPayloads: [[String: CodexJSONValue]] = []
    private let suspendedMethods: Set<String>

    init(suspendedMethods: Set<String> = []) {
        self.suspendedMethods = suspendedMethods
    }

    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        self.onMessage = onMessage
        self.onError = onError
        self.isConnected = true
    }

    func send(_ payload: [String: CodexJSONValue]) async throws {
        sentPayloads.append(payload)

        // Automatically respond to any JSON-RPC request containing an ID
        if let idVal = payload["id"] {
            let method = payload["method"]?.description ?? ""
            guard !suspendedMethods.contains(method) else { return }

            let reqIdString = idVal.description
            let result: String
            switch method {
            case "thread/start":
                result = #"{"thread":{"id":"thread-mock"}}"#
            case "thread/resume":
                result = #"{"thread":{"id":"thread-resumed"}}"#
            case "turn/start":
                result = #"{"turn":{"id":"turn-mock"}}"#
            case "command/exec":
                result = #"{"exitCode":0,"stdout":"COMMAND_OK\n","stderr":""}"#
            default:
                result = "{}"
            }

            let responseJson = """
            {
                "jsonrpc": "2.0",
                "id": \(reqIdString),
                "result": \(result)
            }
            """
            Task { [weak self] in
                guard let self else { return }
                await self.receiveMessage(responseJson)
            }
        }
    }

    func stop() async {
        isConnected = false
    }

    func receiveMessage(_ msg: String) {
        onMessage?(msg)
    }

    func fail(_ error: Error) {
        isConnected = false
        onError?(error)
    }
}

// MARK: - Test Suite

final class CodexClientTerminalTests: XCTestCase {

    func testInitializeHandshakeBuffering() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)

        // We start connecting
        let connectionReadyExpectation = expectation(description: "Initialize completed")

        Task {
            try await client.connect()
            connectionReadyExpectation.fulfill()
        }

        // Send a notification *during* initialize negotiation
        // The client connection must buffer this notification until handshake completes
        let earlyNotification = """
        {
            "jsonrpc": "2.0",
            "method": "thread/started",
            "params": {
                "threadId": "thread-handshake",
                "status": "active"
            }
        }
        """

        // Give socket a tiny window to establish the connection before injecting
        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage(earlyNotification)

        // Wait for connect task to finish
        await fulfillment(of: [connectionReadyExpectation], timeout: 2.0)

        // After handshake completes, the buffered notification should have flushed to the store
        try await Task.sleep(for: .milliseconds(50))

        let activeThread = await store.activeThread
        XCTAssertNotNil(activeThread)
        XCTAssertEqual(activeThread?.id, "thread-handshake")
        XCTAssertEqual(activeThread?.status, .active)
    }

    func testPTYTerminalProcessSessionWorkflow() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)

        // Connect the client
        try await client.connect()

        // 1. Spawn process
        let session = try await client.spawnProcess(
            command: ["zsh", "-i"],
            cwd: "/Users/dev/workspace",
            environment: ["TERM": "xterm-256color"],
            initialSize: PTYSize(rows: 24, cols: 80)
        )

        XCTAssertEqual(session.hasExited, false)
        XCTAssertEqual(session.exitCode, nil)

        // Assert spawn payload sent matching process/spawn spec
        let spawnPayload = await transport.sentPayloads.last
        XCTAssertEqual(spawnPayload?["method"]?.description, "process/spawn")

        // 2. Write stdin bytes
        let keystrokeData = "ls -la\n".data(using: .utf8)!
        try await session.write(data: keystrokeData)

        let writePayload = await transport.sentPayloads.last
        XCTAssertEqual(writePayload?["method"]?.description, "process/writeStdin")

        // Verify base64 encoding correctness
        if let paramsData = try? JSONEncoder().encode(writePayload?["params"]),
           let paramsMap = try? JSONDecoder().decode([String: CodexJSONValue].self, from: paramsData) {
            XCTAssertEqual(paramsMap["processHandle"]?.description, session.processHandle)
            XCTAssertEqual(paramsMap["deltaBase64"]?.description, keystrokeData.base64EncodedString())
        } else {
            XCTFail("Invalid stdin parameters payload")
        }

        // 3. Resize PTY
        try await session.resize(rows: 40, cols: 120)
        let resizePayload = await transport.sentPayloads.last
        XCTAssertEqual(resizePayload?["method"]?.description, "process/resizePty")

        // 4. Stream PTY stdout output delta
        let ptyOutputExpectation = expectation(description: "PTY stdout output received")

        Task {
            for await delta in session.outputStream {
                XCTAssertEqual(delta.stream, .stdout)
                XCTAssertEqual(String(data: delta.data, encoding: .utf8), "Desktop Documents")
                ptyOutputExpectation.fulfill()
            }
        }

        let testOutputBase64 = "Desktop Documents".data(using: .utf8)!.base64EncodedString()
        let stdoutNotification = """
        {
            "jsonrpc": "2.0",
            "method": "process/outputDelta",
            "params": {
                "processHandle": "\(session.processHandle)",
                "stream": "stdout",
                "deltaBase64": "\(testOutputBase64)",
                "capReached": false
            }
        }
        """

        await transport.receiveMessage(stdoutNotification)
        await fulfillment(of: [ptyOutputExpectation], timeout: 2.0)

        // 5. Stream PTY process exit
        let exitExpectation = expectation(description: "PTY process exited")

        Task {
            for await code in session.exitStream {
                XCTAssertEqual(code, 0)
                exitExpectation.fulfill()
            }
        }

        let exitNotification = """
        {
            "jsonrpc": "2.0",
            "method": "process/exited",
            "params": {
                "processHandle": "\(session.processHandle)",
                "exitCode": 0
            }
        }
        """

        await transport.receiveMessage(exitNotification)
        await fulfillment(of: [exitExpectation], timeout: 2.0)

        XCTAssertEqual(session.hasExited, true)
        XCTAssertEqual(session.exitCode, 0)
    }

    func testHighLevelThreadRunCollectsTurnResult() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        defer { Task { await codex.close() } }

        let thread = try await codex.threadStart(cwd: "/tmp")
        XCTAssertEqual(thread.id, "thread-mock")

        let runTask = Task {
            try await thread.run("Reply with hi", timeout: 2)
        }

        try await Task.sleep(for: .milliseconds(50))

        let itemCompleted = """
        {
            "jsonrpc": "2.0",
            "method": "item/completed",
            "params": {
                "threadId": "thread-mock",
                "turnId": "turn-mock",
                "item": {
                    "id": "item-assistant",
                    "type": "agentMessage",
                    "text": "hi"
                }
            }
        }
        """

        let turnCompleted = """
        {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "thread-mock",
                "turn": {
                    "id": "turn-mock",
                    "status": { "type": "completed" }
                },
                "error": null
            }
        }
        """

        await transport.receiveMessage(itemCompleted)
        await transport.receiveMessage(turnCompleted)

        let result = try await runTask.value
        XCTAssertEqual(result.id, "turn-mock")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.finalResponse, "hi")
        XCTAssertEqual(result.items.count, 1)
    }

    func testPendingRequestFailsOnTransportError() async throws {
        let transport = MockTransport(suspendedMethods: ["thread/list"])
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let pending = Task {
            try await client.request(method: "thread/list")
        }

        try await Task.sleep(for: .milliseconds(50))
        await transport.fail(CodexTransportError.connectionClosed)

        do {
            _ = try await pending.value
            XCTFail("Pending request should fail when the transport errors")
        } catch {
            XCTAssertTrue(String(describing: error).contains("transport") || String(describing: error).contains("connection"))
        }
    }

    func testBufferedCommandExecUsesOfficialMethod() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        let result = try await codex.execCommand(["/bin/echo", "COMMAND_OK"], cwd: "/tmp")
        await codex.close()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "COMMAND_OK\n")
        XCTAssertEqual(result.stderr, "")

        let payload = await transport.sentPayloads.last { $0["method"]?.description == "command/exec" }
        XCTAssertNotNil(payload)
        if case .dictionary(let params)? = payload?["params"] {
            XCTAssertEqual(params["cwd"], .string("/tmp"))
            XCTAssertEqual(params["command"], .array([.string("/bin/echo"), .string("COMMAND_OK")]))
        } else {
            XCTFail("command/exec params missing")
        }
    }

    func testStreamingCommandExecSessionRoutesOutputAndCompletion() async throws {
        let transport = MockTransport(suspendedMethods: ["command/exec"])
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let session = try await client.startCommandSession(
            command: ["/bin/zsh", "-f"],
            cwd: "/tmp",
            initialSize: PTYSize(rows: 24, cols: 80)
        )

        try await Task.sleep(for: .milliseconds(50))

        let outputExpectation = expectation(description: "command/exec output received")
        Task {
            for await delta in session.outputStream {
                XCTAssertEqual(delta.stream, .stdout)
                XCTAssertEqual(String(data: delta.data, encoding: .utf8), "STREAM_OK")
                outputExpectation.fulfill()
                break
            }
        }

        let outputBase64 = "STREAM_OK".data(using: .utf8)!.base64EncodedString()
        let outputNotification = """
        {
            "jsonrpc": "2.0",
            "method": "command/exec/outputDelta",
            "params": {
                "processId": "\(session.processId)",
                "stream": "stdout",
                "deltaBase64": "\(outputBase64)",
                "capReached": false
            }
        }
        """
        await transport.receiveMessage(outputNotification)
        await fulfillment(of: [outputExpectation], timeout: 2.0)

        try await session.write(data: "exit\n".data(using: .utf8)!)
        try await session.resize(rows: 40, cols: 120)
        try await session.terminate()

        let sentPayloads = await transport.sentPayloads
        let execPayload = sentPayloads.last { $0["method"]?.description == "command/exec" }
        guard let requestId = execPayload?["id"]?.description else {
            XCTFail("command/exec request id missing")
            return
        }

        let waitTask = Task { try await session.wait() }
        let completionResponse = """
        {
            "jsonrpc": "2.0",
            "id": \(requestId),
            "result": {
                "exitCode": 0,
                "stdout": "",
                "stderr": ""
            }
        }
        """
        await transport.receiveMessage(completionResponse)

        let result = try await waitTask.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(session.hasCompleted)

        let writePayload = sentPayloads.last { $0["method"]?.description == "command/exec/write" }
        let resizePayload = sentPayloads.last { $0["method"]?.description == "command/exec/resize" }
        let terminatePayload = sentPayloads.last { $0["method"]?.description == "command/exec/terminate" }
        XCTAssertNotNil(writePayload)
        XCTAssertNotNil(resizePayload)
        XCTAssertNotNil(terminatePayload)

        await client.disconnect()
    }

    func testANSIEscapeSequenceParsing() throws {
        let parser = ANSIParser()

        // 1. Basic SGR Red Text
        let rawInput = "\u{001B}[31mRed Text\u{001B}[0m Standard Text"
        let segments = parser.parse(rawInput)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Red Text")
        XCTAssertEqual(segments[0].style.foregroundColor, .red)

        XCTAssertEqual(segments[1].text, " Standard Text")
        XCTAssertEqual(segments[1].style.foregroundColor, .primary)

        // 2. Complex SGR Bold Underlined Blue Background Yellow Foreground
        let complexInput = "\u{001B}[1;4;44;33mStyled Text\u{001B}[0m"
        let complexSegments = parser.parse(complexInput)

        XCTAssertEqual(complexSegments.count, 1)
        XCTAssertEqual(complexSegments[0].text, "Styled Text")
        XCTAssertEqual(complexSegments[0].style.isBold, true)
        XCTAssertEqual(complexSegments[0].style.isUnderlined, true)
        XCTAssertEqual(complexSegments[0].style.foregroundColor, .yellow)
        XCTAssertEqual(complexSegments[0].style.backgroundColor, .blue)

        // 3. OSC Hyperlink Strip
        let oscInput = "\u{001B}]8;;http://google.com\u{0007}Google Link\u{001B}]8;;\u{0007} Rest"
        let oscSegments = parser.parse(oscInput)

        XCTAssertEqual(oscSegments.count, 2)
        XCTAssertEqual(oscSegments[0].text, "Google Link")
        XCTAssertEqual(oscSegments[1].text, " Rest")

        // 4. Swift AttributedString generation
        if #available(macOS 12.0, iOS 15.0, *) {
            let attrStr = parser.makeAttributedString(from: segments)
            let rawStr = String(attrStr.characters)
            XCTAssertEqual(rawStr, "Red Text Standard Text")
        }
    }

    func testRealCodexAppServerTurnLifecycle() async throws {
        let binaryURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
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
        let binaryURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
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
    }
}
