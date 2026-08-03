import XCTest
@testable import CodexCore

final class V2TypeTests: XCTestCase {
    func testMaximumReasoningEffortUsesServerWireValue() throws {
        XCTAssertEqual(
            try CodexJSONValue(encoding: ReasoningEffort.max),
            .string("max")
        )
    }

    func testCodexVoiceWebRTCStartUsesOfficialTransportShape() throws {
        let params = CodexSchemaThreadRealtimeStartParams.codexVoiceWebRTC(
            threadID: "thread-voice",
            offerSDP: "v=0\r\n",
            realtimeSessionID: "realtime-session"
        )
        let value = try CodexJSONValue(encoding: params)

        XCTAssertEqual(value.objectValue?["threadId"], .string("thread-voice"))
        XCTAssertEqual(value.objectValue?["outputModality"], .string("audio"))
        XCTAssertEqual(value.objectValue?["includeStartupContext"], .bool(false))
        XCTAssertEqual(value.objectValue?["realtimeSessionId"], .string("realtime-session"))
        XCTAssertEqual(value.objectValue?["model"], .string("gpt-live-1-codex"))
        XCTAssertEqual(value.objectValue?["version"], .string("v3"))
        XCTAssertEqual(value.objectValue?["voice"], .string("sol"))
        XCTAssertEqual(value.objectValue?["transport"], .dictionary([
            "type": .string("webrtc"),
            "sdp": .string("v=0\r\n"),
        ]))
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

    func testInitializeResponseRejectsEveryMissingOrNullRequiredField() throws {
        let complete: [String: CodexJSONValue] = [
            "codexHome": .string("/tmp/codex-home"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex/alpha.20"),
        ]

        for field in ["codexHome", "platformFamily", "platformOs", "userAgent"] {
            var missing = complete
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(
                try CodexJSONValue.dictionary(missing).decode(InitializeResponse.self),
                "InitializeResponse must require \(field)"
            )

            var null = complete
            null[field] = .null
            XCTAssertThrowsError(
                try CodexJSONValue.dictionary(null).decode(InitializeResponse.self),
                "InitializeResponse must reject null \(field)"
            )
        }
    }

    func testInputWireMappingMatchesPythonSDK() {
        XCTAssertEqual(CodexInput.text("hi").jsonValue, .dictionary(["type": .string("text"), "text": .string("hi")]))
        XCTAssertEqual(CodexInput.image(url: "https://example.com/a.png").jsonValue, .dictionary(["type": .string("image"), "url": .string("https://example.com/a.png")]))
        XCTAssertEqual(CodexInput.localImage(path: "/tmp/a.png").jsonValue, .dictionary(["type": .string("localImage"), "path": .string("/tmp/a.png")]))
        XCTAssertEqual(CodexInput.skill(name: "docs", path: "/skills/docs").jsonValue, .dictionary(["type": .string("skill"), "name": .string("docs"), "path": .string("/skills/docs")]))
        XCTAssertEqual(CodexInput.mention(name: "README", path: "README.md").jsonValue, .dictionary(["type": .string("mention"), "name": .string("README"), "path": .string("README.md")]))
    }

    func testInputWireMappingIncludesAudioImageDetailAndTextElements() throws {
        let element = CodexSchemaTextElement(
            byteRange: .init(start: 0, end: 4),
            placeholder: "file"
        )
        XCTAssertEqual(
            CodexInput.text("file", textElements: [element]).jsonValue,
            .dictionary([
                "type": .string("text"),
                "text": .string("file"),
                "text_elements": .array([
                    .dictionary([
                        "byteRange": .dictionary(["start": .int(0), "end": .int(4)]),
                        "placeholder": .string("file"),
                    ])
                ]),
            ])
        )
        XCTAssertEqual(
            CodexInput.image(url: "https://example.com/a.png", detail: .high).jsonValue,
            .dictionary([
                "type": .string("image"),
                "url": .string("https://example.com/a.png"),
                "detail": .string("high"),
            ])
        )
        XCTAssertEqual(
            CodexInput.localImage(path: "/tmp/a.png", detail: .original).jsonValue,
            .dictionary([
                "type": .string("localImage"),
                "path": .string("/tmp/a.png"),
                "detail": .string("original"),
            ])
        )
        XCTAssertEqual(
            CodexInput.audio(url: "data:audio/wav;base64,AA==").jsonValue,
            .dictionary([
                "type": .string("audio"),
                "url": .string("data:audio/wav;base64,AA=="),
            ])
        )
        XCTAssertEqual(
            CodexInput.localAudio(path: "/tmp/input.wav").jsonValue,
            .dictionary([
                "type": .string("localAudio"),
                "path": .string("/tmp/input.wav"),
            ])
        )
    }

    func testGranularApprovalPolicyEncodesCurrentUnionShape() throws {
        let policy = AskForApproval.granular(.init(
            mcpElicitations: true,
            rules: false,
            sandboxApproval: true,
            requestPermissions: false,
            skillApproval: true
        ))
        let encoded = try CodexJSONValue(encoding: policy)
        XCTAssertEqual(
            encoded,
            .dictionary(["granular": .dictionary([
                "mcp_elicitations": .bool(true),
                "rules": .bool(false),
                "sandbox_approval": .bool(true),
                "request_permissions": .bool(false),
                "skill_approval": .bool(true),
            ])])
        )
        XCTAssertEqual(try encoded.decode(AskForApproval.self), policy)
        XCTAssertNil(AskForApproval(rawValue: "on-failure"))
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
