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
    private var methodSendCounts: [String: Int] = [:]

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
        if let idVal = payload["id"], payload["method"] != nil {
            let method = payload["method"]?.description ?? ""
            guard !suspendedMethods.contains(method) else { return }
            methodSendCounts[method, default: 0] += 1
            let methodSendCount = methodSendCounts[method] ?? 0

            let reqIdString = idVal.description
            if method == "retry/overload", methodSendCount == 1 {
                let responseJson = """
                {
                    "jsonrpc": "2.0",
                    "id": \(reqIdString),
                    "error": {
                        "code": -32000,
                        "message": "server overloaded",
                        "data": { "codex_error_info": "server_overloaded" }
                    }
                }
                """
                Task { [weak self] in
                    guard let self else { return }
                    await self.receiveMessage(responseJson)
                }
                return
            }

            let result: String
            switch method {
            case "initialize":
                result = #"{"serverInfo":{"name":"codex","version":"1.0.0"},"userAgent":"codex/1.0.0"}"#
            case "account/login/start":
                let loginType: String? = {
                    guard case .dictionary(let params)? = payload["params"], case .string(let type)? = params["type"] else {
                        return nil
                    }
                    return type
                }()
                switch loginType {
                case "chatgpt":
                    result = #"{"type":"chatgpt","loginId":"login-mock","authUrl":"https://example.com/auth"}"#
                case "chatgptDeviceCode":
                    result = #"{"type":"chatgptDeviceCode","loginId":"login-mock","verificationUrl":"https://example.com/device","userCode":"ABCD-EFGH"}"#
                case "chatgptAuthTokens":
                    result = #"{"type":"chatgptAuthTokens"}"#
                default:
                    result = #"{"type":"apiKey"}"#
                }
            case "account/read":
                result = #"{"requiresOpenaiAuth":false,"account":null}"#
            case "account/logout", "account/login/cancel", "thread/archive", "thread/name/set", "thread/compact/start", "turn/interrupt":
                result = "{}"
            case "thread/start":
                result = #"{"thread":{"id":"thread-mock"}}"#
            case "thread/resume":
                result = #"{"thread":{"id":"thread-resumed"}}"#
            case "thread/fork":
                result = #"{"thread":{"id":"thread-fork"}}"#
            case "thread/unarchive":
                result = #"{"thread":{"id":"thread-unarchived"}}"#
            case "thread/list":
                result = #"{"data":[{"id":"thread-mock"}],"nextCursor":null,"backwardsCursor":null}"#
            case "thread/read":
                result = #"{"thread":{"id":"thread-mock"}}"#
            case "turn/start":
                result = #"{"turn":{"id":"turn-mock"}}"#
            case "turn/steer":
                result = #"{"turnId":"turn-mock"}"#
            case "model/list":
                result = #"{"models":[]}"#
            case "command/exec":
                result = #"{"exitCode":0,"stdout":"COMMAND_OK\n","stderr":""}"#
            case "retry/overload":
                result = #"{"ok":true}"#
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

    func testJSONRPCErrorMappingMatchesPythonSDK() {
        XCTAssertEqual(mapJSONRPCError(code: -32700, message: "parse").kind, .parse)
        XCTAssertEqual(mapJSONRPCError(code: -32600, message: "invalid request").kind, .invalidRequest)
        XCTAssertEqual(mapJSONRPCError(code: -32601, message: "missing").kind, .methodNotFound)
        XCTAssertEqual(mapJSONRPCError(code: -32602, message: "bad params").kind, .invalidParams)
        XCTAssertEqual(mapJSONRPCError(code: -32603, message: "internal").kind, .internalRpc)

        let overloadData: CodexJSONValue = .dictionary(["codexErrorInfo": .string("server_overloaded")])
        let busy = mapJSONRPCError(code: -32000, message: "server busy", data: overloadData)
        XCTAssertEqual(busy.kind, .serverBusy)
        XCTAssertTrue(isRetryableError(busy))
        XCTAssertTrue(is_retryable_error(busy))

        let retryLimit = map_jsonrpc_error(code: -32000, message: "retry limit reached", data: overloadData)
        XCTAssertEqual(retryLimit.kind, .retryLimitExceeded)
        XCTAssertTrue(isRetryableError(retryLimit))

        let generic = mapJSONRPCError(code: -32000, message: "other", data: .dictionary([:]))
        XCTAssertEqual(generic.kind, .codexRpc)
        XCTAssertFalse(isRetryableError(generic))
    }

    func testRequestWithRetryOnOverloadRetriesMappedServerBusyError() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        do {
            _ = try await client.request(method: "retry/overload")
            XCTFail("First overload request should throw without retry")
        } catch let error as CodexRPCError {
            XCTAssertEqual(error.kind, .serverBusy)
            XCTAssertTrue(isRetryableError(error))
        }

        let retryTransport = MockTransport()
        let retryStore = await CodexCoreStore()
        let retryClient = CodexClient(transport: retryTransport, store: retryStore)
        try await retryClient.connect()

        let value = try await retryClient.requestWithRetryOnOverload(
            method: "retry/overload",
            maxAttempts: 2,
            initialDelay: .zero,
            maxDelay: .zero,
            jitterRatio: 0
        )
        XCTAssertEqual(value, .dictionary(["ok": .bool(true)]))

        let retryPayloads = await retryTransport.sentPayloads.filter { $0["method"]?.description == "retry/overload" }
        XCTAssertEqual(retryPayloads.count, 2)

        await client.disconnect()
        await retryClient.disconnect()
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

    func testTypedClientMethodsUsePythonSDKWireMethods() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        let metadata = try await client.connect(clientName: "test", clientTitle: "Test", clientVersion: "0.1", experimentalApi: false)

        XCTAssertEqual(metadata.serverInfo?.name, "codex")

        _ = try await client.accountLoginStart(.apiKey("sk-test"))
        let account = try await client.accountRead(GetAccountParams(refreshToken: true))
        XCTAssertFalse(account.requiresOpenaiAuth)

        let forked = try await client.threadFork(threadId: "thread-mock")
        XCTAssertEqual(forked.thread.id, "thread-fork")

        let listed = try await client.threadList(ThreadListParams(limit: 1, sortDirection: .desc, sortKey: .updatedAt))
        XCTAssertEqual(listed.data?.first?.id, "thread-mock")

        let models = try await client.modelList(includeHidden: true)
        XCTAssertEqual(models.models?.count, 0)

        let methods = await transport.sentPayloads.compactMap { $0["method"]?.description }
        XCTAssertTrue(methods.contains("account/login/start"))
        XCTAssertTrue(methods.contains("account/read"))
        XCTAssertTrue(methods.contains("thread/fork"))
        XCTAssertTrue(methods.contains("thread/list"))
        XCTAssertTrue(methods.contains("model/list"))

        let initialize = await transport.sentPayloads.first { $0["method"]?.description == "initialize" }
        if case .dictionary(let params)? = initialize?["params"],
           case .dictionary(let capabilities)? = params["capabilities"] {
            XCTAssertEqual(capabilities["experimentalApi"], .bool(false))
        } else {
            XCTFail("initialize capabilities missing")
        }

        await client.disconnect()
    }

    func testEveryGeneratedClientMethodCanBeSentByEnumRequest() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let startCount = await transport.sentPayloads.count
        for method in CodexAppServerClientMethod.allCases {
            _ = try await client.appServerRequest(method, params: [:])
        }

        let sent = await transport.sentPayloads
        let requestMethods = sent.dropFirst(startCount).compactMap { payload -> String? in
            guard case .string(let method)? = payload["method"] else { return nil }
            return method
        }

        XCTAssertEqual(requestMethods, CodexAppServerClientMethod.allCases.map(\.rawValue))
        XCTAssertEqual(Set(requestMethods).count, CodexAppServerProtocolInventory.clientMethodCount)

        await client.disconnect()
    }

    func testDefaultServerRequestHandlingCoversGeneratedInventory() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()
        let threadId = try await client.createThread(cwd: "/tmp")
        let turnId = try await client.startTurn(threadId: threadId, userPrompt: "hi")

        let baseParams: [String: CodexJSONValue] = [
            "threadId": .string(threadId),
            "turnId": .string(turnId),
            "itemId": .string("item-request"),
            "startedAtMs": .int(1),
            "cwd": .string("/tmp"),
            "reason": .string("test")
        ]

        let cases: [(CodexAppServerServerRequestMethod, CodexJSONValue, [String: CodexJSONValue], CodexJSONValue)] = [
            (.itemCommandExecutionRequestApproval, .string("server-request-string-id"), baseParams.merging(["command": .string("echo hi")]) { _, new in new }, .dictionary(["decision": .string("accept")])),
            (.itemFileChangeRequestApproval, .int(2), baseParams, .dictionary(["decision": .string("accept")])),
            (.itemToolRequestUserInput, .int(3), baseParams.merging([
                "questions": .array([
                    .dictionary([
                        "id": .string("question-1"),
                        "header": .string("Header"),
                        "question": .string("Choose"),
                        "isSecret": .bool(true),
                        "isOther": .bool(true),
                        "options": .array([
                            .dictionary(["label": .string("Yes"), "description": .string("Confirm")])
                        ])
                    ])
                ])
            ]) { _, new in new }, .dictionary(["answers": .dictionary([:])])),
            (.mcpServerElicitationRequest, .int(4), ["threadId": .string(threadId), "turnId": .string(turnId), "serverName": .string("mcp")], .dictionary(["action": .string("decline"), "content": .null, "_meta": .null])),
            (.itemPermissionsRequestApproval, .int(5), baseParams.merging(["permissions": .dictionary([:])]) { _, new in new }, .dictionary(["permissions": .dictionary([:]), "scope": .string("turn")])),
            (.itemToolCall, .int(6), baseParams.merging(["tool": .string("client_tool"), "arguments": .dictionary([:])]) { _, new in new }, .dictionary(["contentItems": .array([]), "success": .bool(false)])),
            (.accountChatgptAuthTokensRefresh, .int(7), ["reason": .string("unauthorized")], .dictionary([:])),
            (.attestationGenerate, .int(8), [:], .dictionary([:])),
            (.applyPatchApproval, .int(9), ["conversationId": .string(threadId), "callId": .string("call-patch"), "fileChanges": .dictionary([:])], .dictionary(["decision": .string("approved")])),
            (.execCommandApproval, .int(10), ["conversationId": .string(threadId), "callId": .string("call-exec"), "command": .array([.string("echo"), .string("hi")]), "cwd": .string("/tmp"), "parsedCmd": .array([])], .dictionary(["decision": .string("approved")]))
        ]

        XCTAssertEqual(cases.count, CodexAppServerProtocolInventory.serverRequestMethodCount)

        for (method, id, params, expectedResult) in cases {
            let reply = try await sendServerRequest(method: method, id: id, params: params, transport: transport)
            XCTAssertEqual(reply["id"], id)
            XCTAssertEqual(reply["result"], expectedResult, "Unexpected default response for \(method.rawValue)")
        }

        let activeThread = await store.activeThread
        XCTAssertEqual(activeThread?.pendingApprovals.count, 3)
        XCTAssertEqual(activeThread?.pendingApprovals.map(\.kind), [.command, .fileChange, .permissions])

        let pendingInput = await store.pendingUserInput
        XCTAssertEqual(pendingInput?.questions.first?.id, "question-1")
        XCTAssertEqual(pendingInput?.questions.first?.options.first?.label, "Yes")
        XCTAssertEqual(pendingInput?.questions.first?.isSecret, true)
        XCTAssertEqual(pendingInput?.questions.first?.isOtherAllowed, true)

        await client.disconnect()
    }

    func testCustomServerRequestHandlerOverridesDefaultResponse() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store) { request in
            guard request.method == CodexAppServerServerRequestMethod.attestationGenerate.rawValue else {
                return nil
            }
            return .dictionary(["token": .string("custom-attestation")])
        }
        try await client.connect()

        let reply = try await sendServerRequest(
            method: .attestationGenerate,
            id: .string("attestation-request"),
            params: [:],
            transport: transport
        )
        XCTAssertEqual(reply["id"], .string("attestation-request"))
        XCTAssertEqual(reply["result"], .dictionary(["token": .string("custom-attestation")]))

        await client.disconnect()
    }

    func testHighLevelCodexThreadMethodsUseTypedPythonParitySurface() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        XCTAssertEqual(codex.metadata.userAgent, "codex/1.0.0")

        try await codex.loginAPIKey("sk-test")
        let account = try await codex.account(refreshToken: true)
        XCTAssertFalse(account.requiresOpenaiAuth)

        let thread = try await codex.threadStart(cwd: "/tmp", model: "test-model", sandbox: .workspaceWrite)
        XCTAssertEqual(thread.id, "thread-mock")

        let listed = try await codex.threadList(limit: 1)
        XCTAssertEqual(listed.data?.first?.id, "thread-mock")

        let forked = try await codex.threadFork(thread.id, sandbox: .readOnly)
        XCTAssertEqual(forked.id, "thread-fork")

        let unarchived = try await codex.threadUnarchive(thread.id)
        XCTAssertEqual(unarchived.id, "thread-unarchived")

        _ = try await codex.threadArchive(thread.id)
        let modelList = try await codex.models(includeHidden: true)
        XCTAssertEqual(modelList.models?.count, 0)

        let handle = try await thread.turn([.text("hi"), .localImage(path: "/tmp/a.png")], model: "test-model", sandbox: .workspaceWrite)
        XCTAssertEqual(handle.id, "turn-mock")

        let sentPayloads = await transport.sentPayloads
        let threadStartPayload = sentPayloads.last { $0["method"]?.description == "thread/start" }
        if case .dictionary(let params)? = threadStartPayload?["params"] {
            XCTAssertEqual(params["sandbox"], .string("workspace-write"))
            XCTAssertEqual(params["approvalsReviewer"], .string("auto_review"))
            XCTAssertEqual(params["approvalPolicy"], .string("on-request"))
        } else {
            XCTFail("thread/start params missing")
        }

        let turnStartPayload = sentPayloads.last { $0["method"]?.description == "turn/start" }
        if case .dictionary(let params)? = turnStartPayload?["params"],
           case .array(let input)? = params["input"] {
            XCTAssertEqual(input.count, 2)
            XCTAssertEqual(params["sandboxPolicy"], .dictionary(["type": .string("workspaceWrite")]))
        } else {
            XCTFail("turn/start params missing")
        }

        await codex.close()
    }

    func testNotificationStreamsRouteGlobalAndReplayTurnEvents() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let globalExpectation = expectation(description: "global notification receives scoped turn event")
        let globalStream = client.notifications()
        Task {
            var iterator = globalStream.makeAsyncIterator()
            let notification = await iterator.next()
            XCTAssertEqual(notification?.method, "item/agentMessage/delta")
            if case .agentMessageDelta(let delta)? = notification?.payload {
                XCTAssertEqual(delta.delta, "hello")
            } else {
                XCTFail("Expected typed agent message delta notification")
            }
            globalExpectation.fulfill()
        }

        try await Task.sleep(for: .milliseconds(50))
        let threadId = try await client.createThread(cwd: "/tmp")
        let turnId = try await client.startTurn(threadId: threadId, userPrompt: "hi")

        let deltaNotification = """
        {
            "jsonrpc": "2.0",
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "\(threadId)",
                "turnId": "\(turnId)",
                "itemId": "item-agent",
                "delta": "hello"
            }
        }
        """

        let turnCompleted = """
        {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "\(threadId)",
                "turn": {
                    "id": "\(turnId)",
                    "status": { "type": "completed" }
                }
            }
        }
        """

        await transport.receiveMessage(deltaNotification)
        await transport.receiveMessage(turnCompleted)
        await fulfillment(of: [globalExpectation], timeout: 2.0)

        let replayDeltaExpectation = expectation(description: "turn stream replays pending delta")
        let replayCompletedExpectation = expectation(description: "turn stream replays completion")
        let streamFinishedExpectation = expectation(description: "turn stream finishes on completion")
        let turnStream = client.turnNotifications(turnId: turnId)
        Task {
            var iterator = turnStream.makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertEqual(first?.method, "item/agentMessage/delta")
            replayDeltaExpectation.fulfill()

            let second = await iterator.next()
            XCTAssertEqual(second?.method, "turn/completed")
            replayCompletedExpectation.fulfill()

            let finished = await iterator.next()
            XCTAssertNil(finished)
            streamFinishedExpectation.fulfill()
        }

        await fulfillment(of: [replayDeltaExpectation, replayCompletedExpectation, streamFinishedExpectation], timeout: 2.0)
        await client.disconnect()
    }

    func testEveryGeneratedNotificationMethodRoutesAsKnownPayload() async throws {
        let router = CodexNotificationRouter()
        let stream = router.globalNotifications()

        let collector = Task { () -> [CodexNotification] in
            var notifications: [CodexNotification] = []
            var iterator = stream.makeAsyncIterator()
            while notifications.count < CodexAppServerProtocolInventory.notificationMethodCount {
                if let notification = await iterator.next() {
                    notifications.append(notification)
                }
            }
            return notifications
        }

        try await Task.sleep(for: .milliseconds(50))
        for method in CodexAppServerNotificationMethod.allCases {
            await router.route(JSONRPCNotification(jsonrpc: "2.0", method: method.rawValue, params: [:]))
        }

        let notifications = await collector.value
        let knownMethods = notifications.compactMap(\.payload.knownMethod)
        XCTAssertEqual(knownMethods, CodexAppServerNotificationMethod.allCases)
        XCTAssertEqual(Set(knownMethods).count, CodexAppServerProtocolInventory.notificationMethodCount)
        XCTAssertFalse(notifications.contains { notification in
            if case .unknown = notification.payload { return true }
            return false
        })
        XCTAssertFalse(notifications.contains { $0.schemaDefinition == nil })
        XCTAssertTrue(notifications.allSatisfy { $0.schemaValue.rawValue == .dictionary([:]) })
    }

    func testHighLevelTurnTextDeltasReplayPendingEvents() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        let thread = try await codex.threadStart(cwd: "/tmp")
        let handle = try await thread.turn("hi")

        let deltaNotification = """
        {
            "jsonrpc": "2.0",
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "\(thread.id)",
                "turnId": "\(handle.id)",
                "itemId": "item-agent",
                "delta": "streamed"
            }
        }
        """

        let turnCompleted = """
        {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "\(thread.id)",
                "turn": {
                    "id": "\(handle.id)",
                    "status": { "type": "completed" }
                }
            }
        }
        """

        await transport.receiveMessage(deltaNotification)
        await transport.receiveMessage(turnCompleted)

        let deltaExpectation = expectation(description: "high-level text delta replays")
        let finishExpectation = expectation(description: "high-level text stream finishes")
        Task {
            var iterator = handle.textDeltas().makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertEqual(first, "streamed")
            deltaExpectation.fulfill()

            let finished = await iterator.next()
            XCTAssertNil(finished)
            finishExpectation.fulfill()
        }

        await fulfillment(of: [deltaExpectation, finishExpectation], timeout: 2.0)
        await codex.close()
    }

    func testLoginNotificationStreamReplaysCompletion() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let response = try await client.accountLoginStart(.chatgpt())
        guard case .chatgpt(let loginId, let authUrl) = response else {
            XCTFail("Expected chatgpt login response")
            return
        }
        XCTAssertEqual(loginId, "login-mock")
        XCTAssertEqual(authUrl, "https://example.com/auth")

        let completedNotification = """
        {
            "jsonrpc": "2.0",
            "method": "account/login/completed",
            "params": {
                "loginId": "\(loginId)",
                "status": "success"
            }
        }
        """
        await transport.receiveMessage(completedNotification)

        let replayExpectation = expectation(description: "login stream replays completion")
        let finishExpectation = expectation(description: "login stream finishes on completion")
        let loginStream = client.loginNotifications(loginId: loginId)
        Task {
            var iterator = loginStream.makeAsyncIterator()
            let notification = await iterator.next()
            XCTAssertEqual(notification?.method, "account/login/completed")
            if case .accountLoginCompleted(let payload)? = notification?.payload {
                XCTAssertEqual(payload.loginId, loginId)
            } else {
                XCTFail("Expected typed login completion payload")
            }
            replayExpectation.fulfill()

            let finished = await iterator.next()
            XCTAssertNil(finished)
            finishExpectation.fulfill()
        }

        await fulfillment(of: [replayExpectation, finishExpectation], timeout: 2.0)
        await client.disconnect()
    }

    func testHighLevelLoginHandlesMatchPythonSDKSurface() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        let chatgpt = try await codex.loginChatgpt()
        XCTAssertEqual(chatgpt.loginId, "login-mock")
        XCTAssertEqual(chatgpt.authUrl, "https://example.com/auth")

        let completedNotification = """
        {
            "jsonrpc": "2.0",
            "method": "account/login/completed",
            "params": {
                "loginId": "\(chatgpt.loginId)",
                "status": "success"
            }
        }
        """
        await transport.receiveMessage(completedNotification)
        let completion = try await chatgpt.wait()
        XCTAssertEqual(completion.loginId, chatgpt.loginId)

        let deviceCode = try await codex.loginChatgptDeviceCode()
        XCTAssertEqual(deviceCode.loginId, "login-mock")
        XCTAssertEqual(deviceCode.verificationUrl, "https://example.com/device")
        XCTAssertEqual(deviceCode.userCode, "ABCD-EFGH")
        _ = try await deviceCode.cancel()

        try await codex.loginChatgptAuthTokens(
            accessToken: "access-token",
            chatgptAccountId: "account-id",
            chatgptPlanType: "pro"
        )

        let sentPayloads = await transport.sentPayloads
        let loginPayloads = sentPayloads.filter { $0["method"]?.description == "account/login/start" }
        let loginTypes = loginPayloads.compactMap { payload -> String? in
            guard case .dictionary(let params)? = payload["params"], case .string(let type)? = params["type"] else {
                return nil
            }
            return type
        }
        XCTAssertEqual(loginTypes, ["chatgpt", "chatgptDeviceCode", "chatgptAuthTokens"])

        let cancelPayload = sentPayloads.last { $0["method"]?.description == "account/login/cancel" }
        if case .dictionary(let params)? = cancelPayload?["params"] {
            XCTAssertEqual(params["loginId"], .string(deviceCode.loginId))
        } else {
            XCTFail("account/login/cancel params missing")
        }

        await codex.close()
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

    private func sendServerRequest(
        method: CodexAppServerServerRequestMethod,
        id: CodexJSONValue,
        params: [String: CodexJSONValue],
        transport: MockTransport
    ) async throws -> [String: CodexJSONValue] {
        let payload: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method.rawValue),
            "params": .dictionary(params)
        ]
        let data = try JSONEncoder().encode(payload)
        guard let message = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to encode server request")
            return [:]
        }

        await transport.receiveMessage(message)
        for _ in 0..<100 {
            let sent = await transport.sentPayloads
            if let reply = sent.last(where: { $0["id"] == id && $0["result"] != nil }) {
                return reply
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("No reply for server request \(method.rawValue)")
        return [:]
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
