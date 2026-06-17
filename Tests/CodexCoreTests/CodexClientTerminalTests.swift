import XCTest
import SwiftUI
@testable import CodexCore

// MARK: - Test Suite

final class CodexClientTerminalTests: XCTestCase {

    func testFuzzyFileSearchDecodesResults() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let response = try await client.fuzzyFileSearch(query: "cli", roots: ["/repo"])
        XCTAssertEqual(response.files.count, 2)
        let first = try XCTUnwrap(response.files.first)
        XCTAssertEqual(first.fileName, "Client.swift")
        XCTAssertEqual(first.matchType, .file)
        XCTAssertEqual(first.path, "Sources/CodexCore/Client/Client.swift")
        XCTAssertEqual(first.absolutePath, "/repo/Sources/CodexCore/Client/Client.swift")
        XCTAssertEqual(first.indices, [0, 1, 2])

        // The request must carry query + roots and route through the enum method.
        let sent = await transport.sentPayloads
        let searchPayload = sent.first { ($0["method"]?.description ?? "") == "fuzzyFileSearch" }
        XCTAssertNotNil(searchPayload)
        if case .dictionary(let params)? = searchPayload?["params"] {
            XCTAssertEqual(params["query"], .string("cli"))
            XCTAssertEqual(params["roots"], .array([.string("/repo")]))
        } else {
            XCTFail("fuzzyFileSearch params missing")
        }

        await client.disconnect()
    }

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

        let tokenUsage = """
        {
            "jsonrpc": "2.0",
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": "thread-mock",
                "turnId": "turn-mock",
                "tokenUsage": {
                    "total": {
                        "inputTokens": 7,
                        "outputTokens": 3
                    }
                }
            }
        }
        """

        await transport.receiveMessage(itemCompleted)
        await transport.receiveMessage(tokenUsage)
        await transport.receiveMessage(turnCompleted)

        let result = try await runTask.value
        XCTAssertEqual(result.id, "turn-mock")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.finalResponse, "hi")
        XCTAssertEqual(result.items.count, 1)
        if case .dictionary(let total)? = result.usage?.raw["total"] {
            XCTAssertEqual(total["inputTokens"], .int(7))
            XCTAssertEqual(total["outputTokens"], .int(3))
        } else {
            XCTFail("Expected turn result token usage")
        }
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

        let retryLimit = mapJSONRPCError(code: -32000, message: "retry limit reached", data: overloadData)
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

    func testClientNotificationWaitAndTextStreamConveniences() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let typedAccount = try await client.request(
            method: "account/read",
            params: ["refreshToken": .bool(false)],
            response: GetAccountResponse.self
        )
        XCTAssertFalse(typedAccount.requiresOpenAIAuth)

        try await client.notify(method: "initialized", params: ["ready": .bool(true)])
        let notifyPayload = await transport.sentPayloads.last { $0["method"]?.description == "initialized" }
        XCTAssertEqual(notifyPayload?["id"], nil)
        if case .dictionary(let params)? = notifyPayload?["params"] {
            XCTAssertEqual(params["ready"], .bool(true))
        } else {
            XCTFail("notify params missing")
        }

        let turnWait = Task {
            try await client.waitForTurnCompleted(turnId: "turn-wait")
        }
        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "thread-wait",
                "turn": {
                    "id": "turn-wait",
                    "status": { "type": "completed" }
                }
            }
        }
        """)
        let completed = try await turnWait.value
        XCTAssertEqual(completed.turn.id, "turn-wait")

        let loginWait = Task {
            try await client.waitForLoginCompleted(loginId: "login-wait")
        }
        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "account/login/completed",
            "params": {
                "loginId": "login-wait",
                "status": "success"
            }
        }
        """)
        let login = try await loginWait.value
        XCTAssertEqual(login.loginId, "login-wait")

        let textStream = client.streamText(
            threadId: "thread-stream",
            text: "hello",
            params: ["model": .string("test-model")]
        )
        let deltas = Task { () throws -> [String] in
            var chunks: [String] = []
            for try await delta in textStream {
                chunks.append(delta.delta)
            }
            return chunks
        }

        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "thread-stream",
                "turnId": "turn-mock",
                "itemId": "item-stream",
                "delta": "chunk"
            }
        }
        """)
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "thread-stream",
                "turn": {
                    "id": "turn-mock",
                    "status": { "type": "completed" }
                }
            }
        }
        """)

        let streamedDeltas = try await deltas.value
        XCTAssertEqual(streamedDeltas, ["chunk"])
        let turnStartPayload = await transport.sentPayloads.last { $0["method"]?.description == "turn/start" }
        if case .dictionary(let params)? = turnStartPayload?["params"],
           case .array(let input)? = params["input"] {
            XCTAssertEqual(params["model"], .string("test-model"))
            XCTAssertEqual(input, [.dictionary(["type": .string("text"), "text": .string("hello")])])
        } else {
            XCTFail("streamText turn/start params missing")
        }

        await client.disconnect()
    }

    func testDefaultCodexHomeMatchesPythonSDKHelper() {
        XCTAssertEqual(defaultCodexHome(), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
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

    func testHighLevelCodexThreadMethodsUseTypedPythonParitySurface() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        XCTAssertEqual(codex.metadata.userAgent, "codex/1.0.0")

        try await codex.loginAPIKey("sk-test")
        let account = try await codex.account(refreshToken: true)
        XCTAssertFalse(account.requiresOpenAIAuth)

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
        XCTAssertNil(modelList.models)
        XCTAssertEqual(modelList.data?.count, 3)
        if case .dictionary(let firstModel)? = modelList.data?.first,
           case .array(let reasoningEfforts)? = firstModel["supportedReasoningEfforts"] {
            XCTAssertEqual(firstModel["id"], .string("gpt-5.5"))
            XCTAssertEqual(firstModel["displayName"], .string("GPT-5.5"))
            XCTAssertEqual(firstModel["defaultReasoningEffort"], .string("medium"))
            XCTAssertEqual(reasoningEfforts.count, 4)
        } else {
            XCTFail("model/list response missing live app-server model shape")
        }
        let skillsList = try await codex.skillsListRaw(cwds: ["/tmp"], forceReload: true)
        if case .dictionary(let skillsObject) = skillsList,
           case .array(let data)? = skillsObject["data"] {
            XCTAssertEqual(data.count, 1)
        } else {
            XCTFail("skills/list response missing data")
        }
        let permissionProfiles = try await codex.permissionProfileListRaw()
        if case .dictionary(let profileObject) = permissionProfiles,
           case .array(let data)? = profileObject["data"] {
            XCTAssertEqual(data.count, 3)
        } else {
            XCTFail("permissionProfile/list response missing data")
        }
        let collaborationModes = try await codex.collaborationModeListRaw()
        if case .dictionary(let modeObject) = collaborationModes,
           case .array(let data)? = modeObject["data"] {
            XCTAssertEqual(data.count, 2)
        } else {
            XCTFail("collaborationMode/list response missing data")
        }
        let mcpList = try await codex.mcpServerStatusListRaw(threadId: thread.id, detail: "toolsAndAuthOnly", limit: 25)
        if case .dictionary(let mcpObject) = mcpList,
           case .array(let data)? = mcpObject["data"] {
            XCTAssertEqual(data.count, 1)
        } else {
            XCTFail("mcpServerStatus/list response missing data")
        }
        let pluginList = try await codex.pluginListRaw(cwds: ["/tmp"])
        if case .dictionary(let pluginObject) = pluginList,
           case .array(let marketplaces)? = pluginObject["marketplaces"] {
            XCTAssertEqual(marketplaces.count, 1)
        } else {
            XCTFail("plugin/list response missing marketplaces")
        }
        let searchResults = try await codex.threadSearchRaw(searchTerm: "needle", limit: 10)
        if case .dictionary(let searchObject) = searchResults,
           case .array(let data)? = searchObject["data"] {
            XCTAssertEqual(data.count, 1)
        } else {
            XCTFail("thread/search response missing data")
        }
        let setGoal = try await thread.setGoal(objective: "Ship Swift goal parity", tokenBudget: 4096)
        XCTAssertEqual(setGoal.goal.threadId, "thread-mock")
        XCTAssertEqual(setGoal.goal.objective, "Ship Swift goal parity")
        XCTAssertEqual(setGoal.goal.status, .active)
        XCTAssertEqual(setGoal.goal.tokenBudget, 4096)

        let currentGoal = try await thread.goal()
        XCTAssertEqual(currentGoal.goal?.tokensUsed, 12)
        XCTAssertEqual(currentGoal.goal?.timeUsedSeconds, 3)

        let clearedGoal = try await thread.clearGoal()
        XCTAssertTrue(clearedGoal.cleared)

        _ = try await thread.compact()

        let handle = try await thread.turn(
            [.text("hi"), .localImage(path: "/tmp/a.png")],
            model: "test-model",
            sandbox: .workspaceWrite,
            params: ["collaborationMode": .string("plan")]
        )
        XCTAssertEqual(handle.id, "turn-mock")

        let sentPayloads = await transport.sentPayloads
        let mcpStatusPayload = sentPayloads.last { $0["method"]?.description == "mcpServerStatus/list" }
        if case .dictionary(let params)? = mcpStatusPayload?["params"] {
            XCTAssertEqual(params["threadId"], .string("thread-mock"))
            XCTAssertEqual(params["detail"], .string("toolsAndAuthOnly"))
            XCTAssertEqual(params["limit"], .int(25))
        } else {
            XCTFail("mcpServerStatus/list params missing")
        }

        let pluginListPayload = sentPayloads.last { $0["method"]?.description == "plugin/list" }
        if case .dictionary(let params)? = pluginListPayload?["params"],
           case .array(let cwds)? = params["cwds"] {
            XCTAssertEqual(cwds, [.string("/tmp")])
        } else {
            XCTFail("plugin/list params missing")
        }

        let compactPayload = sentPayloads.last { $0["method"]?.description == "thread/compact/start" }
        if case .dictionary(let params)? = compactPayload?["params"] {
            XCTAssertEqual(params["threadId"], .string("thread-mock"))
        } else {
            XCTFail("thread/compact/start params missing")
        }

        let goalSetPayload = sentPayloads.last { $0["method"]?.description == "thread/goal/set" }
        if case .dictionary(let params)? = goalSetPayload?["params"] {
            XCTAssertEqual(params["threadId"], .string("thread-mock"))
            XCTAssertEqual(params["objective"], .string("Ship Swift goal parity"))
            XCTAssertEqual(params["status"], .string(ThreadGoalStatus.active.rawValue))
            XCTAssertEqual(params["tokenBudget"], .int(4096))
        } else {
            XCTFail("thread/goal/set params missing")
        }

        let goalGetPayload = sentPayloads.last { $0["method"]?.description == "thread/goal/get" }
        if case .dictionary(let params)? = goalGetPayload?["params"] {
            XCTAssertEqual(params["threadId"], .string("thread-mock"))
        } else {
            XCTFail("thread/goal/get params missing")
        }

        let goalClearPayload = sentPayloads.last { $0["method"]?.description == "thread/goal/clear" }
        if case .dictionary(let params)? = goalClearPayload?["params"] {
            XCTAssertEqual(params["threadId"], .string("thread-mock"))
        } else {
            XCTFail("thread/goal/clear params missing")
        }

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
            XCTAssertEqual(params["collaborationMode"], .string("plan"))
        } else {
            XCTFail("turn/start params missing")
        }

        let skillsListPayload = sentPayloads.last { $0["method"]?.description == "skills/list" }
        if case .dictionary(let params)? = skillsListPayload?["params"] {
            XCTAssertEqual(params["cwds"], .array([.string("/tmp")]))
            XCTAssertEqual(params["forceReload"], .bool(true))
        } else {
            XCTFail("skills/list params missing")
        }

        let searchPayload = sentPayloads.last { $0["method"]?.description == "thread/search" }
        if case .dictionary(let params)? = searchPayload?["params"] {
            XCTAssertEqual(params["searchTerm"], .string("needle"))
            XCTAssertEqual(params["limit"], .int(10))
            XCTAssertEqual(params["archived"], .bool(false))
            XCTAssertEqual(params["sortDirection"], .string(SortDirection.desc.rawValue))
            XCTAssertEqual(params["sortKey"], .string(ThreadSortKey.updatedAt.rawValue))
        } else {
            XCTFail("thread/search params missing")
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

    func testSkillsChangedNotificationStreamsWithoutTimelineMutation() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let notificationExpectation = expectation(description: "skills changed notification streamed")
        let collector = Task {
            for await notification in client.notifications() {
                if notification.knownMethod == .skillsChanged {
                    notificationExpectation.fulfill()
                    break
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "skills/changed",
            "params": {}
        }
        """)

        await fulfillment(of: [notificationExpectation], timeout: 2.0)
        collector.cancel()

        let activeThread = await store.activeThread
        XCTAssertNil(activeThread)
    }

    func testThreadGoalNotificationsUpdateStore() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "thread/started",
            "params": {
                "thread": {
                    "id": "thread-mock",
                    "status": { "type": "idle" }
                }
            }
        }
        """)

        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "thread/goal/updated",
            "params": {
                "threadId": "thread-mock",
                "turnId": null,
                "goal": {
                    "threadId": "thread-mock",
                    "objective": "Reach app parity",
                    "status": "active",
                    "tokenBudget": 2048,
                    "tokensUsed": 42,
                    "timeUsedSeconds": 7,
                    "createdAt": 1781075531,
                    "updatedAt": 1781075540
                }
            }
        }
        """)

        var deadline = Date().addingTimeInterval(2.0)
        while await store.activeThread?.goal == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        var activeThread = await store.activeThread
        XCTAssertEqual(activeThread?.goal?.objective, "Reach app parity")
        XCTAssertEqual(activeThread?.goal?.status, .active)
        XCTAssertEqual(activeThread?.goal?.tokensUsed, 42)

        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "method": "thread/goal/cleared",
            "params": {
                "threadId": "thread-mock"
            }
        }
        """)

        deadline = Date().addingTimeInterval(2.0)
        while await store.activeThread?.goal != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        activeThread = await store.activeThread
        XCTAssertNil(activeThread?.goal)

        await client.disconnect()
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

        let chatgpt = try await codex.loginChatGPT()
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

        let deviceCode = try await codex.loginChatGPTDeviceCode()
        XCTAssertEqual(deviceCode.loginId, "login-mock")
        XCTAssertEqual(deviceCode.verificationUrl, "https://example.com/device")
        XCTAssertEqual(deviceCode.userCode, "ABCD-EFGH")
        _ = try await deviceCode.cancel()

        try await codex.loginChatGPTAuthTokens(
            accessToken: "access-token",
            chatGPTAccountID: "account-id",
            chatGPTPlanType: "pro"
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

    func sendServerRequest(
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


}
