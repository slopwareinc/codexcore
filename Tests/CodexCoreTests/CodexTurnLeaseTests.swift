import XCTest
@testable import CodexCore

final class CodexTurnLeaseTests: XCTestCase {
    func testLeaseCommandsUseCanonicalIdentityAndReturnAtomicTerminalResult() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let thread = try await session.startThread(.init(
            approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
            approvalsReviewer: .user,
            permissions: ":workspace"
        ))
        XCTAssertEqual(thread.id, ThreadID("thread-1"))
        XCTAssertLessThan(thread.startRevision, thread.responseRevision)
        XCTAssertEqual(
            thread.permissionConfiguration,
            .init(
                profileID: ":workspace",
                approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
                approvalsReviewer: .autoReview
            )
        )
        let maybeThreadStartParams = await transport.latestObjectParams(
            method: "thread/start"
        )
        let threadStartParams = try XCTUnwrap(maybeThreadStartParams)
        XCTAssertEqual(threadStartParams["permissions"], .string(":workspace"))
        XCTAssertEqual(
            threadStartParams["approvalPolicy"],
            .string("on-request")
        )
        XCTAssertEqual(
            threadStartParams["approvalsReviewer"],
            .string("user")
        )
        XCTAssertNil(threadStartParams["sandbox"])

        let input = CodexSchemaUserInput(.dictionary([
            "type": .string("text"),
            "text": .string("Say hi"),
        ]))
        let turn = try await thread.startTurn(.init(
            input: [input],
            threadID: thread.id.rawValue
        ))

        XCTAssertEqual(
            turn.key,
            TurnKey(threadID: "thread-1", turnID: "turn-1")
        )
        XCTAssertLessThan(turn.startRevision, turn.responseRevision)

        let turnSnapshot = try await turn.snapshot()
        XCTAssertEqual(turnSnapshot.turns[turn.key]?.status, .inProgress)
        XCTAssertEqual(turnSnapshot.threads.count, 1)
        XCTAssertEqual(turnSnapshot.turns.count, 1)

        let maybeStartParams = await transport.latestObjectParams(method: "turn/start")
        let startParams = try XCTUnwrap(maybeStartParams)
        guard case .string(let clientMessageID)? = startParams["clientUserMessageId"] else {
            return XCTFail("turn/start must carry a session-owned submission id")
        }
        XCTAssertTrue(clientMessageID.hasPrefix("codexcore-"))

        let resultTask = Task {
            try await turn.awaitTerminal(timeout: .seconds(1))
        }
        await transport.sendNotification(
            method: "item/completed",
            params: [
                "completedAtMs": .int(2),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "item": Self.agentItem,
            ]
        )
        await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string("thread-1"),
                "turn": .dictionary([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([Self.agentItem]),
                ]),
            ]
        )

        let result = try await resultTask.value
        XCTAssertEqual(result.turn.key, turn.key)
        XCTAssertEqual(result.turn.status, .completed)
        XCTAssertEqual(result.items.map(\.key.itemID), [ItemID("answer-1")])
        XCTAssertEqual(result.items.first?.payload["text"], .string("hi"))
        XCTAssertEqual(result.revision, result.turn.lastChangedRevision)

        await thread.close()
        XCTAssertTrue(thread.isClosed)
        await session.stop()
    }

    func testResumeLeaseHydratesServerPermissionStateWithoutRequestOverrides() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let started = try await session.startThread()

        let resumed = try await session.resumeThread(.init(
            threadID: started.id.rawValue
        ))

        XCTAssertEqual(
            resumed.permissionConfiguration,
            .init(
                profileID: ":workspace",
                approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
                approvalsReviewer: .autoReview
            )
        )
        let maybeResumeParams = await transport.latestObjectParams(
            method: "thread/resume"
        )
        let resumeParams = try XCTUnwrap(maybeResumeParams)
        XCTAssertNil(resumeParams["permissions"])
        XCTAssertNil(resumeParams["approvalPolicy"])
        XCTAssertNil(resumeParams["approvalsReviewer"])
        XCTAssertNil(resumeParams["sandbox"])

        await resumed.close()
        await started.close()
        await session.stop()
    }

    func testForkLeaseUsesAuthoritativeResponseAfterForwardingRequestedProfile() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let started = try await session.startThread()

        let forked = try await started.fork(.init(
            approvalPolicy: CodexSchemaAskForApproval(.string("never")),
            approvalsReviewer: .user,
            permissions: ":danger-full-access",
            threadID: started.id.rawValue
        ))

        let maybeForkParams = await transport.latestObjectParams(
            method: "thread/fork"
        )
        let forkParams = try XCTUnwrap(maybeForkParams)
        XCTAssertEqual(
            forkParams["permissions"],
            .string(":danger-full-access")
        )
        XCTAssertEqual(forkParams["approvalPolicy"], .string("never"))
        XCTAssertEqual(forkParams["approvalsReviewer"], .string("user"))
        XCTAssertEqual(
            forked.permissionConfiguration,
            .init(
                profileID: ":workspace",
                approvalPolicy: CodexSchemaAskForApproval(.string("on-request")),
                approvalsReviewer: .autoReview
            )
        )

        await forked.close()
        await started.close()
        await session.stop()
    }

    func testSteerAndInterruptCannotEscapeCompositeTurnKey() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let thread = try await session.startThread()
        let input = CodexSchemaUserInput(.dictionary([
            "type": .string("text"),
            "text": .string("initial"),
        ]))
        let turn = try await thread.startTurn(.init(
            input: [input],
            threadID: thread.id.rawValue
        ))

        do {
            _ = try await turn.steer(.init(
                expectedTurnID: turn.key.turnID.rawValue,
                input: [input],
                threadID: "another-thread"
            ))
            XCTFail("A turn lease must reject another thread's identical raw turn id")
        } catch let error as CodexLeaseError {
            guard case .requestTurnMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let response = try await turn.steer(.init(
            expectedTurnID: turn.key.turnID.rawValue,
            input: [CodexSchemaUserInput(.dictionary([
                "type": .string("text"),
                "text": .string("steer"),
            ]))],
            threadID: turn.key.threadID.rawValue
        ))
        XCTAssertEqual(response.turnID, turn.key.turnID.rawValue)

        let maybeSteerParams = await transport.latestObjectParams(method: "turn/steer")
        let steerParams = try XCTUnwrap(maybeSteerParams)
        XCTAssertEqual(steerParams["threadId"], .string("thread-1"))
        XCTAssertEqual(steerParams["expectedTurnId"], .string("turn-1"))
        XCTAssertNotNil(steerParams["clientUserMessageId"])

        try await turn.interrupt()
        let maybeInterruptParams = await transport.latestObjectParams(method: "turn/interrupt")
        let interruptParams = try XCTUnwrap(maybeInterruptParams)
        XCTAssertEqual(interruptParams["threadId"], .string("thread-1"))
        XCTAssertEqual(interruptParams["turnId"], .string("turn-1"))

        let snapshot = await session.canonicalSnapshot()
        XCTAssertEqual(snapshot.submissionIntents.count, 2)

        await thread.close()
        await session.stop()
    }

    func testThreadScopedSteerRegistersIntentBeforeWriteAndHandlesEchoBeforeResponse() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let thread = try await session.startThread()
        await transport.setHoldSteerResponses(true)

        let input = CodexSchemaUserInput(.dictionary([
            "type": .string("text"),
            "text": .string("change direction"),
        ]))
        let steerTask = Task {
            try await thread.steerTurn(.init(
                clientUserMessageID: "steer-client",
                expectedTurnID: "turn-2",
                input: [input],
                threadID: thread.id.rawValue
            ))
        }

        let wroteSteerRequest = await transport.waitForRequest(method: "turn/steer")
        XCTAssertTrue(wroteSteerRequest)
        var snapshot = await session.canonicalSnapshot()
        XCTAssertEqual(snapshot.submissionIntents["steer-client"]?.state, .pending)

        let echoedUserItem: CodexJSONValue = .dictionary([
            "type": .string("userMessage"),
            "id": .string("steer-user-item"),
            "clientId": .string("steer-client"),
            "content": .array([input.rawValue]),
        ])
        await transport.sendNotification(
            method: "item/started",
            params: [
                "threadId": .string(thread.id.rawValue),
                "turnId": .string("turn-2"),
                "startedAtMs": .int(2),
                "item": echoedUserItem,
            ]
        )

        for _ in 0 ..< 10_000 {
            snapshot = await session.canonicalSnapshot()
            if case .reconciled? = snapshot.submissionIntents["steer-client"]?.state {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            snapshot.submissionIntents["steer-client"]?.state,
            .reconciled(item: .init(
                threadID: thread.id,
                turnID: "turn-2",
                itemID: "steer-user-item"
            ))
        )

        await transport.releaseNextSteerResponse()
        let recoveredTurn = try await steerTask.value
        let steerRequestCount = await transport.requestCount(method: "turn/steer")
        let readRequestCount = await transport.requestCount(method: "thread/read")
        XCTAssertEqual(recoveredTurn.key, .init(threadID: thread.id, turnID: "turn-2"))
        XCTAssertEqual(steerRequestCount, 1)
        XCTAssertEqual(readRequestCount, 0)

        await thread.close()
        await session.stop()
    }

    func testAttachExistingTurnRestoresControlWithoutAnotherProtocolRequest() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let thread = try await session.startThread()
        let started = try await thread.startTurn(.init(
            input: [CodexSchemaUserInput(.dictionary([
                "type": .string("text"),
                "text": .string("keep working"),
            ]))],
            threadID: thread.id.rawValue
        ))
        let requestCountBeforeAttach = await transport.requestCount

        let attached = try await thread.attachTurn(started.key.turnID)
        let requestCountAfterAttach = await transport.requestCount

        XCTAssertEqual(attached.key, started.key)
        XCTAssertEqual(requestCountAfterAttach, requestCountBeforeAttach)

        let terminalTask = Task {
            try await attached.awaitTerminal(timeout: .seconds(1))
        }
        await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string(thread.id.rawValue),
                "turn": .dictionary([
                    "id": .string(attached.key.turnID.rawValue),
                    "status": .string("completed"),
                    "items": .array([]),
                ]),
            ]
        )

        let terminal = try await terminalTask.value
        XCTAssertEqual(terminal.turn.status, .completed)
        await thread.close()
        await session.stop()
    }

    func testLoginWaiterUsesOperationFactWithoutRawNotificationStream() async throws {
        let transport = CodexSessionLeaseTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let params = try CodexJSONValue.dictionary([
            "type": .string("chatgptDeviceCode")
        ]).decode(CodexSchemaLoginAccountParams.self)
        let started = try await session.startLogin(params)
        guard case .identified(let attempt) = started else {
            return XCTFail("Device-code login must return an interactive attempt")
        }
        XCTAssertEqual(attempt.key.connectionEpoch, 1)
        XCTAssertEqual(attempt.key.loginID, "login-1")

        await transport.sendNotification(
            method: "account/login/completed",
            params: [
                "loginId": .string("login-1"),
                "success": .bool(true),
            ]
        )

        // Completion-before-await is retained under the exact epoch-scoped key.
        let completion = try await attempt.completion()
        XCTAssertEqual(completion.loginID, "login-1")
        XCTAssertTrue(completion.success)
        XCTAssertNil(completion.error)
        await session.stop()
    }

    private static let agentItem = CodexJSONValue.dictionary([
        "id": .string("answer-1"),
        "type": .string("agentMessage"),
        "phase": .string("final_answer"),
        "text": .string("hi"),
    ])
}

private actor CodexSessionLeaseTestTransport: CodexFrameTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var outbound: [[String: CodexJSONValue]] = []
    private var holdSteerResponses = false
    private var heldSteerResponses: [(CodexJSONRPCID, String)] = []

    var requestCount: Int { outbound.count }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard continuation == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard case .dictionary(let object) = value else {
            throw CodexJSONRPCEnvelopeError.topLevelMustBeObject
        }
        outbound.append(object)

        guard case .string(let method)? = object["method"],
              let rawID = object["id"] else {
            return
        }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(CodexHome.default.path),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("Codex Desktop/0.145.0-alpha.20 (Mac OS; arm64) test"),
            ])
        case "account/login/start":
            result = .dictionary([
                "type": .string("chatgptDeviceCode"),
                "loginId": .string("login-1"),
                "verificationUrl": .string("https://example.test/device"),
                "userCode": .string("ABCD-EFGH"),
            ])
        case "thread/start", "thread/resume":
            result = Self.threadResult(id: "thread-1")
        case "thread/fork":
            result = Self.threadResult(id: "thread-fork")
        case "turn/start":
            result = .dictionary([
                "turn": .dictionary([
                    "id": .string("turn-1"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ])
        case "turn/steer":
            let expectedTurnID = Self.stringParam(
                "expectedTurnId",
                from: object
            ) ?? "turn-1"
            if holdSteerResponses {
                heldSteerResponses.append((id, expectedTurnID))
                return
            }
            result = .dictionary(["turnId": .string(expectedTurnID)])
        default:
            result = .dictionary([:])
        }

        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func sendNotification(
        method: String,
        params: [String: CodexJSONValue]
    ) {
        let frame = try? CodexJSONRPCCodec.encodeNotification(
            method: method,
            objectParams: params
        )
        if let frame {
            continuation?.yield(frame)
        }
    }

    func setHoldSteerResponses(_ hold: Bool) {
        holdSteerResponses = hold
    }

    func waitForRequest(method: String) async -> Bool {
        for _ in 0 ..< 10_000 {
            if outbound.contains(where: { $0["method"] == .string(method) }) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func releaseNextSteerResponse() {
        guard !heldSteerResponses.isEmpty else { return }
        let (id, turnID) = heldSteerResponses.removeFirst()
        let frame = try? CodexJSONRPCCodec.encodeResult(
            id: id,
            result: .dictionary(["turnId": .string(turnID)])
        )
        if let frame {
            continuation?.yield(frame)
        }
    }

    func requestCount(method: String) -> Int {
        outbound.count(where: { $0["method"] == .string(method) })
    }

    func latestObjectParams(method: String) -> [String: CodexJSONValue]? {
        for request in outbound.reversed()
        where request["method"] == .string(method) {
            guard case .dictionary(let params)? = request["params"] else { return nil }
            return params
        }
        return nil
    }

    private static func threadResult(id: String) -> CodexJSONValue {
        .dictionary([
            "activePermissionProfile": .dictionary([
                "id": .string(":workspace"),
            ]),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("auto_review"),
            "cwd": .string("/tmp"),
            "model": .string("gpt-5.6"),
            "modelProvider": .string("openai"),
            "sandbox": .dictionary(["type": .string("workspaceWrite")]),
            "thread": .dictionary([
                "cliVersion": .string("alpha.20"),
                "createdAt": .int(1),
                "cwd": .string("/tmp"),
                "ephemeral": .bool(false),
                "id": .string(id),
                "historyMode": .string("legacy"),
                "modelProvider": .string("openai"),
                "preview": .string(""),
                "sessionId": .string("session-\(id)"),
                "source": .string("appServer"),
                "status": .dictionary(["type": .string("idle")]),
                "turns": .array([]),
                "updatedAt": .int(1),
            ]),
        ])
    }

    private static func stringParam(
        _ name: String,
        from request: [String: CodexJSONValue]
    ) -> String? {
        guard case .dictionary(let params)? = request["params"],
              case .string(let value)? = params[name]
        else { return nil }
        return value
    }
}
