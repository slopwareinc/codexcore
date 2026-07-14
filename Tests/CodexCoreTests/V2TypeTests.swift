import XCTest
@testable import CodexCore

final class V2TypeTests: XCTestCase {
    func testGeneratedTurnProjectionRetainsStructuredErrorAndTiming() throws {
        let schemaError = CodexSchemaTurnError(
            additionalDetails: "request 42",
            message: "failed"
        )
        let turn = AppServerTurn(CodexSchemaTurn(
            completedAt: 20,
            durationMs: 10_000,
            error: schemaError,
            id: "turn-1",
            items: [],
            startedAt: 10,
            status: .failed
        ))

        XCTAssertEqual(turn.id, "turn-1")
        XCTAssertEqual(turn.status, .failed)
        XCTAssertEqual(turn.error?.message, "failed")
        XCTAssertEqual(turn.startedAt, 10)
        XCTAssertEqual(turn.completedAt, 20)
        XCTAssertEqual(turn.durationMs, 10_000)
    }

    func testKnownGeneratedDriftFieldsAreRepresented() throws {
        XCTAssertEqual(try CodexJSONValue(encoding: ThreadSortKey.recencyAt), .string("recency_at"))
    }

    func testCurrentThreadAndTurnOptionsEncodeWithWireNames() throws {
        let start = ThreadStartParams(
            cwd: "/tmp/project",
            allowProviderModelFallback: true,
            historyMode: .paginated,
            permissions: "workspace",
            runtimeWorkspaceRoots: ["/tmp/project"]
        )
        let startValue = try CodexJSONValue(encoding: start)
        let startObject = try XCTUnwrap(startValue.objectValue)
        XCTAssertEqual(startObject["allowProviderModelFallback"], CodexJSONValue.bool(true))
        XCTAssertEqual(startObject["historyMode"], CodexJSONValue.string("paginated"))
        XCTAssertEqual(startObject["permissions"], CodexJSONValue.string("workspace"))
        XCTAssertEqual(startObject["runtimeWorkspaceRoots"], CodexJSONValue.array([.string("/tmp/project")]))

        let list = ThreadListParams(ancestorThreadId: "ancestor", parentThreadId: nil)
        let listValue = try CodexJSONValue(encoding: list)
        XCTAssertEqual(try XCTUnwrap(listValue.objectValue)["ancestorThreadId"], CodexJSONValue.string("ancestor"))

        let turn = TurnStartParams(
            threadId: "thread-1",
            input: [.text("hello")],
            clientUserMessageId: "message-1",
            permissions: "workspace",
            runtimeWorkspaceRoots: ["/tmp/project"]
        )
        let turnValue = try CodexJSONValue(encoding: turn)
        let turnObject = try XCTUnwrap(turnValue.objectValue)
        XCTAssertEqual(turnObject["clientUserMessageId"], CodexJSONValue.string("message-1"))
        XCTAssertEqual(turnObject["permissions"], CodexJSONValue.string("workspace"))
        XCTAssertEqual(turnObject["runtimeWorkspaceRoots"], CodexJSONValue.array([.string("/tmp/project")]))
    }

    func testInitializeResponseDecodesCodexHome() throws {
        let response = try CodexJSONValue.dictionary([
            "codexHome": .string("/tmp/codex-home"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex-cli/0.144.1")
        ]).decode(InitializeResponse.self)

        XCTAssertEqual(response.codexHome, "/tmp/codex-home")
    }

    func testInputWireMappingMatchesPythonSDK() {
        XCTAssertEqual(CodexInput.text("hi").jsonValue, .dictionary(["type": .string("text"), "text": .string("hi")]))
        XCTAssertEqual(CodexInput.image(url: "https://example.com/a.png").jsonValue, .dictionary(["type": .string("image"), "url": .string("https://example.com/a.png")]))
        XCTAssertEqual(CodexInput.localImage(path: "/tmp/a.png").jsonValue, .dictionary(["type": .string("localImage"), "path": .string("/tmp/a.png")]))
        XCTAssertEqual(CodexInput.skill(name: "docs", path: "/skills/docs").jsonValue, .dictionary(["type": .string("skill"), "name": .string("docs"), "path": .string("/skills/docs")]))
        XCTAssertEqual(CodexInput.mention(name: "README", path: "README.md").jsonValue, .dictionary(["type": .string("mention"), "name": .string("README"), "path": .string("README.md")]))
    }

    func testDynamicToolSpecEncodesInThreadStartParams() throws {
        let params = ThreadStartParams(
            cwd: "/tmp/walkable",
            dynamicTools: [
                CodexDynamicToolSpec(
                    name: "save_notebook_entry",
                    description: "Save a project notebook entry.",
                    inputSchema: .dictionary([
                        "type": .string("object"),
                        "required": .array([.string("title")]),
                        "properties": .dictionary([
                            "title": .dictionary(["type": .string("string")])
                        ])
                    ]),
                    namespace: "walkable",
                    deferLoading: true
                )
            ],
            serviceName: "walkable"
        )

        let value = try CodexJSONValue(encoding: params)

        XCTAssertEqual(value.objectValue?["dynamicTools"], .array([
            .dictionary([
                "deferLoading": .bool(true),
                "description": .string("Save a project notebook entry."),
                "inputSchema": .dictionary([
                    "type": .string("object"),
                    "required": .array([.string("title")]),
                    "properties": .dictionary([
                        "title": .dictionary(["type": .string("string")])
                    ])
                ]),
                "name": .string("save_notebook_entry"),
                "namespace": .string("walkable")
            ])
        ]))
    }

    func testDynamicToolCallParsingAndResponseEncoding() throws {
        let request = JSONRPCServerRequest(
            id: .int(42),
            method: CodexAppServerServerRequestMethod.itemToolCall.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "callId": .string("call-1"),
                "tool": .string("save_notebook_entry"),
                "arguments": .dictionary(["title": .string("Groove map")])
            ]
        )

        let call = try XCTUnwrap(request.dynamicToolCall)
        XCTAssertEqual(call.requestID, .int(42))
        XCTAssertEqual(call.threadID, "thread-1")
        XCTAssertEqual(call.turnID, "turn-1")
        XCTAssertEqual(call.callID, "call-1")
        XCTAssertEqual(call.tool, "save_notebook_entry")
        XCTAssertEqual(call.argumentsObject, ["title": .string("Groove map")])

        XCTAssertEqual(
            CodexDynamicToolResponse.success(text: "Saved.").jsonValue,
            .dictionary([
                "success": .bool(true),
                "contentItems": .array([
                    .dictionary([
                        "type": .string("inputText"),
                        "text": .string("Saved.")
                    ])
                ])
            ])
        )
    }

    func testDynamicToolCallRejectsLegacyItemIdentifierShape() {
        let request = JSONRPCServerRequest(
            id: .int(42),
            method: CodexAppServerServerRequestMethod.itemToolCall.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("legacy-item-1"),
                "tool": .string("save_notebook_entry"),
                "arguments": .dictionary([:])
            ]
        )

        XCTAssertNil(request.dynamicToolCall)
    }

    func testStructuredCommandApprovalDecisionsRoundTrip() throws {
        let decisions: [CodexCommandApprovalDecision] = [
            .accept,
            .acceptWithExecpolicyAmendment(["git", "status"]),
            .applyNetworkPolicyAmendment(.init(action: .deny, host: "example.com")),
            .decline
        ]

        for decision in decisions {
            let encoded = try CodexJSONValue(encoding: decision)
            XCTAssertEqual(try encoded.decode(CodexCommandApprovalDecision.self), decision)
            XCTAssertEqual(encoded, decision.jsonValue)
        }
    }

    func testApprovalModeMappingMatchesPythonSDK() {
        XCTAssertEqual(ApprovalMode.autoReview.settings.approvalPolicy, .onRequest)
        XCTAssertEqual(ApprovalMode.autoReview.settings.approvalsReviewer, .autoReview)
        XCTAssertEqual(ApprovalMode.denyAll.settings.approvalPolicy, .never)
        XCTAssertNil(ApprovalMode.denyAll.settings.approvalsReviewer)
    }

    func testSandboxMappingMatchesPythonSDK() {
        XCTAssertEqual(Sandbox.readOnly.threadMode, .readOnly)
        XCTAssertEqual(Sandbox.workspaceWrite.threadMode, .workspaceWrite)
        XCTAssertEqual(Sandbox.fullAccess.threadMode, .dangerFullAccess)
        XCTAssertEqual(Sandbox.readOnly.turnPolicy, .dictionary(["type": .string("readOnly")]))
        XCTAssertEqual(Sandbox.workspaceWrite.turnPolicy, .dictionary(["type": .string("workspaceWrite")]))
        XCTAssertEqual(Sandbox.fullAccess.turnPolicy, .dictionary(["type": .string("dangerFullAccess")]))
    }

    func testLoginParamsEncodeAsRootUnionObjects() throws {
        let value = try CodexJSONValue(encoding: LoginAccountParams.apiKey("sk-test"))
        XCTAssertEqual(value, .dictionary(["type": .string("apiKey"), "apiKey": .string("sk-test")]))

        let deviceCode = try CodexJSONValue(encoding: LoginAccountParams.chatgptDeviceCode)
        XCTAssertEqual(deviceCode, .dictionary(["type": .string("chatgptDeviceCode")]))
    }

    func testLoginResponsesDecodeRootUnionObjects() throws {
        let browser = try CodexJSONValue.dictionary([
            "type": .string("chatgpt"),
            "loginId": .string("login-1"),
            "authUrl": .string("https://example.com/auth")
        ]).decode(LoginAccountResponse.self)
        XCTAssertEqual(browser, .chatgpt(loginId: "login-1", authUrl: "https://example.com/auth"))

        let device = try CodexJSONValue.dictionary([
            "type": .string("chatgptDeviceCode"),
            "loginId": .string("login-2"),
            "verificationUrl": .string("https://example.com/device"),
            "userCode": .string("ABCD")
        ]).decode(LoginAccountResponse.self)
        XCTAssertEqual(device, .chatgptDeviceCode(loginId: "login-2", verificationUrl: "https://example.com/device", userCode: "ABCD"))
    }

    func testTurnStatusDecodesNestedStatusShapeFromAppServer() throws {
        let turn = try CodexJSONValue.dictionary([
            "id": .string("turn-1"),
            "status": .dictionary(["type": .string("completed")])
        ]).decode(AppServerTurn.self)

        XCTAssertEqual(turn.id, "turn-1")
        XCTAssertEqual(turn.status, .completed)
    }

    func testThreadGoalWireTypesMatchAppServerShape() throws {
        let params = try CodexJSONValue(encoding: ThreadGoalSetParams(
            threadId: "thread-1",
            objective: "Ship parity",
            status: .active,
            tokenBudget: 4096
        ))
        XCTAssertEqual(params, .dictionary([
            "threadId": .string("thread-1"),
            "objective": .string("Ship parity"),
            "status": .string("active"),
            "tokenBudget": .int(4096)
        ]))

        let response = try CodexJSONValue.dictionary([
            "goal": .dictionary([
                "threadId": .string("thread-1"),
                "objective": .string("Ship parity"),
                "status": .string("usageLimited"),
                "tokenBudget": .int(4096),
                "tokensUsed": .int(4096),
                "timeUsedSeconds": .int(90),
                "createdAt": .int(1781075531),
                "updatedAt": .int(1781075540)
            ])
        ]).decode(ThreadGoalSetResponse.self)

        XCTAssertEqual(response.goal.threadId, "thread-1")
        XCTAssertEqual(response.goal.status, .usageLimited)
        XCTAssertEqual(response.goal.tokenBudget, 4096)
        XCTAssertEqual(response.goal.tokensUsed, 4096)

        let update = try CodexJSONValue.dictionary([
            "threadId": .string("thread-1"),
            "turnId": .null,
            "goal": .dictionary([
                "threadId": .string("thread-1"),
                "objective": .string("Ship parity"),
                "status": .string("complete"),
                "tokenBudget": .null,
                "tokensUsed": .int(512),
                "timeUsedSeconds": .int(45),
                "createdAt": .int(1781075531),
                "updatedAt": .int(1781075600)
            ])
        ]).decode(ThreadGoalUpdatedNotification.self)

        XCTAssertNil(update.turnId)
        XCTAssertEqual(update.goal.status, .complete)
    }
}
