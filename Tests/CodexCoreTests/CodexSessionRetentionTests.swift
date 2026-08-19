import XCTest
@testable import CodexCore

final class CodexSessionRetentionTests: XCTestCase {
    func testPendingServerRequestRetainsDetailUntilTerminalUnsubscribe() async throws {
        let transport = RetentionTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                reconnectPolicy: .disabled,
                maximumRetainedUnleasedThreadDetails: 0
            )
        )
        _ = try await session.start()
        let thread = try await session.startThread()
        let threadID = thread.id
        let turnKey = TurnKey(threadID: threadID, turnID: "turn")

        try await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string(threadID.rawValue),
                "turn": .dictionary([
                    "id": .string(turnKey.turnID.rawValue),
                    "status": .string("completed"),
                    "items": .array([]),
                    "itemsView": .string("full"),
                ]),
            ]
        )
        try await waitUntil {
            await session.canonicalSnapshot().turns[turnKey] != nil
        }

        try await transport.sendServerRequest(
            id: .string("approval"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(threadID: threadID)
        )
        try await waitUntil {
            await session.pendingServerRequests().count == 1
        }
        let pendingRequests = await session.pendingServerRequests()
        let request = try XCTUnwrap(pendingRequests.first)

        await thread.close()
        for _ in 0..<20 { await Task.yield() }
        let unsubscribeCountBeforeResolution = await transport.requestCount(
            method: "thread/unsubscribe"
        )
        let retainedBeforeResolution = await session.canonicalSnapshot()
        XCTAssertEqual(unsubscribeCountBeforeResolution, 0)
        XCTAssertNotNil(retainedBeforeResolution.turns[turnKey])

        try await session.resolveServerRequest(
            request.key,
            result: .dictionary(["decision": .string("decline")])
        )
        try await waitUntil {
            let unsubscribeCount = await transport.requestCount(method: "thread/unsubscribe")
            let snapshot = await session.canonicalSnapshot()
            return unsubscribeCount == 1 && snapshot.turns[turnKey] == nil
        }

        let evicted = await session.canonicalSnapshot()
        let retainedThread = try XCTUnwrap(evicted.threads[threadID])
        XCTAssertEqual(retainedThread.metadata.cwd, .string("/tmp"))
        XCTAssertFalse(retainedThread.isLoaded)
        XCTAssertEqual(retainedThread.turnOrder, [])
        XCTAssertEqual(
            retainedThread.retainedLatestTurn,
            .init(id: turnKey.turnID, status: .completed)
        )
        XCTAssertEqual(retainedThread.history.turnsCoverage, .notLoaded)
        let indexAfterEviction = await session.threadIndexSnapshot()
        XCTAssertEqual(indexAfterEviction.summary(for: threadID)?.latestTurnStatus, .completed)

        do {
            try await session.resolveServerRequest(
                request.key,
                result: .dictionary(["decision": .string("decline")])
            )
            XCTFail("A terminal request must not release its lease twice")
        } catch let error as CodexSessionError {
            XCTAssertEqual(error, .unknownServerRequest(request.key))
        }
        let unsubscribeCountAfterDuplicate = await transport.requestCount(
            method: "thread/unsubscribe"
        )
        XCTAssertEqual(unsubscribeCountAfterDuplicate, 1)
        await session.stop()
    }

    func testDisconnectReleasesPendingRequestLeaseAndEvictsAtZeroWarmBudget() async throws {
        let transport = RetentionTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                reconnectPolicy: .disabled,
                maximumRetainedUnleasedThreadDetails: 0
            )
        )
        _ = try await session.start()
        let thread = try await session.startThread()
        let threadID = thread.id
        let turnKey = TurnKey(threadID: threadID, turnID: "turn")

        try await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string(threadID.rawValue),
                "turn": .dictionary([
                    "id": .string(turnKey.turnID.rawValue),
                    "status": .string("completed"),
                    "items": .array([]),
                ]),
            ]
        )
        try await transport.sendServerRequest(
            id: .integer(19),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(threadID: threadID)
        )
        try await waitUntil {
            let requests = await session.pendingServerRequests()
            let snapshot = await session.canonicalSnapshot()
            return requests.count == 1 && snapshot.turns[turnKey] != nil
        }

        await thread.close()
        await transport.finishConnection()
        try await waitUntil {
            let requests = await session.pendingServerRequests()
            let snapshot = await session.canonicalSnapshot()
            return requests.isEmpty && snapshot.turns[turnKey] == nil
        }
        let unsubscribeCount = await transport.requestCount(method: "thread/unsubscribe")
        let disconnectedSnapshot = await session.canonicalSnapshot()
        XCTAssertEqual(unsubscribeCount, 0)
        XCTAssertNotNil(disconnectedSnapshot.threads[threadID])
        await session.stop()
    }

    func testUnleasedTerminalDetailUsesBoundedLRUAndActiveDetailIsProtected() async throws {
        let transport = RetentionTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                reconnectPolicy: .disabled,
                maximumRetainedUnleasedThreadDetails: 2
            )
        )
        _ = try await session.start()

        try await sendTerminalTurn(threadID: "a", transport: transport)
        try await waitUntil {
            await session.threadIndexSnapshot().summary(for: "a")?.latestTurnStatus == .completed
        }
        let indexBeforeEviction = await session.threadIndexSnapshot()
        let attentionBeforeEviction = try XCTUnwrap(
            indexBeforeEviction.summary(for: "a")
        ).attentionRevision
        for threadID in ["b", "c"] {
            try await sendTerminalTurn(threadID: ThreadID(threadID), transport: transport)
        }
        try await waitUntil {
            let snapshot = await session.canonicalSnapshot()
            return snapshot.turns[TurnKey(threadID: "a", turnID: "turn")] == nil
                && snapshot.turns[TurnKey(threadID: "b", turnID: "turn")] != nil
                && snapshot.turns[TurnKey(threadID: "c", turnID: "turn")] != nil
        }

        try await transport.sendNotification(
            method: "thread/name/updated",
            params: [
                "threadId": .string("b"),
                "threadName": .string("recently touched"),
            ]
        )
        try await sendTerminalTurn(threadID: "d", transport: transport)
        try await waitUntil {
            let snapshot = await session.canonicalSnapshot()
            return snapshot.turns[TurnKey(threadID: "c", turnID: "turn")] == nil
                && snapshot.turns[TurnKey(threadID: "b", turnID: "turn")] != nil
                && snapshot.turns[TurnKey(threadID: "d", turnID: "turn")] != nil
        }

        try await transport.sendNotification(
            method: "turn/started",
            params: [
                "threadId": .string("active"),
                "turn": .dictionary([
                    "id": .string("turn"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                    "itemsView": .string("notLoaded"),
                ]),
            ]
        )
        for _ in 0..<20 { await Task.yield() }
        let activeSnapshot = await session.canonicalSnapshot()
        XCTAssertNotNil(activeSnapshot.turns[TurnKey(threadID: "active", turnID: "turn")])

        let index = await session.threadIndexSnapshot()
        XCTAssertEqual(index.summary(for: "a")?.latestTurnStatus, .completed)
        XCTAssertEqual(index.summary(for: "c")?.latestTurnStatus, .completed)
        XCTAssertEqual(index.summary(for: "a")?.attentionRevision, attentionBeforeEviction)
        await session.stop()
    }

    func testUnleasedDetailRetentionStaysBoundedDuringRepeatedEviction() async throws {
        let transport = RetentionTestTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                reconnectPolicy: .disabled,
                maximumRetainedUnleasedThreadDetails: 2
            )
        )
        _ = try await session.start()

        for index in 0..<40 {
            try await sendTerminalTurn(
                threadID: ThreadID("churn-\(index)"),
                transport: transport
            )
        }

        try await waitUntil {
            let snapshot = await session.canonicalSnapshot()
            return snapshot.turns[TurnKey(threadID: "churn-0", turnID: "turn")] == nil
                && snapshot.turns[TurnKey(threadID: "churn-38", turnID: "turn")] != nil
                && snapshot.turns[TurnKey(threadID: "churn-39", turnID: "turn")] != nil
        }

        let snapshot = await session.canonicalSnapshot()
        let retainedTurnCount = (0..<40).reduce(into: 0) { count, index in
            if snapshot.turns[TurnKey(threadID: ThreadID("churn-\(index)"), turnID: "turn")] != nil {
                count += 1
            }
        }
        XCTAssertEqual(retainedTurnCount, 2)
        await session.stop()
    }

    private func sendTerminalTurn(
        threadID: ThreadID,
        transport: RetentionTestTransport
    ) async throws {
        try await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string(threadID.rawValue),
                "turn": .dictionary([
                    "id": .string("turn"),
                    "status": .string("completed"),
                    "items": .array([]),
                    "itemsView": .string("full"),
                ]),
            ]
        )
    }

    private static func fileApprovalParams(
        threadID: ThreadID
    ) -> [String: CodexJSONValue] {
        [
            "threadId": .string(threadID.rawValue),
            "turnId": .string("turn"),
            "itemId": .string("file-change"),
            "approvalId": .string("approval"),
            "startedAtMs": .int(1),
            "grantRoot": .string("/tmp"),
        ]
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for retention state")
        throw RetentionTestError.timedOut
    }
}

private enum RetentionTestError: Error {
    case timedOut
    case connectionNotOpen
}

private actor RetentionTestTransport: CodexFrameTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var outboundMethods: [String] = []

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard continuation == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let envelope = try CodexJSONRPCCodec.decode(frame)
        guard case .serverRequest(let request) = envelope else { return }
        outboundMethods.append(request.method)

        let result: CodexJSONValue
        switch request.method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(CodexHome.default.path),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("Codex Desktop/0.145.0-alpha.20 (Mac OS; arm64) test"),
            ])
        case "thread/start":
            result = Self.threadStartResult
        default:
            result = .dictionary([:])
        }
        continuation?.yield(
            try CodexJSONRPCCodec.encodeResult(id: request.id, result: result)
        )
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func sendNotification(
        method: String,
        params: [String: CodexJSONValue]
    ) throws {
        guard let continuation else { throw RetentionTestError.connectionNotOpen }
        continuation.yield(
            try CodexJSONRPCCodec.encodeNotification(method: method, objectParams: params)
        )
    }

    func sendServerRequest(
        id: CodexJSONRPCID,
        method: String,
        params: [String: CodexJSONValue]
    ) throws {
        guard let continuation else { throw RetentionTestError.connectionNotOpen }
        continuation.yield(
            try CodexJSONRPCCodec.encodeRequest(id: id, method: method, objectParams: params)
        )
    }

    func finishConnection() {
        continuation?.finish()
        continuation = nil
    }

    func requestCount(method: String) -> Int {
        outboundMethods.count { $0 == method }
    }

    private static let threadStartResult = CodexJSONValue.dictionary([
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
            "id": .string("thread"),
            "modelProvider": .string("openai"),
            "preview": .string("retained summary"),
            "sessionId": .string("session-thread"),
            "source": .string("appServer"),
            "status": .dictionary(["type": .string("idle")]),
            "turns": .array([]),
            "updatedAt": .int(1),
        ]),
    ])
}
