import XCTest
@testable import CodexCore

final class CodexClientNotificationStreamTests: XCTestCase {

    func testLoginWaitAcceptsScopedFailureWithoutLoginID() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        let wait = Task {
            try await client.waitForLoginCompleted(loginId: "login-1")
        }
        try await Task.sleep(for: .milliseconds(50))
        await transport.receiveMessage(
            #"{"jsonrpc":"2.0","method":"account/login/completed","params":{"success":false,"error":"denied"}}"#
        )

        let completion = try await wait.value
        XCTAssertNil(completion.loginId)
        XCTAssertFalse(completion.success)
        XCTAssertEqual(completion.error, "denied")

        await client.disconnect()
    }

    func testGenericStructuredErrorsRemainActiveWhileRetrying() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        try await client.connect()

        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"thread-1","status":{"type":"idle"}}}}"#)
        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"inProgress","items":[]}}}"#)
        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"error","params":{"threadId":"thread-1","turnId":"turn-1","willRetry":true,"error":{"message":"temporary overload"}}}"#)

        for _ in 0..<20 where await store.activeThread?.turns.first?.status != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }
        var activeTurn = await store.activeThread?.turns.first
        XCTAssertEqual(activeTurn?.status, .running)
        XCTAssertNil(activeTurn?.error)

        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"error","params":{"threadId":"thread-1","turnId":"turn-1","willRetry":false,"error":{"message":"terminal overload"}}}"#)
        for _ in 0..<20 where await store.activeThread?.turns.first?.status != .failed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        activeTurn = await store.activeThread?.turns.first
        XCTAssertEqual(activeTurn?.status, .failed)
        XCTAssertEqual(activeTurn?.error, "terminal overload")

        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-2","status":"inProgress","items":[]}}}"#)
        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-2","status":"failed","error":{"message":"completion failure"},"items":[]}}}"#)
        for _ in 0..<20 where await store.activeThread?.turns.last?.status != .failed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completedTurn = await store.activeThread?.turns.last
        XCTAssertEqual(completedTurn?.status, .failed)
        XCTAssertEqual(completedTurn?.error, "completion failure")

        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-3","status":"inProgress","items":[]}}}"#)
        await transport.receiveMessage(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-3","status":"failed","items":[]}}}"#)
        for _ in 0..<20 where await store.activeThread?.turns.last?.status != .failed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let statusOnlyFailure = await store.activeThread?.turns.last
        XCTAssertEqual(statusOnlyFailure?.id, "turn-3")
        XCTAssertEqual(statusOnlyFailure?.status, .failed)

        await client.disconnect()
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
        let threadId = try await client.threadStart(ThreadStartParams(cwd: "/tmp")).thread.id
        let turnId = try await client.turnStart(TurnStartParams(threadId: threadId, input: [.text("hi")])).turn.id

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
                    "status": "completed",
                    "items": []
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
                    "status": "completed",
                    "items": []
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
                "success": true
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
                "success": true
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
        let hasCompleted = await session.hasCompleted
        XCTAssertTrue(hasCompleted)

        let writePayload = sentPayloads.last { $0["method"]?.description == "command/exec/write" }
        let resizePayload = sentPayloads.last { $0["method"]?.description == "command/exec/resize" }
        let terminatePayload = sentPayloads.last { $0["method"]?.description == "command/exec/terminate" }
        XCTAssertNotNil(writePayload)
        XCTAssertNotNil(resizePayload)
        XCTAssertNotNil(terminatePayload)

        await client.disconnect()
    }
}
