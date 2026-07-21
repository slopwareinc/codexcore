import XCTest
@testable import CodexCore

final class ServerRequestProtocolTests: XCTestCase {
    func testHostHandlerBoundaryUsesPublicDecisionType() async throws {
        let parsed = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .string("host-boundary"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: commonItemParams(itemID: "host-boundary")
        )
        let handler: CodexSessionServerRequestHandler = { _ in
            CodexServerRequestHandlerDecision.pending
        }

        let decision = await handler(parsed)
        guard case .pending = decision else {
            return XCTFail("The public handler decision should remain host-owned")
        }
    }

    func testNotificationOptOutPolicyAllowsOnlyBoundedDiagnostics() {
        let requested = [
            CodexAppServerNotificationMethod.threadStarted.rawValue,
            CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            CodexAppServerNotificationMethod.commandExecOutputDelta.rawValue,
            CodexAppServerNotificationMethod.accountLoginCompleted.rawValue,
            CodexAppServerNotificationMethod.warning.rawValue,
            CodexAppServerNotificationMethod.warning.rawValue,
            CodexAppServerNotificationMethod.guardianWarning.rawValue,
            CodexAppServerNotificationMethod.deprecationNotice.rawValue,
            CodexAppServerNotificationMethod.configWarning.rawValue,
            CodexAppServerNotificationMethod.windowsWorldWritableWarning.rawValue,
            "future/state-bearing-notification",
        ]
        let expected = [
            CodexAppServerNotificationMethod.warning.rawValue,
            CodexAppServerNotificationMethod.guardianWarning.rawValue,
            CodexAppServerNotificationMethod.deprecationNotice.rawValue,
            CodexAppServerNotificationMethod.configWarning.rawValue,
            CodexAppServerNotificationMethod.windowsWorldWritableWarning.rawValue,
        ]

        XCTAssertNil(CodexNotificationOptOutPolicy.filtered(nil))
        XCTAssertEqual(CodexNotificationOptOutPolicy.filtered(requested), expected)

        let capabilities = InitializeCapabilities(
            experimentalAPI: false,
            optOutNotificationMethods: requested
        )
        let sessionConfiguration = CodexSessionConfiguration(
            capabilities: capabilities
        )
        let sdkConfiguration = CodexConfig(capabilities: capabilities)
        XCTAssertEqual(
            sessionConfiguration.capabilities.optOutNotificationMethods,
            expected
        )
        XCTAssertEqual(
            sdkConfiguration.capabilities.optOutNotificationMethods,
            expected
        )
        XCTAssertEqual(sessionConfiguration.capabilities.experimentalAPI, true)
        XCTAssertEqual(sdkConfiguration.capabilities.experimentalAPI, true)
    }

    func testTypedKindsExactlyCoverGA145GeneratedInventory() {
        XCTAssertEqual(
            CodexServerRequestKind.knownMethods,
            Set(CodexAppServerServerRequestMethod.allCases.map(\.rawValue))
        )
        XCTAssertEqual(CodexServerRequestKind.knownMethods.count, 11)
        XCTAssertEqual(CodexAppServerProtocolInventory.serverRequestMethodCount, 11)
    }

    func testEveryGA145RequestArmParsesAndValidatesItsResult() throws {
        let fixtures: [(method: CodexAppServerServerRequestMethod, params: [String: CodexJSONValue], result: CodexJSONValue)] = [
            (
                .itemCommandExecutionRequestApproval,
                [
                    "threadId": .string("thread"),
                    "turnId": .string("turn"),
                    "itemId": .string("command"),
                    "approvalId": .string("approval"),
                    "startedAtMs": .int(1_700_000_000_123),
                    "command": .string("ls"),
                    "availableDecisions": .array([.string("accept"), .string("decline")])
                ],
                .dictionary(["decision": .string("accept")])
            ),
            (
                .itemFileChangeRequestApproval,
                commonItemParams(itemID: "file"),
                .dictionary(["decision": .string("acceptForSession")])
            ),
            (
                .itemToolRequestUserInput,
                [
                    "threadId": .string("thread"),
                    "turnId": .string("turn"),
                    "itemId": .string("input"),
                    "autoResolutionMs": .int(60_000),
                    "questions": .array([
                        .dictionary([
                            "id": .string("q1"),
                            "header": .string("Choice"),
                            "question": .string("Continue?"),
                            "options": .array([
                                .dictionary([
                                    "label": .string("Yes"),
                                    "description": .string("Continue the turn")
                                ])
                            ])
                        ])
                    ])
                ],
                .dictionary([
                    "answers": .dictionary([
                        "q1": .dictionary(["answers": .array([.string("Yes")])])
                    ])
                ])
            ),
            (
                .mcpServerElicitationRequest,
                [
                    "threadId": .string("thread"),
                    "turnId": .string("turn"),
                    "serverName": .string("mcp"),
                    "message": .string("Provide a value"),
                    "mode": .string("form"),
                    "requestedSchema": .dictionary([
                        "type": .string("object"),
                        "properties": .dictionary([:])
                    ])
                ],
                .dictionary(["action": .string("decline")])
            ),
            (
                .itemPermissionsRequestApproval,
                [
                    "threadId": .string("thread"),
                    "turnId": .string("turn"),
                    "itemId": .string("permissions"),
                    "cwd": .string("/tmp"),
                    "startedAtMs": .int(1_700_000_000_124),
                    "permissions": .dictionary([
                        "network": .dictionary(["enabled": .bool(true)])
                    ])
                ],
                .dictionary([
                    "permissions": .dictionary([
                        "network": .dictionary(["enabled": .bool(true)])
                    ]),
                    "scope": .string("turn")
                ])
            ),
            (
                .itemToolCall,
                [
                    "threadId": .string("thread"),
                    "turnId": .string("turn"),
                    "callId": .string("call"),
                    "namespace": .string("tools"),
                    "tool": .string("lookup"),
                    "arguments": .dictionary(["query": .string("value")])
                ],
                .dictionary([
                    "success": .bool(true),
                    "contentItems": .array([
                        .dictionary(["type": .string("inputText"), "text": .string("done")]),
                        .dictionary(["type": .string("inputImage"), "imageUrl": .string("data:image/png;base64,AA==")]),
                        .dictionary(["type": .string("inputAudio"), "audioUrl": .string("data:audio/wav;base64,AA==")])
                    ])
                ])
            ),
            (
                .accountChatGPTAuthTokensRefresh,
                ["reason": .string("unauthorized"), "previousAccountId": .null],
                .dictionary([
                    "accessToken": .string("secret"),
                    "chatgptAccountId": .string("account"),
                    "chatgptPlanType": .string("pro")
                ])
            ),
            (
                .attestationGenerate,
                [:],
                .dictionary(["token": .string("attestation-secret")])
            ),
            (
                .currentTimeRead,
                ["threadId": .string("thread")],
                .dictionary(["currentTimeAt": .int(1_700_000_000)])
            ),
            (
                .applyPatchApproval,
                [
                    "conversationId": .string("thread"),
                    "callId": .string("patch"),
                    "fileChanges": .dictionary([:])
                ],
                .dictionary(["decision": .string("approved")])
            ),
            (
                .execCommandApproval,
                [
                    "conversationId": .string("thread"),
                    "callId": .string("exec"),
                    "approvalId": .string("legacy-approval"),
                    "command": .array([.string("ls")]),
                    "cwd": .string("/tmp"),
                    "parsedCmd": .array([])
                ],
                .dictionary([
                    "decision": .dictionary([
                        "denied": .dictionary(["rejection": .string("Rejected in test.")])
                    ])
                ])
            )
        ]

        for (index, fixture) in fixtures.enumerated() {
            let parsed = try CodexServerRequestParser.parse(
                connectionEpoch: 3,
                id: .int(index + 1),
                method: fixture.method.rawValue,
                params: fixture.params
            )
            XCTAssertEqual(parsed.body.kind.method, fixture.method.rawValue)
            XCTAssertEqual(parsed.registration.method, fixture.method.rawValue)
            XCTAssertTrue(parsed.registration.key.requestID == .integer(Int64(index + 1)))

            let validated = try parsed.validate(result: fixture.result)
            XCTAssertEqual(validated.jsonValue, fixture.result, "Result mismatch for \(fixture.method.rawValue)")
        }
    }

    func testParsedRegistrationIsSanitizedButKeepsApprovalAndProtocolCoordinates() throws {
        let parsed = try CodexServerRequestParser.parse(
            connectionEpoch: 8,
            id: .string("wire-id"),
            method: CodexServerRequestKind.commandApproval.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "approvalId": .string("approval"),
                "startedAtMs": .int(10),
                "command": .string("secret command argument")
            ]
        )

        let registration = parsed.registration
        XCTAssertEqual(registration.key, .init(connectionEpoch: 8, requestID: .string("wire-id")))
        XCTAssertEqual(
            registration.scope,
            .init(threadID: "thread", turnID: "turn", itemID: "item")
        )
        XCTAssertEqual(
            registration.approvalCorrelation,
            .init(threadID: "thread", approvalID: "approval")
        )
        XCTAssertFalse(String(describing: registration).contains("secret command argument"))
    }

    func testKnownRequestRetainsOnlyAdditiveTopLevelFieldsOutsideSanitizedRegistration() throws {
        let futureField: CodexJSONValue = .dictionary([
            "nested": .array([.string("future-value")])
        ])
        let parsed = try CodexServerRequestParser.parse(
            connectionEpoch: 8,
            id: .string("wire-id"),
            method: CodexServerRequestKind.commandApproval.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "startedAtMs": .int(10),
                "command": .string("echo hello"),
                "futureField": futureField
            ]
        )

        XCTAssertEqual(parsed.unknownFields, ["futureField": futureField])
        XCTAssertFalse(String(describing: parsed.registration).contains("future-value"))
    }

    func testUnknownMethodPreservesParamsAndAcceptsOpaqueResult() throws {
        let params: [String: CodexJSONValue] = ["future": .dictionary(["value": .int(1)])]
        let parsed = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .string("future"),
            method: "future/serverRequest",
            params: params
        )

        guard case .unknown(let method, let retained) = parsed.body else {
            return XCTFail("Expected unknown request")
        }
        XCTAssertEqual(method, "future/serverRequest")
        XCTAssertEqual(retained, params)
        XCTAssertTrue(parsed.unknownFields.isEmpty, "the unknown body already owns the full payload")
        XCTAssertEqual(parsed.registration.kind, .unknown("future/serverRequest"))
        XCTAssertEqual(
            try parsed.validate(result: .dictionary(["futureResult": .bool(true)])),
            .unknown(.dictionary(["futureResult": .bool(true)]))
        )
    }

    func testMissingRequiredRequestFieldFailsBeforeInboxAdmission() {
        XCTAssertThrowsError(try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .integerFixture,
            method: CodexServerRequestKind.dynamicToolCall.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "callId": .string("call"),
                "arguments": .dictionary([:])
            ]
        )) { error in
            XCTAssertEqual(
                error as? CodexServerRequestProtocolError,
                .missingField(method: CodexServerRequestKind.dynamicToolCall.method, field: "tool")
            )
        }
    }

    func testCommandDecisionMustBeOneOfOfferedDecisions() throws {
        let request = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(1),
            method: CodexServerRequestKind.commandApproval.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "startedAtMs": .int(1),
                "availableDecisions": .array([.string("decline")])
            ]
        )

        XCTAssertThrowsError(try request.validate(result: .dictionary([
            "decision": .string("accept")
        ]))) { error in
            XCTAssertEqual(
                error as? CodexServerRequestProtocolError,
                .unavailableDecision(method: CodexServerRequestKind.commandApproval.method)
            )
        }
    }

    func testCommandDecisionAllowsSchemaPermittedAdditiveNestedFields() throws {
        let offered: CodexJSONValue = .dictionary([
            "acceptWithExecpolicyAmendment": .dictionary([
                "execpolicy_amendment": .array([.string("git"), .string("status")]),
                "futureMetadata": .bool(true)
            ])
        ])
        let request = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(11),
            method: CodexServerRequestKind.commandApproval.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "startedAtMs": .int(1),
                "availableDecisions": .array([offered])
            ]
        )

        let result = try request.validate(result: .dictionary(["decision": offered]))
        XCTAssertEqual(
            result,
            .commandApproval(.acceptWithExecpolicyAmendment(["git", "status"]))
        )
    }

    func testUserInputRejectsAnswersForUnrequestedQuestion() throws {
        let request = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(2),
            method: CodexServerRequestKind.userInput.method,
            params: [
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "questions": .array([
                    .dictionary([
                        "id": .string("known"),
                        "header": .string("Question"),
                        "question": .string("Answer?")
                    ])
                ])
            ]
        )

        XCTAssertThrowsError(try request.validate(result: .dictionary([
            "answers": .dictionary([
                "unknown": .dictionary(["answers": .array([.string("x")])])
            ])
        ]))) { error in
            XCTAssertEqual(error as? CodexServerRequestProtocolError, .unknownQuestionID("unknown"))
        }
    }

    func testPermissionResponseCannotGrantMoreThanRequested() throws {
        let request = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(3),
            method: CodexServerRequestKind.permissionsApproval.method,
            params: commonItemParams(itemID: "permissions").merging([
                "cwd": .string("/tmp"),
                "permissions": .dictionary([:])
            ]) { _, rhs in rhs }
        )

        XCTAssertThrowsError(try request.validate(result: .dictionary([
            "permissions": .dictionary([
                "network": .dictionary(["enabled": .bool(true)])
            ])
        ]))) { error in
            XCTAssertEqual(
                error as? CodexServerRequestProtocolError,
                .permissionGrantExceedsRequest(field: "permissions")
            )
        }
    }

    func testPermissionRequestRejectsMalformedSpecialPathPayload() {
        XCTAssertThrowsError(try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(12),
            method: CodexServerRequestKind.permissionsApproval.method,
            params: commonItemParams(itemID: "permissions").merging([
                "cwd": .string("/tmp"),
                "permissions": .dictionary([
                    "fileSystem": .dictionary([
                        "entries": .array([
                            .dictionary([
                                "access": .string("read"),
                                "path": .dictionary([
                                    "type": .string("special"),
                                    "value": .dictionary([
                                        "kind": .string("unknown"),
                                        "path": .bool(true)
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ]) { _, rhs in rhs }
        )) { error in
            XCTAssertEqual(
                error as? CodexServerRequestProtocolError,
                .invalidField(
                    method: CodexServerRequestKind.permissionsApproval.method,
                    field: "permissions.fileSystem.entries.special.path"
                )
            )
        }
    }

    func testSecretResultsAreNotRetainedByPendingInboxSnapshot() throws {
        let parsed = try CodexServerRequestParser.parse(
            connectionEpoch: 1,
            id: .int(4),
            method: CodexServerRequestKind.tokenRefresh.method,
            params: ["reason": .string("unauthorized")]
        )
        let result: CodexJSONValue = .dictionary([
            "accessToken": .string("highly-secret-token"),
            "chatgptAccountId": .string("account")
        ])
        _ = try parsed.validate(result: result)

        var inbox = CodexInteractionInbox()
        _ = inbox.register(parsed)
        let snapshot = try XCTUnwrap(inbox.pendingSnapshots().first)
        XCTAssertFalse(String(describing: snapshot).contains("highly-secret-token"))
        XCTAssertEqual(inbox.takeForLocalReply(parsed.key), parsed)
        XCTAssertTrue(inbox.pendingSnapshots().isEmpty)
    }

    private func commonItemParams(itemID: String) -> [String: CodexJSONValue] {
        [
            "threadId": .string("thread"),
            "turnId": .string("turn"),
            "itemId": .string(itemID),
            "startedAtMs": .int(1_700_000_000_000)
        ]
    }
}

private extension CodexJSONValue {
    static var integerFixture: Self { .int(99) }
}
