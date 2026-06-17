import XCTest
@testable import CodexCore

extension CodexClientTerminalTests {
    func testTypedClientMethodsUsePythonSDKWireMethods() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store)
        let metadata = try await client.connect(clientName: "test", clientTitle: "Test", clientVersion: "0.1", experimentalAPI: false)

        XCTAssertEqual(metadata.serverInfo?.name, "codex")

        _ = try await client.accountLoginStart(.apiKey("sk-test"))
        let account = try await client.accountRead(GetAccountParams(refreshToken: true))
        XCTAssertFalse(account.requiresOpenAIAuth)

        let forked = try await client.threadFork(threadId: "thread-mock")
        XCTAssertEqual(forked.thread.id, "thread-fork")

        let listed = try await client.threadList(ThreadListParams(limit: 1, sortDirection: .desc, sortKey: .updatedAt))
        XCTAssertEqual(listed.data?.first?.id, "thread-mock")

        let models = try await client.modelList(includeHidden: true)
        XCTAssertNil(models.models)
        XCTAssertEqual(models.data?.count, 3)
        if case .dictionary(let firstModel)? = models.data?.first {
            XCTAssertEqual(firstModel["displayName"], .string("GPT-5.5"))
        } else {
            XCTFail("model/list response missing first model")
        }

        _ = try await client.threadCompact(threadId: "thread-mock")

        let methods = await transport.sentPayloads.compactMap { $0["method"]?.description }
        XCTAssertTrue(methods.contains("account/login/start"))
        XCTAssertTrue(methods.contains("account/read"))
        XCTAssertTrue(methods.contains("thread/fork"))
        XCTAssertTrue(methods.contains("thread/list"))
        XCTAssertTrue(methods.contains("model/list"))
        XCTAssertTrue(methods.contains("thread/compact/start"))

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
            (.accountChatGPTAuthTokensRefresh, .int(7), ["reason": .string("unauthorized")], .dictionary([:])),
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

        // Auto policies answer on the wire without publishing pending UI state:
        // a request that is already decided must never dangle in the store.
        let activeThread = await store.activeThread
        XCTAssertEqual(activeThread?.pendingApprovals.count, 0)
        let storePending = await store.pendingApprovals
        XCTAssertTrue(storePending.isEmpty)
        let pendingInput = await store.pendingUserInput
        XCTAssertNil(pendingInput)

        await client.disconnect()
    }

    func testAskPolicyPublishesApprovalKindsAndQuestions() async throws {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store, approvalPolicy: .ask)
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

        let requests: [(CodexAppServerServerRequestMethod, CodexJSONValue, [String: CodexJSONValue])] = [
            (.itemCommandExecutionRequestApproval, .int(101), baseParams.merging(["command": .string("echo hi")]) { _, new in new }),
            (.itemFileChangeRequestApproval, .int(102), baseParams),
            (.itemPermissionsRequestApproval, .int(103), baseParams.merging(["permissions": .dictionary([:])]) { _, new in new }),
            (.itemToolRequestUserInput, .int(104), baseParams.merging([
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
            ]) { _, new in new })
        ]

        for (method, id, params) in requests {
            let frame: [String: CodexJSONValue] = [
                "jsonrpc": .string("2.0"),
                "id": id,
                "method": .string(method.rawValue),
                "params": .dictionary(params)
            ]
            let data = try JSONEncoder().encode(frame)
            await transport.receiveMessage(String(decoding: data, as: UTF8.self))
        }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let approvals = await store.pendingApprovals
            let input = await store.pendingUserInput
            if approvals.count == 3, input != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let pendingApprovals = await store.pendingApprovals
        XCTAssertEqual(pendingApprovals.map(\.kind), [.command, .fileChange, .permissions])
        let activeThread = await store.activeThread
        XCTAssertEqual(activeThread?.pendingApprovals.map(\.kind), [.command, .fileChange, .permissions])
        XCTAssertEqual(activeThread?.status, .waiting)

        let pendingInput = await store.pendingUserInput
        XCTAssertEqual(pendingInput?.questions.first?.id, "question-1")
        XCTAssertEqual(pendingInput?.questions.first?.options.first?.label, "Yes")
        XCTAssertEqual(pendingInput?.questions.first?.isSecret, true)
        XCTAssertEqual(pendingInput?.questions.first?.isOtherAllowed, true)

        for approval in pendingApprovals {
            await client.resolveApproval(requestId: approval.id, decision: .decline)
        }
        if let pendingInput {
            await client.resolveUserInput(requestId: pendingInput.id, answers: [:])
        }
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

}
