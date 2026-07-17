import XCTest
@testable import CodexCore

final class CodexSessionOrderingTests: XCTestCase {
    func testDirectSessionHandshakeAlwaysEnablesExperimentalAPI() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(
                capabilities: .init(experimentalAPI: false),
                reconnectPolicy: .disabled
            )
        )

        _ = try await session.start()
        let recordedParams = await transport.requestObjectParams(method: "initialize")
        let initializeParams = try XCTUnwrap(recordedParams.last)
        let capabilities = try XCTUnwrap(
            initializeParams["capabilities"]?.objectValue
        )
        XCTAssertEqual(capabilities["experimentalApi"], .bool(true))

        await session.stop()
    }

    func testInitializationBuffersEveryNonHandshakeFrameAndDrainsInWireOrder() async throws {
        let transport = ControllableCodexFrameTransport(autoInitialize: false)
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        let start = Task { try await session.start() }

        try await waitUntil {
            await transport.requestWriteCount(method: "initialize") == 1
        }
        let observation = await session.observeSessionState()

        try await transport.sendNotification(
            method: "thread/name/updated",
            params: Self.renameNotification(name: "first")
        )
        try await transport.sendServerRequest(
            id: .string("during-handshake"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "during-handshake")
        )
        try await transport.sendNotification(
            method: "thread/name/updated",
            params: Self.renameNotification(name: "second")
        )
        await drainScheduler()

        guard case .initializing = await session.lifecycle else {
            return XCTFail("The session should remain in the handshake phase")
        }
        let initializingSnapshot = await session.canonicalSnapshot()
        let initializingRequests = await session.pendingServerRequests()
        XCTAssertNil(initializingSnapshot.threads[Self.threadID])
        XCTAssertTrue(initializingRequests.isEmpty)

        try await transport.respondToLatestRequest(
            method: "initialize",
            result: Self.initializeResult
        )
        _ = try await start.value

        let state = await session.sessionStateSnapshot()
        XCTAssertEqual(state.canonical.threads[Self.threadID]?.metadata.name, "second")
        XCTAssertEqual(state.serverRequests.requests.map(\.key.requestID), [.string("during-handshake")])

        guard case .changes(let changes, _) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("The handshake drain should remain in retained journal history")
        }
        let orderedStateChanges = changes.compactMap { change -> String? in
            if change.fields.contains(.requests) { return "request" }
            if change.fields.contains(.threadMetadata) { return "thread" }
            return nil
        }
        XCTAssertEqual(orderedStateChanges, ["thread", "request", "thread"])

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testResponseStateIsCommittedBeforeRequestContinuationResumes() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let request = Task {
            try await session.performCall(
                method: .threadNameSet,
                params: Self.renameRequest(name: "committed")
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/name/set") == 1
        }
        try await transport.respondToLatestRequest(
            method: "thread/name/set",
            result: .dictionary([:])
        )

        let call = try await request.value
        let snapshot = await session.canonicalSnapshot()
        let thread = try XCTUnwrap(snapshot.threads[Self.threadID])
        XCTAssertEqual(thread.metadata.name, "committed")
        XCTAssertEqual(thread.lastChangedRevision, call.responseRevision)
        XCTAssertEqual(snapshot.revision, call.responseRevision)
        XCTAssertGreaterThan(call.responseRevision, call.startRevision)

        await session.stop()
    }

    func testMalformedFrameResumesPendingClientRequestWithProtocolViolation() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let request = Task {
            try await session.perform(
                method: .threadNameSet,
                params: Self.renameRequest(name: "never-committed")
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/name/set") == 1
        }
        let writtenRequestID = await transport.latestRequestID(method: "thread/name/set")
        let requestID = try XCTUnwrap(writtenRequestID)
        let malformedFrame = try JSONEncoder().encode(CodexJSONValue.dictionary([
            "jsonrpc": .string("2.0"),
            "id": requestID.jsonValue,
            "result": .dictionary([:]),
            "error": .dictionary([
                "code": .int(-32_000),
                "message": .string("invalid mixed response"),
            ]),
        ]))
        try await transport.sendRawFrame(malformedFrame)

        do {
            _ = try await request.value
            XCTFail("A malformed frame must fail the pending request instead of suspending it")
        } catch let error as CodexSessionError {
            guard case .protocolViolation(let detail) = error else {
                return XCTFail("Expected protocolViolation, got \(error)")
            }
            XCTAssertTrue(detail.contains("responseMustContainExactlyOneOutcome"))
        }

        await session.stop()
    }

    func testThreadReadResponsePublishesOneRevisionForThreadTurnAndItems() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let observation = await session.observeSessionState()

        let request = Task {
            try await session.performCall(
                method: .threadRead,
                params: .dictionary([
                    "threadId": .string(Self.threadID.rawValue),
                    "includeTurns": .bool(true),
                ])
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/read") == 1
        }
        try await transport.respondToLatestRequest(
            method: "thread/read",
            result: Self.threadReadResult
        )

        let call = try await request.value
        let snapshot = await session.canonicalSnapshot()
        let turnKey = TurnKey(threadID: Self.threadID, turnID: "turn-1")
        let itemKey = ItemKey(threadID: Self.threadID, turnID: "turn-1", itemID: "item-1")
        XCTAssertEqual(snapshot.revision, call.responseRevision)
        XCTAssertEqual(snapshot.threads[Self.threadID]?.lastChangedRevision, call.responseRevision)
        XCTAssertEqual(snapshot.turns[turnKey]?.lastChangedRevision, call.responseRevision)
        XCTAssertEqual(snapshot.items[itemKey]?.lastChangedRevision, call.responseRevision)

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected the thread/read transaction in retained history")
        }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.revision, call.responseRevision)
        XCTAssertEqual(changes.first?.threadIDs, Set([Self.threadID]))
        XCTAssertEqual(changes.first?.turnKeys, Set([turnKey]))
        XCTAssertEqual(changes.first?.itemKeys, Set([itemKey]))
        XCTAssertEqual(through, call.responseRevision)

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testEquivalentNotificationAndResponsePermutationsConverge() async throws {
        let responseThenNotification = try await runRenamePermutation(notificationFirst: false)
        let notificationThenResponse = try await runRenamePermutation(notificationFirst: true)

        XCTAssertEqual(responseThenNotification, notificationThenResponse)
        XCTAssertEqual(
            responseThenNotification.threads[Self.threadID]?.metadata.name,
            "converged"
        )
    }

    func testHistoryItemPagesFanOutAndInstallAtomicallyAfterOutOfOrderResponses() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        _ = await session.hydrateThreadHistory(Self.threadID)

        try await waitUntil {
            await transport.requestWriteCount(method: "thread/resume") == 1
        }
        try await transport.respondToLatestRequest(
            method: "thread/resume",
            result: Self.historyResumeResult
        )
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/turns/list") == 1
        }
        try await transport.respondToLatestRequest(
            method: "thread/turns/list",
            result: .dictionary([
                "data": .array([
                    Self.historyTurn(id: "turn-2"),
                    Self.historyTurn(id: "turn-1"),
                ]),
                "backwardsCursor": .string("turn-head"),
                "nextCursor": .null,
            ])
        )

        // The coordinator permits both item chains, so the session must write
        // both requests before either response is allowed to make progress.
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/items/list") == 2
        }
        let itemRequests = await transport.requestObjectParams(method: "thread/items/list")
        let requestedTurnIDs = itemRequests.compactMap { $0["turnId"] }
        let requestedCursors = itemRequests.compactMap { $0["cursor"] }
        XCTAssertEqual(itemRequests.count, 2)
        XCTAssertEqual(requestedTurnIDs.count, 2)
        XCTAssertTrue(requestedTurnIDs.contains(.string("turn-1")))
        XCTAssertTrue(requestedTurnIDs.contains(.string("turn-2")))
        XCTAssertEqual(requestedCursors, [.string("item-head"), .string("item-head")])

        let beforeItems = await session.canonicalSnapshot()
        XCTAssertNil(beforeItems.threads[Self.threadID])

        // Complete turn-2 first even though turn-1 is the older canonical turn.
        try await transport.respondToRequest(
            method: "thread/items/list",
            parameter: "turnId",
            equals: .string("turn-2"),
            result: Self.historyItemsResult(turnID: "turn-2", itemID: "item-2")
        )
        try await transport.sendNotification(
            method: "thread/name/updated",
            params: [
                "threadId": .string("history-response-marker"),
                "threadName": .string("seen"),
            ]
        )
        try await waitUntil {
            await session.canonicalSnapshot()
                .threads[ThreadID("history-response-marker")]?.metadata.name == "seen"
        }
        let halfComplete = await session.canonicalSnapshot()
        XCTAssertNil(halfComplete.threads[Self.threadID])

        try await transport.respondToRequest(
            method: "thread/items/list",
            parameter: "turnId",
            equals: .string("turn-1"),
            result: Self.historyItemsResult(turnID: "turn-1", itemID: "item-1")
        )
        try await waitUntil {
            let snapshot = await session.canonicalSnapshot()
            return snapshot.threads[Self.threadID]?.history.turnsCoverage == .full
                && snapshot.items[ItemKey(
                    threadID: Self.threadID,
                    turnID: "turn-1",
                    itemID: "item-1"
                )] != nil
                && snapshot.items[ItemKey(
                    threadID: Self.threadID,
                    turnID: "turn-2",
                    itemID: "item-2"
                )] != nil
        }

        let installed = await session.canonicalSnapshot()
        let thread = try XCTUnwrap(installed.threads[Self.threadID])
        XCTAssertEqual(thread.turnOrder, ["turn-1", "turn-2"])
        XCTAssertEqual(thread.history.mode, .paginated)
        XCTAssertEqual(thread.history.turnsCoverage, .full)
        XCTAssertTrue(thread.history.itemPagesByTurn.values.allSatisfy(\.isExhausted))
        XCTAssertEqual(
            Set(installed.turns.keys.filter { $0.threadID == Self.threadID }),
            [
                TurnKey(threadID: Self.threadID, turnID: "turn-1"),
                TurnKey(threadID: Self.threadID, turnID: "turn-2"),
            ]
        )

        await session.stop()
    }

    func testHistoryPageFailureDoesNotBlackHoleCurrentEpochStateNotifications() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        _ = await session.hydrateThreadHistory(Self.threadID)

        try await waitUntil {
            await transport.requestWriteCount(method: "thread/resume") == 1
        }
        try await transport.respondToLatestRequest(
            method: "thread/resume",
            result: Self.historyResumeResult
        )
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/turns/list") == 1
        }
        try await transport.respondErrorToLatestRequest(
            method: "thread/turns/list",
            error: .init(code: -32_000, message: "fixture page failure")
        )
        try await waitUntil {
            guard let loading = await session.threadHistoryLoadingState(Self.threadID),
                  case .failed = loading.phase else { return false }
            return true
        }

        try await transport.sendNotification(
            method: "thread/name/updated",
            params: Self.renameNotification(name: "live-after-page-failure")
        )
        try await waitUntil {
            await session.canonicalSnapshot().threads[Self.threadID]?.metadata.name
                == "live-after-page-failure"
        }

        await session.stop()
    }

    func testHistoryCoordinatorAppliesFailedEpochEventsButRejectsSealedEpochEvents() throws {
        let command = ThreadReconciliationCommand(
            threadID: Self.threadID,
            connectionEpoch: 7,
            operationID: .init(rawValue: 1)
        )
        var coordinator = PaginatedHistoryCoordinator()
        guard case .requestResume(let resume)? = coordinator
            .beginReconciliation(command)
            .first else {
            return XCTFail("Expected resume request")
        }
        guard case .requestTurns(let turns)? = coordinator.receiveResumeCut(
            threadID: Self.threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: "turn-head",
            itemsBackwardsCursor: "item-head",
            responseCursor: .init(connectionEpoch: 7, ordinal: 1),
            resumeThread: .dictionary(["id": .string(Self.threadID.rawValue)])
        ).first else {
            return XCTFail("Expected turns page request")
        }
        _ = coordinator.requestFailed(
            threadID: Self.threadID,
            requestID: turns.requestID,
            message: "fixture page failure"
        )

        let currentEvent = PaginatedHistoryBufferedLiveEvent(
            cursor: .init(connectionEpoch: 7, ordinal: 2),
            method: "thread/name/updated",
            params: .dictionary(Self.renameNotification(name: "current"))
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(threadID: Self.threadID, event: currentEvent),
            .applyImmediately
        )

        _ = coordinator.connectionLost(7)
        let obsoleteEvent = PaginatedHistoryBufferedLiveEvent(
            cursor: .init(connectionEpoch: 7, ordinal: 3),
            method: "thread/name/updated",
            params: .dictionary(Self.renameNotification(name: "obsolete"))
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(threadID: Self.threadID, event: obsoleteEvent),
            .ignoredStale
        )
    }

    func testIntegerAndStringServerRequestIDsCoexistWithoutCollision() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .integer(7),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "integer-id")
        )
        try await transport.sendServerRequest(
            id: .string("7"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "string-id")
        )
        try await waitUntil { await session.pendingServerRequests().count == 2 }

        let requests = await session.pendingServerRequests()
        XCTAssertEqual(Set(requests.map(\.key.requestID)), [.integer(7), .string("7")])
        let integerKey = try XCTUnwrap(requests.first { $0.key.requestID == .integer(7) }?.key)
        let stringKey = try XCTUnwrap(requests.first { $0.key.requestID == .string("7") }?.key)

        try await session.resolveServerRequest(
            integerKey,
            result: .dictionary(["decision": .string("accept")])
        )
        try await session.resolveServerRequest(
            stringKey,
            result: .dictionary(["decision": .string("decline")])
        )
        try await waitUntil {
            let integerCount = await transport.responseWriteCount(id: .integer(7))
            let stringCount = await transport.responseWriteCount(id: .string("7"))
            return integerCount == 1 && stringCount == 1
        }

        let remainingRequests = await session.pendingServerRequests()
        let integerResult = await transport.responseResult(id: .integer(7))
        let stringResult = await transport.responseResult(id: .string("7"))
        XCTAssertTrue(remainingRequests.isEmpty)
        XCTAssertEqual(
            integerResult,
            .dictionary(["decision": .string("accept")])
        )
        XCTAssertEqual(
            stringResult,
            .dictionary(["decision": .string("decline")])
        )

        await session.stop()
    }

    func testImmediateServerResolvedNotificationPreventsLateHandlerReply() async throws {
        let gate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled),
            serverRequestHandler: { _ in
                await gate.wait()
                return .result(.dictionary(["late": .bool(true)]))
            }
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .string("server-wins"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "server-wins")
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }
        try await waitUntil { await gate.waitingCount == 1 }

        try await transport.sendNotification(
            method: "serverRequest/resolved",
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .string("server-wins"),
            ]
        )
        try await waitUntil { await session.pendingServerRequests().isEmpty }

        await gate.open()
        try await waitUntil { await gate.completedCount == 1 }
        await drainScheduler()
        let responseCount = await transport.responseWriteCount(id: .string("server-wins"))
        let lifecycle = await session.lifecycle
        XCTAssertEqual(responseCount, 0)
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))

        await session.stop()
    }

    func testServerResolvedDropsMatchingReplyThatHasNotStartedWriting() async throws {
        let responseWriteGate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport(
            responseWriteGate: responseWriteGate
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        // Response A owns the transport write while response B remains queued.
        try await transport.sendServerRequest(
            id: .string("blocking-response"),
            method: CodexServerRequestKind.currentTime.method,
            params: [:]
        )
        try await waitUntil { await responseWriteGate.waitingCount == 1 }

        try await transport.sendServerRequest(
            id: .string("queued-response"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "queued-response")
        )
        try await waitUntil {
            await session.pendingServerRequests().contains {
                $0.key.requestID == .string("queued-response")
            }
        }
        let pending = await session.pendingServerRequests()
        let request = try XCTUnwrap(pending.first {
            $0.key.requestID == .string("queued-response")
        })
        try await session.resolveServerRequest(
            request.key,
            result: .dictionary(["decision": .string("accept")])
        )

        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .string("queued-response"),
            ]
        )
        // A following state notification is an ordering fence proving the
        // resolution was processed before the blocked writer is released.
        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.threadNameUpdated.rawValue,
            params: Self.renameNotification(name: "resolution-processed")
        )
        try await waitUntil {
            await session.canonicalSnapshot().threads[Self.threadID]?.metadata.name
                == "resolution-processed"
        }

        await responseWriteGate.open()
        try await waitUntil {
            await transport.responseWriteCount(id: .string("blocking-response")) == 1
        }
        await drainScheduler()
        let queuedResponseCount = await transport.responseWriteCount(
            id: .string("queued-response")
        )
        let lifecycle = await session.lifecycle
        XCTAssertEqual(queuedResponseCount, 0)
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))

        await session.stop()
    }

    func testServerResolvedDoesNotCancelReplyAfterTransportWriteStarts() async throws {
        let responseWriteGate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport(
            responseWriteGate: responseWriteGate
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .string("in-flight-response"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "in-flight-response")
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }
        let pending = await session.pendingServerRequests()
        let request = try XCTUnwrap(pending.first)
        try await session.resolveServerRequest(
            request.key,
            result: .dictionary(["decision": .string("accept")])
        )
        try await waitUntil { await responseWriteGate.waitingCount == 1 }

        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .string("in-flight-response"),
            ]
        )
        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.threadNameUpdated.rawValue,
            params: Self.renameNotification(name: "in-flight-resolution-processed")
        )
        try await waitUntil {
            await session.canonicalSnapshot().threads[Self.threadID]?.metadata.name
                == "in-flight-resolution-processed"
        }

        await responseWriteGate.open()
        try await waitUntil {
            await transport.responseWriteCount(id: .string("in-flight-response")) == 1
        }
        let lifecycle = await session.lifecycle
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))

        await session.stop()
    }

    func testServerResolvedKeepsIntegerAndStringRequestIDsDistinct() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .integer(7),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "integer-resolved-id")
        )
        try await transport.sendServerRequest(
            id: .string("7"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "string-resolved-id")
        )
        try await waitUntil { await session.pendingServerRequests().count == 2 }

        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .string("7"),
            ]
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }
        var pending = await session.pendingServerRequests()
        XCTAssertEqual(pending.map(\.key.requestID), [.integer(7)])

        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .int(7),
            ]
        )
        try await waitUntil { await session.pendingServerRequests().isEmpty }
        pending = await session.pendingServerRequests()
        let lifecycle = await session.lifecycle
        let integerResponseCount = await transport.responseWriteCount(id: .integer(7))
        let stringResponseCount = await transport.responseWriteCount(id: .string("7"))
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: 1))
        XCTAssertEqual(integerResponseCount, 0)
        XCTAssertEqual(stringResponseCount, 0)

        await session.stop()
    }

    func testServerResolvedRejectsMissingOrMismatchedThreadScope() async throws {
        try await assertServerResolvedRejected(
            requestID: "missing-thread",
            params: ["requestId": .string("missing-thread")]
        )
        try await assertServerResolvedRejected(
            requestID: "null-thread",
            params: [
                "threadId": .null,
                "requestId": .string("null-thread"),
            ]
        )
        try await assertServerResolvedRejected(
            requestID: "wrong-thread",
            params: [
                "threadId": .string("different-thread"),
                "requestId": .string("wrong-thread"),
            ]
        )
    }

    func testServerResolvedRejectsMissingInvalidOrUnknownRequestID() async throws {
        try await assertServerResolvedRejected(
            requestID: "missing-request-id",
            params: ["threadId": .string(Self.threadID.rawValue)]
        )
        let invalidIDs: [(String, CodexJSONValue)] = [
            ("null-request-id", .null),
            ("bool-request-id", .bool(true)),
            ("double-request-id", .double(7.5)),
            ("object-request-id", .dictionary(["id": .int(7)])),
            ("array-request-id", .array([.int(7)])),
        ]
        for (requestID, invalidID) in invalidIDs {
            try await assertServerResolvedRejected(
                requestID: requestID,
                params: [
                    "threadId": .string(Self.threadID.rawValue),
                    "requestId": invalidID,
                ]
            )
        }
        try await assertServerResolvedRejected(
            requestID: "known-request-id",
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "requestId": .string("unknown-request-id"),
            ]
        )
    }

    func testCallerCancellationStillLetsWrittenResponseUpdateCanonicalState() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let request = Task {
            try await session.perform(
                method: .threadNameSet,
                params: Self.renameRequest(name: "arrived-after-cancel")
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/name/set") == 1
        }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("The caller should observe cancellation")
        } catch is CancellationError {
            // Expected. The written request itself remains correlated in the session.
        }

        try await transport.respondToLatestRequest(
            method: "thread/name/set",
            result: .dictionary([:])
        )
        try await waitUntil {
            await session.canonicalSnapshot().threads[Self.threadID]?.metadata.name
                == "arrived-after-cancel"
        }
        let writeCount = await transport.requestWriteCount(method: "thread/name/set")
        XCTAssertEqual(writeCount, 1)

        await session.stop()
    }

    func testLastFrameIsReducedBeforeDisconnectIsPublished() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let observation = await session.observeSessionState()

        try await transport.sendNotificationThenFinish(
            method: "thread/name/updated",
            params: Self.renameNotification(name: "last-frame")
        )
        try await waitUntil {
            let state = await session.sessionStateSnapshot()
            return state.canonical.threads[Self.threadID]?.metadata.name == "last-frame"
                && state.lifecycle != .ready(connectionEpoch: 1)
        }

        guard case .changes(let changes, _) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected retained disconnect changes")
        }
        let threadIndex = try XCTUnwrap(changes.firstIndex {
            $0.fields.contains(.threadMetadata)
        })
        let disconnectIndex = try XCTUnwrap(changes.indices.first { index in
            index > threadIndex && changes[index].fields.contains(.connection)
        })
        XCTAssertLessThan(threadIndex, disconnectIndex)

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testWrittenMutationIsNeverReplayedAfterReconnect() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: Self.immediateReconnect)
        )
        _ = try await session.start()

        let mutation = Task {
            try await session.perform(
                method: .threadNameSet,
                params: Self.renameRequest(name: "one-attempt")
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/name/set") == 1
        }
        await transport.finish(connectionID: 0)

        do {
            _ = try await mutation.value
            XCTFail("Disconnect must fail the in-flight mutation")
        } catch {
            XCTAssertTrue(error is CodexSessionError)
        }
        try await waitUntil {
            let count = await transport.successfulConnectionCount
            let lifecycle = await session.lifecycle
            return count == 2 && lifecycle == .ready(connectionEpoch: 2)
        }
        await drainScheduler()

        let writeCount = await transport.requestWriteCount(method: "thread/name/set")
        let writeConnections = await transport.requestWriteConnectionIDs(
            method: "thread/name/set"
        )
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(writeConnections, [0])

        await session.stop()
    }

    func testOldEpochFramesAndHandlerCompletionsAreIgnored() async throws {
        let gate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: Self.immediateReconnect),
            serverRequestHandler: { _ in
                await gate.wait()
                return .result(.dictionary(["late": .bool(true)]))
            }
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .integer(91),
            method: "test/future",
            params: [:],
            connectionID: 0
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }
        try await waitUntil { await gate.waitingCount == 1 }
        await transport.finish(connectionID: 0)
        try await waitUntil {
            let count = await transport.successfulConnectionCount
            let lifecycle = await session.lifecycle
            return count == 2 && lifecycle == .ready(connectionEpoch: 2)
        }

        try await transport.sendNotification(
            method: "thread/name/updated",
            params: Self.renameNotification(name: "stale"),
            connectionID: 0
        )
        await gate.open()
        try await waitUntil { await gate.completedCount == 1 }
        await drainScheduler()

        let snapshot = await session.canonicalSnapshot()
        let requests = await session.pendingServerRequests()
        let responseCount = await transport.responseWriteCount(id: .integer(91))
        XCTAssertNil(snapshot.threads[Self.threadID])
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(responseCount, 0)

        await session.stop()
    }

    func testLoginAttemptIdentityIncludesConnectionEpochAndFirstCompletionWins() async throws {
        let loginResponse = CodexJSONValue.dictionary([
            "type": .string("chatgptDeviceCode"),
            "loginId": .string("reused-login-id"),
            "verificationUrl": .string("https://example.test/device"),
            "userCode": .string("ABCD-EFGH"),
        ])
        let transport = ControllableCodexFrameTransport(
            autoLoginStartResult: loginResponse
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: Self.immediateReconnect)
        )
        _ = try await session.start()

        let firstStart = try await session.startLogin(Self.deviceCodeLoginParams)
        guard case .identified(let firstAttempt) = firstStart else {
            return XCTFail("Device-code login must be interactive")
        }
        XCTAssertEqual(firstAttempt.key.connectionEpoch, 1)

        await transport.finish(connectionID: 0)
        try await waitUntil {
            await session.lifecycle == .ready(connectionEpoch: 2)
        }

        let secondStart = try await session.startLogin(Self.deviceCodeLoginParams)
        guard case .identified(let secondAttempt) = secondStart else {
            return XCTFail("Device-code login must be interactive")
        }
        XCTAssertEqual(secondAttempt.key.connectionEpoch, 2)
        XCTAssertEqual(firstAttempt.key.loginID, secondAttempt.key.loginID)
        XCTAssertNotEqual(firstAttempt.key, secondAttempt.key)

        try await transport.sendNotification(
            method: "account/login/completed",
            params: [
                "loginId": .string("reused-login-id"),
                "success": .bool(true),
            ],
            connectionID: 1
        )
        try await transport.sendNotification(
            method: "account/login/completed",
            params: [
                "loginId": .string("reused-login-id"),
                "success": .bool(false),
                "error": .string("conflicting duplicate"),
            ],
            connectionID: 1
        )

        let secondCompletion = try await secondAttempt.completion()
        XCTAssertTrue(secondCompletion.success)
        XCTAssertNil(secondCompletion.error)

        do {
            _ = try await firstAttempt.completion()
            XCTFail("A later epoch's same-ID completion must not satisfy an old attempt")
        } catch let error as CodexSessionError {
            guard case .connectionLost(let epoch, _) = error else {
                return XCTFail("Expected stale-epoch connection loss, got \(error)")
            }
            XCTAssertEqual(epoch, 1)
        }

        await session.stop()
    }

    func testAnonymousLoginAwaitsNullIDTerminalAndSurfacesFailure() async throws {
        let transport = ControllableCodexFrameTransport(
            autoLoginStartResult: .dictionary(["type": .string("apiKey")])
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let params = try CodexJSONValue.dictionary([
            "type": .string("apiKey"),
            "apiKey": .string("secret"),
        ]).decode(CodexSchemaLoginAccountParams.self)
        let result = try await session.startLogin(params)
        guard case .anonymous(let attempt) = result else {
            return XCTFail("API-key login must return an anonymous attempt")
        }
        XCTAssertEqual(attempt.response.rawValue.objectValue?["type"], .string("apiKey"))
        XCTAssertEqual(attempt.key.identity, .anonymous)

        do {
            _ = try await session.startLogin(params)
            XCTFail("Only one unresolved anonymous login may exist per epoch")
        } catch let error as CodexSessionError {
            XCTAssertEqual(error, .anonymousLoginAlreadyInProgress(connectionEpoch: 1))
        }

        try await transport.sendNotification(
            method: "account/login/completed",
            params: [
                "loginId": .null,
                "success": .bool(false),
                "error": .string("invalid API key"),
            ]
        )
        let completion = try await attempt.completion()
        XCTAssertFalse(completion.success)
        XCTAssertEqual(completion.error, "invalid API key")

        await session.stop()
    }

    func testIdentifiedLoginCancelUsesExactKeyAndAwaitsFalseTerminal() async throws {
        let transport = ControllableCodexFrameTransport(
            autoLoginStartResult: .dictionary([
                "type": .string("chatgptDeviceCode"),
                "loginId": .string("cancel-me"),
                "verificationUrl": .string("https://example.test/device"),
                "userCode": .string("ABCD-EFGH"),
            ]),
            autoCancelLogin: true
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let transaction = try await session.startLogin(Self.deviceCodeLoginParams)
        guard case .identified(let attempt) = transaction else {
            return XCTFail("Device-code login must be identified")
        }
        let completion = try await attempt.cancel()
        XCTAssertFalse(completion.success)
        XCTAssertEqual(completion.loginID, "cancel-me")

        let cancelParams = await transport.requestObjectParams(
            method: "account/login/cancel"
        )
        XCTAssertEqual(cancelParams.last?["loginId"], .string("cancel-me"))

        await session.stop()
    }

    func testTerminalLoginFactRemainsReplayableAfterConnectionSeal() async throws {
        let transport = ControllableCodexFrameTransport(
            autoLoginStartResult: .dictionary([
                "type": .string("chatgptDeviceCode"),
                "loginId": .string("terminal-before-seal"),
                "verificationUrl": .string("https://example.test/device"),
                "userCode": .string("ABCD-EFGH"),
            ])
        )
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: Self.immediateReconnect)
        )
        _ = try await session.start()

        let transaction = try await session.startLogin(Self.deviceCodeLoginParams)
        guard case .identified(let attempt) = transaction else {
            return XCTFail("Device-code login must be identified")
        }
        try await transport.sendNotification(
            method: "account/login/completed",
            params: [
                "loginId": .string("terminal-before-seal"),
                "success": .bool(true),
            ]
        )
        let beforeSeal = try await attempt.completion()
        XCTAssertTrue(beforeSeal.success)

        await transport.finish(connectionID: 0)
        try await waitUntil {
            await session.lifecycle == .ready(connectionEpoch: 2)
        }
        let afterSeal = try await attempt.completion()
        XCTAssertTrue(afterSeal.success)

        await session.stop()
    }

    func testServerRequestPendingToEmptyAdvancesRevisionAndSeedsAtomically() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let observation = await session.observeSessionState()
        Self.assertAtomic(observation.seed)

        try await transport.sendServerRequest(
            id: .string("revision"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "revision")
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }
        let pendingState = await session.sessionStateSnapshot()
        Self.assertAtomic(pendingState)
        let key = try XCTUnwrap(pendingState.serverRequests.requests.first?.key)

        try await session.resolveServerRequest(
            key,
            result: .dictionary(["decision": .string("decline")])
        )
        try await waitUntil { await session.pendingServerRequests().isEmpty }
        let emptyState = await session.sessionStateSnapshot()
        Self.assertAtomic(emptyState)
        XCTAssertGreaterThan(emptyState.stateRevision, pendingState.stateRevision)

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected request transitions in retained history")
        }
        let requestChanges = changes.filter { $0.fields.contains(.requests) }
        XCTAssertEqual(requestChanges.count, 2)
        XCTAssertLessThan(requestChanges[0].revision, requestChanges[1].revision)
        XCTAssertEqual(requestChanges[1].revision, emptyState.stateRevision)
        XCTAssertEqual(through, emptyState.stateRevision)

        let reseeded = await session.observeSessionState()
        Self.assertAtomic(reseeded.seed)
        XCTAssertEqual(reseeded.revision, reseeded.seed.stateRevision)

        await session.cancelObservation(observation.id)
        await session.cancelObservation(reseeded.id)
        await session.stop()
    }

    func testDefaultServerRequestPolicyRegistersBeforeRespondingAndUsesProtocolSafeDefaults() async throws {
        let responseGate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport(responseWriteGate: responseGate)
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        let observation = await session.observeSessionState()

        let earliestCurrentTime = Int(Date().timeIntervalSince1970.rounded(.down))
        try await transport.sendServerRequest(
            id: .string("default-current-time"),
            method: CodexServerRequestKind.currentTime.method,
            params: ["threadId": .string(Self.threadID.rawValue)]
        )
        try await waitUntil { await responseGate.waitingCount == 1 }

        let blockedCurrentTimeResponseCount = await transport.responseWriteCount(
            id: .string("default-current-time")
        )
        XCTAssertEqual(
            blockedCurrentTimeResponseCount,
            0,
            "The wire response must remain blocked until after request-state commits"
        )
        let committed = await session.sessionStateSnapshot()
        Self.assertAtomic(committed)
        XCTAssertTrue(committed.serverRequests.requests.isEmpty)

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected registration and terminal request revisions")
        }
        let requestChanges = changes.filter { $0.fields.contains(.requests) }
        XCTAssertEqual(requestChanges.count, 2)
        XCTAssertLessThan(requestChanges[0].revision, requestChanges[1].revision)
        XCTAssertEqual(requestChanges[1].revision, committed.stateRevision)
        XCTAssertEqual(through, committed.stateRevision)

        await responseGate.open()
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-current-time")) == 1
        }
        let latestCurrentTime = Int(Date().timeIntervalSince1970.rounded(.down))
        guard case .dictionary(let currentTimeResult)? = await transport.responseResult(
            id: .string("default-current-time")
        ), case .int(let currentTime)? = currentTimeResult["currentTimeAt"] else {
            return XCTFail("Expected currentTime/read to auto-return currentTimeAt")
        }
        XCTAssertGreaterThanOrEqual(currentTime, earliestCurrentTime)
        XCTAssertLessThanOrEqual(currentTime, latestCurrentTime)

        try await transport.sendServerRequest(
            id: .string("default-dynamic-tool"),
            method: CodexServerRequestKind.dynamicToolCall.method,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "turnId": .string("turn-defaults"),
                "callId": .string("call-defaults"),
                "tool": .string("lookup"),
                "arguments": .dictionary(["query": .string("value")]),
            ]
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-dynamic-tool")) == 1
        }
        let dynamicToolResult = await transport.responseResult(
            id: .string("default-dynamic-tool")
        )
        XCTAssertEqual(
            dynamicToolResult,
            .dictionary([
                "success": .bool(false),
                "contentItems": .array([]),
            ])
        )

        try await transport.sendServerRequest(
            id: .string("default-token-refresh"),
            method: CodexServerRequestKind.tokenRefresh.method,
            params: ["reason": .string("unauthorized")]
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-token-refresh")) == 1
        }
        let tokenRefreshError = await transport.responseError(
            id: .string("default-token-refresh")
        )
        XCTAssertEqual(
            tokenRefreshError,
            .init(
                code: -32_004,
                message: "Client capability is not configured",
                data: .dictionary([
                    "method": .string(CodexServerRequestKind.tokenRefresh.method)
                ])
            )
        )

        try await transport.sendServerRequest(
            id: .string("default-attestation"),
            method: CodexServerRequestKind.attestation.method,
            params: [:]
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-attestation")) == 1
        }
        let attestationError = await transport.responseError(
            id: .string("default-attestation")
        )
        XCTAssertEqual(
            attestationError,
            .init(
                code: -32_004,
                message: "Client capability is not configured",
                data: .dictionary([
                    "method": .string(CodexServerRequestKind.attestation.method)
                ])
            )
        )

        try await transport.sendServerRequest(
            id: .string("default-unknown"),
            method: "future/serverRequest",
            params: ["opaque": .bool(true)]
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-unknown")) == 1
        }
        let unknownError = await transport.responseError(
            id: .string("default-unknown")
        )
        XCTAssertEqual(
            unknownError,
            .init(
                code: -32_601,
                message: "Method not found",
                data: .dictionary(["method": .string("future/serverRequest")])
            )
        )

        try await transport.sendServerRequest(
            id: .string("default-interactive"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "default-interactive")
        )
        try await waitUntil {
            await session.pendingServerRequests().contains {
                $0.key.requestID == .string("default-interactive")
            }
        }
        await drainScheduler()
        let interactiveResponseCount = await transport.responseWriteCount(
            id: .string("default-interactive")
        )
        XCTAssertEqual(
            interactiveResponseCount,
            0
        )
        let pendingInteractiveRequests = await session.pendingServerRequests()
        let interactiveKey = try XCTUnwrap(
            pendingInteractiveRequests.first {
                $0.key.requestID == .string("default-interactive")
            }?.key
        )
        try await session.resolveServerRequest(
            interactiveKey,
            result: .dictionary(["decision": .string("decline")])
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("default-interactive")) == 1
        }

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testPendingCustomHandlerFallsThroughToTheSameDefaultPolicy() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled),
            serverRequestHandler: { _ in .pending }
        )
        _ = try await session.start()

        try await transport.sendServerRequest(
            id: .string("handler-dynamic-tool"),
            method: CodexServerRequestKind.dynamicToolCall.method,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "turnId": .string("turn-handler"),
                "callId": .string("call-handler"),
                "tool": .string("lookup"),
                "arguments": .dictionary([:]),
            ]
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("handler-dynamic-tool")) == 1
        }
        let dynamicToolResult = await transport.responseResult(
            id: .string("handler-dynamic-tool")
        )
        XCTAssertEqual(
            dynamicToolResult,
            .dictionary([
                "success": .bool(false),
                "contentItems": .array([]),
            ])
        )

        try await transport.sendServerRequest(
            id: .string("handler-interactive"),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: "handler-interactive")
        )
        try await waitUntil {
            await session.pendingServerRequests().contains {
                $0.key.requestID == .string("handler-interactive")
            }
        }
        await drainScheduler()
        let interactiveResponseCount = await transport.responseWriteCount(
            id: .string("handler-interactive")
        )
        XCTAssertEqual(
            interactiveResponseCount,
            0
        )

        let pendingInteractiveRequests = await session.pendingServerRequests()
        let key = try XCTUnwrap(
            pendingInteractiveRequests.first {
                $0.key.requestID == .string("handler-interactive")
            }?.key
        )
        try await session.resolveServerRequest(
            key,
            result: .dictionary(["decision": .string("decline")])
        )
        try await waitUntil {
            await transport.responseWriteCount(id: .string("handler-interactive")) == 1
        }

        await session.stop()
    }

    func testTypedServerRequestInboxProjectsOnlyPresentationSafeRequestData() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let observation = await session.observeServerRequests()
        XCTAssertEqual(observation.scope.fields, .requests)
        XCTAssertTrue(observation.seed.requests.isEmpty)
        XCTAssertEqual(observation.seed.revision, observation.revision)

        try await transport.sendServerRequest(
            id: .string("typed-command"),
            method: CodexServerRequestKind.commandApproval.method,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "turnId": .string("turn-approval"),
                "itemId": .string("item-command"),
                "approvalId": .string("approval-command"),
                "startedAtMs": .int(100),
                "command": .string("git status"),
                "cwd": .string("/workspace"),
                "availableDecisions": .array([.string("accept"), .string("decline")]),
                "commandActions": .array([.dictionary([
                    "type": .string("read"),
                    "command": .string("cat README.md"),
                    "name": .string("README.md"),
                    "path": .string("/workspace/README.md"),
                ])]),
                "networkApprovalContext": .dictionary([
                    "host": .string("example.com"),
                    "protocol": .string("https"),
                ]),
                "futureSecretMetadata": .string("must-not-enter-presentation"),
            ]
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.count == 1
        }

        let commandInbox = await session.serverRequestInboxSnapshot()
        let commandEntry = try XCTUnwrap(commandInbox.requests.first)
        XCTAssertEqual(commandEntry.key.requestID, .string("typed-command"))
        XCTAssertEqual(commandEntry.key, commandEntry.ledgerSnapshot.key)
        XCTAssertEqual(
            commandEntry.ledgerSnapshot.approvalCorrelation,
            .init(threadID: Self.threadID.rawValue, approvalID: "approval-command")
        )
        guard case .commandApproval(let command) = commandEntry.body else {
            return XCTFail("Expected typed command approval body")
        }
        XCTAssertEqual(command.command, "git status")
        XCTAssertEqual(command.cwd, "/workspace")
        XCTAssertEqual(command.commandActions.first?.type, "read")
        XCTAssertEqual(command.networkApprovalContext?.host, "example.com")
        XCTAssertFalse(
            String(describing: commandInbox).contains("must-not-enter-presentation")
        )

        try await session.resolveServerRequest(
            commandEntry.key,
            result: .dictionary(["decision": .string("accept")])
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.isEmpty
        }

        try await transport.sendServerRequest(
            id: .integer(44),
            method: CodexServerRequestKind.mcpElicitation.method,
            params: [
                "threadId": .string(Self.threadID.rawValue),
                "turnId": .string("turn-approval"),
                "serverName": .string("calendar"),
                "message": .string("Choose a calendar"),
                "mode": .string("form"),
                "requestedSchema": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([:]),
                ]),
                "_meta": .dictionary([
                    "opaque": .string("must-not-enter-mcp-presentation"),
                ]),
            ]
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.count == 1
        }

        let mcpInbox = await session.serverRequestInboxSnapshot()
        let mcpEntry = try XCTUnwrap(mcpInbox.requests.first)
        guard case .mcpElicitation(let elicitation) = mcpEntry.body else {
            return XCTFail("Expected typed MCP elicitation body")
        }
        XCTAssertEqual(elicitation.serverName, "calendar")
        guard case .form(let schema) = elicitation.mode else {
            return XCTFail("Expected MCP form schema")
        }
        XCTAssertEqual(
            schema,
            .dictionary(["type": .string("object"), "properties": .dictionary([:])])
        )
        XCTAssertFalse(
            String(describing: mcpInbox).contains("must-not-enter-mcp-presentation")
        )

        try await session.resolveServerRequest(
            mcpEntry.key,
            result: .dictionary(["action": .string("decline")])
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.isEmpty
        }

        try await transport.sendServerRequest(
            id: .integer(45),
            method: CodexServerRequestKind.legacyExecCommandApproval.method,
            params: [
                "conversationId": .string(Self.threadID.rawValue),
                "callId": .string("legacy-exec"),
                "approvalId": .string("legacy-approval"),
                "command": .array([.string("git"), .string("status")]),
                "cwd": .string("/workspace"),
                "parsedCmd": .array([.dictionary([
                    "type": .string("unknown"),
                    "cmd": .string("git status"),
                ])]),
                "reason": .string("Inspect the worktree"),
            ]
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.count == 1
        }
        let legacyExecInbox = await session.serverRequestInboxSnapshot()
        let legacyExecEntry = try XCTUnwrap(legacyExecInbox.requests.first)
        guard case .commandApproval(let legacyExec) = legacyExecEntry.body else {
            return XCTFail("Legacy protocol exec requests must remain presentable")
        }
        XCTAssertEqual(legacyExec.callID, "legacy-exec")
        XCTAssertEqual(legacyExec.command, "git status")
        XCTAssertEqual(legacyExec.commandArguments, ["git", "status"])
        XCTAssertEqual(legacyExec.cwd, "/workspace")
        XCTAssertEqual(legacyExec.parsedCommand?.count, 1)
        XCTAssertNil(legacyExec.startedAtMilliseconds)
        try await session.resolveServerRequest(
            legacyExecEntry.key,
            result: .dictionary(["decision": .string("denied")])
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.isEmpty
        }

        let legacyChanges: [String: CodexJSONValue] = [
            "/workspace/file.txt": .dictionary([
                "type": .string("update"),
                "unified_diff": .string("@@ -1 +1 @@"),
                "move_path": .null,
            ])
        ]
        try await transport.sendServerRequest(
            id: .integer(46),
            method: CodexServerRequestKind.legacyApplyPatchApproval.method,
            params: [
                "conversationId": .string(Self.threadID.rawValue),
                "callId": .string("legacy-patch"),
                "fileChanges": .dictionary(legacyChanges),
                "grantRoot": .string("/workspace"),
                "reason": .string("Apply the generated patch"),
            ]
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.count == 1
        }
        let legacyPatchInbox = await session.serverRequestInboxSnapshot()
        let legacyPatchEntry = try XCTUnwrap(legacyPatchInbox.requests.first)
        guard case .fileChangeApproval(let legacyPatch) = legacyPatchEntry.body else {
            return XCTFail("Legacy protocol patch requests must remain presentable")
        }
        XCTAssertEqual(legacyPatch.callID, "legacy-patch")
        XCTAssertEqual(
            legacyPatch.fileChanges,
            [
                "/workspace/file.txt": .update(
                    unifiedDiff: "@@ -1 +1 @@",
                    movePath: nil
                )
            ]
        )
        XCTAssertEqual(legacyPatch.grantRoot, "/workspace")
        XCTAssertNil(legacyPatch.startedAtMilliseconds)
        try await session.resolveServerRequest(
            legacyPatchEntry.key,
            result: .dictionary(["decision": .string("denied")])
        )

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testDedicatedRequestObservationPublishesPendingToEmptyRevision() async throws {
        let handlerGate = AsyncTestGate()
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled),
            serverRequestHandler: { _ in
                await handlerGate.wait()
                return .pending
            }
        )
        _ = try await session.start()
        let observation = await session.observeServerRequests()

        try await transport.sendServerRequest(
            id: .integer(55),
            method: "future/serverRequest",
            params: ["opaque": .string("not-presented")]
        )
        try await waitUntil {
            await session.serverRequestInboxSnapshot().requests.count == 1
        }
        try await waitUntil { await handlerGate.waitingCount == 1 }
        let pending = await session.serverRequestInboxSnapshot()
        XCTAssertGreaterThan(pending.revision, observation.revision)
        guard case .some(.unsupported(.unknown("future/serverRequest"))) = pending.requests.first?.body else {
            return XCTFail("Unknown payloads must be represented without exposing raw params")
        }
        XCTAssertFalse(String(describing: pending).contains("not-presented"))

        let key = try XCTUnwrap(pending.requests.first?.key)
        try await session.resolveServerRequest(
            key,
            result: .dictionary(["ok": .bool(true)])
        )
        try await waitUntil {
            let snapshot = await session.serverRequestInboxSnapshot()
            return snapshot.requests.isEmpty && snapshot.revision > pending.revision
        }
        let empty = await session.serverRequestInboxSnapshot()

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected retained request transitions")
        }
        XCTAssertEqual(changes.map(\.fields), [.requests, .requests])
        XCTAssertEqual(changes.last?.revision, empty.revision)
        XCTAssertEqual(through, empty.revision)

        await handlerGate.open()
        try await waitUntil { await handlerGate.completedCount == 1 }
        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testThreadIndexExposesSubagentMetadataThroughNarrowObservation() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let observation = await session.observeThreadIndex()
        XCTAssertTrue(observation.scope.fields.contains(.threadMetadata))

        let parentThreadID = ThreadID("parent-thread")
        let childThreadID = ThreadID("child-thread")
        try await transport.sendNotification(
            method: "thread/started",
            params: [
                "thread": .dictionary([
                    "id": .string(childThreadID.rawValue),
                    "sessionId": .string("child-session"),
                    "parentThreadId": .string(parentThreadID.rawValue),
                    "preview": .string("Investigating state flow"),
                    "ephemeral": .bool(true),
                    "historyMode": .string("legacy"),
                    "modelProvider": .string("openai"),
                    "createdAt": .int(1_700_000_000),
                    "updatedAt": .int(1_700_000_001),
                    "status": .dictionary(["type": .string("idle")]),
                    "path": .string("root/researcher"),
                    "cwd": .string("/tmp"),
                    "cliVersion": .string("test"),
                    "source": .string("cli"),
                    "agentNickname": .string("Scout"),
                    "agentRole": .string("researcher"),
                    "name": .string("Child task"),
                    "turns": .array([]),
                ]),
            ]
        )
        try await waitUntil {
            await session.threadIndexSnapshot().summary(for: childThreadID) != nil
        }

        let snapshot = await session.threadIndexSnapshot()
        let child = try XCTUnwrap(snapshot.summary(for: childThreadID))
        XCTAssertEqual(child.parentThreadID, parentThreadID)
        XCTAssertEqual(child.agentNickname, "Scout")
        XCTAssertEqual(child.agentRole, "researcher")
        XCTAssertEqual(child.path, "root/researcher")
        XCTAssertEqual(child.name, "Child task")
        XCTAssertEqual(child.cwd, .string("/tmp"))

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Subagent metadata must invalidate the thread index")
        }
        XCTAssertTrue(changes.contains { change in
            change.threadIDs.contains(childThreadID)
                && change.fields.contains(.threadMetadata)
        })
        XCTAssertEqual(through, snapshot.revision)

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testThreadIndexObservesInactiveRunningFailedAndUnreadRelevantActivity() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        // No transcript observation or selected-thread state is installed. The
        // catalogue must independently observe background thread activity.
        let observation = await session.observeThreadIndex()
        XCTAssertTrue(observation.seed.threads.isEmpty)
        XCTAssertEqual(observation.scope, CanonicalThreadIndexSnapshot.observationScope)

        let runningThread = ThreadID("inactive-running")
        try await transport.sendNotification(
            method: "turn/started",
            params: [
                "threadId": .string(runningThread.rawValue),
                "turn": .dictionary([
                    "id": .string("turn-running"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                    "itemsView": .string("notLoaded"),
                ]),
            ]
        )
        try await waitUntil {
            await session.threadIndexSnapshot()
                .summary(for: runningThread)?.latestTurnStatus == .inProgress
        }
        let runningSnapshot = await session.threadIndexSnapshot()
        let running = try XCTUnwrap(runningSnapshot.summary(for: runningThread))
        XCTAssertGreaterThan(running.attentionRevision, observation.revision)
        XCTAssertEqual(running.latestTurnID, "turn-running")

        try await transport.sendNotification(
            method: "item/started",
            params: [
                "threadId": .string(runningThread.rawValue),
                "turnId": .string("turn-running"),
                "startedAtMs": .int(1_700_000_000_000),
                "item": .dictionary([
                    "type": .string("agentMessage"),
                    "id": .string("message-running"),
                    "phase": .string("commentary"),
                    "text": .string(""),
                ]),
            ]
        )
        try await waitUntil {
            let snapshot = await session.threadIndexSnapshot()
            guard let summary = snapshot.summary(for: runningThread) else {
                return false
            }
            return summary.attentionRevision > running.attentionRevision
        }
        let itemStartSnapshot = await session.threadIndexSnapshot()
        let afterItemStart = try XCTUnwrap(itemStartSnapshot.summary(for: runningThread))

        try await transport.sendNotification(
            method: "item/agentMessage/delta",
            params: [
                "threadId": .string(runningThread.rawValue),
                "turnId": .string("turn-running"),
                "itemId": .string("message-running"),
                "delta": .string("background output"),
            ]
        )
        try await waitUntil {
            let snapshot = await session.threadIndexSnapshot()
            guard let summary = snapshot.summary(for: runningThread) else {
                return false
            }
            return summary.attentionRevision > afterItemStart.attentionRevision
        }
        let deltaSnapshot = await session.threadIndexSnapshot()
        let afterDelta = try XCTUnwrap(deltaSnapshot.summary(for: runningThread))
        XCTAssertEqual(afterDelta.lastChangedRevision, afterItemStart.lastChangedRevision)
        XCTAssertGreaterThan(afterDelta.attentionRevision, afterDelta.lastChangedRevision)

        let failedThread = ThreadID("inactive-failed")
        try await transport.sendNotification(
            method: "turn/completed",
            params: [
                "threadId": .string(failedThread.rawValue),
                "turn": .dictionary([
                    "id": .string("turn-failed"),
                    "status": .string("failed"),
                    "items": .array([]),
                    "itemsView": .string("notLoaded"),
                    "error": .dictionary(["message": .string("boom")]),
                ]),
            ]
        )
        try await waitUntil {
            await session.threadIndexSnapshot()
                .summary(for: failedThread)?.latestTurnStatus == .failed
        }
        let index = await session.threadIndexSnapshot()
        let failed = try XCTUnwrap(index.summary(for: failedThread))
        XCTAssertGreaterThan(failed.attentionRevision, observation.revision)
        XCTAssertEqual(index.threadIDs, [runningThread, failedThread])

        guard case .changes(let changes, let through) = await session.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Background thread-index activity must remain observable")
        }
        XCTAssertTrue(changes.contains { change in
            change.threadIDs.contains(runningThread) && change.fields.contains(.itemContent)
        })
        XCTAssertTrue(changes.contains { change in
            change.threadIDs.contains(failedThread) && change.fields.contains(.turnStatus)
        })
        XCTAssertEqual(through, index.revision)

        await session.cancelObservation(observation.id)
        await session.stop()
    }

    func testStopDuringReconnectBackoffPreventsAnotherOpenAttempt() async throws {
        let transport = ControllableCodexFrameTransport(failedOpenAttempts: 1)
        let backoff = AsyncTestGate()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .init(
                isEnabled: true,
                initialDelayMilliseconds: 25,
                maximumDelayMilliseconds: 25,
                multiplier: 1
            )),
            reconnectSleep: { _ in await backoff.wait() }
        )
        let start = Task { try await session.start() }

        try await waitUntil { await backoff.waitingCount == 1 }
        guard case .reconnecting(afterConnectionEpoch: nil, attempt: 2) = await session.lifecycle else {
            return XCTFail("Expected the session to be suspended in retry backoff")
        }
        await session.stop()

        do {
            _ = try await start.value
            XCTFail("Stopping should fail the start waiter")
        } catch let error as CodexSessionError {
            XCTAssertEqual(error, .closed)
        }
        let stoppedLifecycle = await session.lifecycle
        let attemptsBeforeOpeningGate = await transport.openAttemptCount
        XCTAssertEqual(stoppedLifecycle, .stopped)
        XCTAssertEqual(attemptsBeforeOpeningGate, 1)

        await backoff.open()
        try await waitUntil { await backoff.completedCount == 1 }
        await drainScheduler()
        let attemptsAfterOpeningGate = await transport.openAttemptCount
        XCTAssertEqual(attemptsAfterOpeningGate, 1)
    }

    func testCleanReaderEOFBecomesConnectionLossWithoutDisabledReconnect() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        await transport.finish(connectionID: 0)
        try await waitUntil { await session.lifecycle == .stopped }

        let openAttempts = await transport.openAttemptCount
        XCTAssertEqual(openAttempts, 1)
        await session.stop()
    }

    func testInvalidUTF8StdioLineAbortsAndNeverReconnects() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: Self.immediateReconnect)
        )
        _ = try await session.start()

        let frames = try CodexLineBuffer().append(Data([0xFF, 0x0A]))
        XCTAssertEqual(frames, [Data([0xFF])])
        try await transport.sendRawFrame(try XCTUnwrap(frames.first))
        try await waitUntil { await session.lifecycle == .stopped }

        let openAttempts = await transport.openAttemptCount
        XCTAssertEqual(openAttempts, 1)
        await session.stop()
    }

    func testCommandOperationRegistersBeforeWriteAndResponseTerminatesOutput() async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let handle = try await session.startCommandExec(.init(
            command: ["echo", "ordered"],
            processID: "command-ordered",
            tty: false
        ))
        try await waitUntil {
            await transport.requestWriteCount(method: "command/exec") == 1
        }

        let recordedCommandParams = await transport.requestObjectParams(
            method: "command/exec"
        )
        let params = try XCTUnwrap(recordedCommandParams.last)
        XCTAssertEqual(params["processId"], .string("command-ordered"))
        XCTAssertEqual(params["streamStdin"], .bool(true))
        XCTAssertEqual(params["streamStdoutStderr"], .bool(true))

        try await transport.sendNotification(
            method: "command/exec/outputDelta",
            params: [
                "processId": .string("command-ordered"),
                "stream": .string("stdout"),
                "deltaBase64": .string(Data("first".utf8).base64EncodedString()),
                "capReached": .bool(false),
            ]
        )
        try await transport.respondToLatestRequest(
            method: "command/exec",
            result: .dictionary([
                "exitCode": .int(0),
                "stdout": .string("first"),
                "stderr": .string(""),
            ])
        )

        let result = try await handle.wait()
        XCTAssertEqual(result.exitCode, 0)
        var output = handle.outputStream.makeAsyncIterator()
        let firstOutput = await output.next()
        let delta = try XCTUnwrap(firstOutput)
        XCTAssertEqual(String(decoding: delta.data, as: UTF8.self), "first")
        let outputEnd = await output.next()
        XCTAssertNil(outputEnd)

        try await transport.sendNotification(
            method: "command/exec/outputDelta",
            params: [
                "processId": .string("command-ordered"),
                "stream": .string("stdout"),
                "deltaBase64": .string(Data("late".utf8).base64EncodedString()),
                "capReached": .bool(false),
            ]
        )
        try await waitUntil {
            await session.operationDiagnostics().entries.contains {
                $0.kind == .unmatchedOperation
                    && $0.method == "command/exec/outputDelta"
            }
        }

        await session.stop()
    }

    private func runRenamePermutation(
        notificationFirst: Bool
    ) async throws -> CanonicalStateSnapshot {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()

        let request = Task {
            try await session.performCall(
                method: .threadNameSet,
                params: Self.renameRequest(name: "converged")
            )
        }
        try await waitUntil {
            await transport.requestWriteCount(method: "thread/name/set") == 1
        }

        if notificationFirst {
            try await transport.sendNotification(
                method: "thread/name/updated",
                params: Self.renameNotification(name: "converged")
            )
            try await transport.respondToLatestRequest(
                method: "thread/name/set",
                result: .dictionary([:])
            )
        } else {
            try await transport.respondToLatestRequest(
                method: "thread/name/set",
                result: .dictionary([:])
            )
            try await transport.sendNotification(
                method: "thread/name/updated",
                params: Self.renameNotification(name: "converged")
            )
        }
        try await transport.sendNotification(
            method: "thread/name/updated",
            params: [
                "threadId": .string("ordering-marker"),
                "threadName": .string("seen"),
            ]
        )

        _ = try await request.value
        try await waitUntil {
            await session.canonicalSnapshot().threads[ThreadID("ordering-marker")]?.metadata.name
                == "seen"
        }
        let snapshot = await session.canonicalSnapshot()
        await session.stop()
        return snapshot
    }

    private func assertServerResolvedRejected(
        requestID: String,
        params: [String: CodexJSONValue],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let transport = ControllableCodexFrameTransport()
        let session = CodexSession(
            transport: transport,
            configuration: .init(reconnectPolicy: .disabled)
        )
        _ = try await session.start()
        try await transport.sendServerRequest(
            id: .string(requestID),
            method: CodexServerRequestKind.fileChangeApproval.method,
            params: Self.fileApprovalParams(itemID: requestID)
        )
        try await waitUntil { await session.pendingServerRequests().count == 1 }

        try await transport.sendNotification(
            method: CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
            params: params
        )
        try await waitUntil { await session.lifecycle == .stopped }

        let responseCount = await transport.responseWriteCount(id: .string(requestID))
        let openAttemptCount = await transport.openAttemptCount
        XCTAssertEqual(responseCount, 0, file: file, line: line)
        XCTAssertEqual(openAttemptCount, 1, file: file, line: line)
        await session.stop()
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
        XCTFail("Timed out waiting for asynchronous condition")
        throw OrderingTestError.timedOut
    }

    private func drainScheduler() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static func assertAtomic(
        _ state: CodexSessionStateSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.stateRevision, state.canonical.revision, file: file, line: line)
        XCTAssertEqual(state.stateRevision, state.serverRequests.revision, file: file, line: line)
    }

    private static func renameRequest(name: String) -> CodexJSONValue {
        .dictionary([
            "threadId": .string(threadID.rawValue),
            "name": .string(name),
        ])
    }

    private static func renameNotification(name: String) -> [String: CodexJSONValue] {
        [
            "threadId": .string(threadID.rawValue),
            "threadName": .string(name),
        ]
    }

    private static func fileApprovalParams(
        itemID: String
    ) -> [String: CodexJSONValue] {
        [
            "threadId": .string(threadID.rawValue),
            "turnId": .string("turn-approval"),
            "itemId": .string(itemID),
            "approvalId": .string("approval-\(itemID)"),
            "startedAtMs": .int(1),
            "grantRoot": .string("/workspace"),
        ]
    }

    private static func historyTurn(id: String) -> CodexJSONValue {
        .dictionary([
            "id": .string(id),
            "status": .string("completed"),
            "items": .array([]),
            "itemsView": .string("summary"),
        ])
    }

    private static func historyItemsResult(
        turnID: String,
        itemID: String
    ) -> CodexJSONValue {
        .dictionary([
            "data": .array([.dictionary([
                "turnId": .string(turnID),
                "item": .dictionary([
                    "id": .string(itemID),
                    "type": .string("agentMessage"),
                    "phase": .string("final_answer"),
                    "text": .string(itemID),
                ]),
            ])]),
            "backwardsCursor": .string("item-head"),
            "nextCursor": .null,
        ])
    }

    private static let threadID = ThreadID("thread-1")
    private static let deviceCodeLoginParams: CodexSchemaLoginAccountParams = {
        try! CodexJSONValue.dictionary([
            "type": .string("chatgptDeviceCode")
        ]).decode(CodexSchemaLoginAccountParams.self)
    }()
    fileprivate static let initializeResult = CodexJSONValue.dictionary([
        "codexHome": .string(CodexHome.default.path),
        "platformFamily": .string("unix"),
        "platformOs": .string("macos"),
        "userAgent": .string("Codex Desktop/0.145.0-alpha.20 (Mac OS; arm64) test"),
    ])
    private static let threadReadResult = CodexJSONValue.dictionary([
        "thread": .dictionary([
            "cliVersion": .string("alpha.20"),
            "createdAt": .int(1),
            "cwd": .string("/tmp"),
            "ephemeral": .bool(false),
            "historyMode": .string("legacy"),
            "id": .string(threadID.rawValue),
            "modelProvider": .string("openai"),
            "preview": .string("hello"),
            "sessionId": .string("session-thread-1"),
            "source": .string("appServer"),
            "status": .dictionary(["type": .string("idle")]),
            "turns": .array([.dictionary([
                "id": .string("turn-1"),
                "items": .array([.dictionary([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "phase": .string("final_answer"),
                    "text": .string("done"),
                ])]),
                "itemsView": .string("full"),
                "status": .string("completed"),
            ])]),
            "updatedAt": .int(2),
        ]),
    ])
    private static let historyResumeResult = CodexJSONValue.dictionary([
        "approvalPolicy": .string("on-request"),
        "approvalsReviewer": .string("auto_review"),
        "cwd": .string("/tmp"),
        "model": .string("gpt-5.6"),
        "modelProvider": .string("openai"),
        "sandbox": .dictionary(["type": .string("workspaceWrite")]),
        "turnsBackwardsCursor": .string("turn-head"),
        "itemsBackwardsCursor": .string("item-head"),
        "thread": .dictionary([
            "cliVersion": .string("alpha.20"),
            "createdAt": .int(1),
            "cwd": .string("/tmp"),
            "ephemeral": .bool(false),
            "historyMode": .string("paginated"),
            "id": .string(threadID.rawValue),
            "modelProvider": .string("openai"),
            "preview": .string(""),
            "sessionId": .string("session-thread-1"),
            "source": .string("appServer"),
            "status": .dictionary(["type": .string("idle")]),
            "turns": .array([]),
            "updatedAt": .int(1),
        ]),
    ])
    private static let immediateReconnect = CodexReconnectPolicy(
        isEnabled: true,
        initialDelayMilliseconds: 0,
        maximumDelayMilliseconds: 0,
        multiplier: 1
    )
}

private enum OrderingTestError: Error {
    case timedOut
    case transportNotOpen
    case requestNotFound(String)
    case configuredOpenFailure
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0
    private(set) var completedCount = 0

    func wait() async {
        if !isOpen {
            waitingCount += 1
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        completedCount += 1
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor ControllableCodexFrameTransport: CodexFrameTransport {
    private struct Connection {
        let id: Int
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
    }

    private struct RecordedFrame: Sendable {
        let connectionID: Int
        let envelope: CodexJSONRPCEnvelope
    }

    private let autoInitialize: Bool
    private let autoLoginStartResult: CodexJSONValue?
    private let autoCancelLogin: Bool
    private let responseWriteGate: AsyncTestGate?
    private var failedOpenAttemptsRemaining: Int
    private var connections: [Int: Connection] = [:]
    private var activeConnectionID: Int?
    private var nextConnectionID = 0
    private var frames: [RecordedFrame] = []
    private(set) var openAttemptCount = 0

    init(
        autoInitialize: Bool = true,
        failedOpenAttempts: Int = 0,
        responseWriteGate: AsyncTestGate? = nil,
        autoLoginStartResult: CodexJSONValue? = nil,
        autoCancelLogin: Bool = false
    ) {
        self.autoInitialize = autoInitialize
        self.autoLoginStartResult = autoLoginStartResult
        self.autoCancelLogin = autoCancelLogin
        self.failedOpenAttemptsRemaining = failedOpenAttempts
        self.responseWriteGate = responseWriteGate
    }

    var successfulConnectionCount: Int { connections.count }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        openAttemptCount += 1
        if failedOpenAttemptsRemaining > 0 {
            failedOpenAttemptsRemaining -= 1
            throw OrderingTestError.configuredOpenFailure
        }
        guard activeConnectionID == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }

        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let id = nextConnectionID
        nextConnectionID += 1
        connections[id] = .init(id: id, continuation: pair.continuation)
        activeConnectionID = id
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        guard let connectionID = activeConnectionID,
              let connection = connections[connectionID] else {
            throw OrderingTestError.transportNotOpen
        }
        let envelope = try CodexJSONRPCCodec.decode(frame)
        if case .response = envelope, let responseWriteGate {
            await responseWriteGate.wait()
        }
        frames.append(.init(connectionID: connectionID, envelope: envelope))

        if autoInitialize,
           case .serverRequest(let request) = envelope,
           request.method == "initialize" {
            connection.continuation.yield(try CodexJSONRPCCodec.encodeResult(
                id: request.id,
                result: CodexSessionOrderingTests.initializeResult
            ))
        } else if let autoLoginStartResult,
                  case .serverRequest(let request) = envelope,
                  request.method == "account/login/start" {
            connection.continuation.yield(try CodexJSONRPCCodec.encodeResult(
                id: request.id,
                result: autoLoginStartResult
            ))
        } else if autoCancelLogin,
                  case .serverRequest(let request) = envelope,
                  request.method == "account/login/cancel" {
            connection.continuation.yield(try CodexJSONRPCCodec.encodeResult(
                id: request.id,
                result: .dictionary(["status": .string("canceled")])
            ))
            let loginID = request.params["loginId"] ?? .null
            connection.continuation.yield(try CodexJSONRPCCodec.encodeNotification(
                method: "account/login/completed",
                objectParams: [
                    "loginId": loginID,
                    "success": .bool(false),
                ]
            ))
        }
    }

    func close() async {
        guard let connectionID = activeConnectionID else { return }
        connections[connectionID]?.continuation.finish()
        activeConnectionID = nil
    }

    func requestWriteCount(method: String) -> Int {
        frames.reduce(into: 0) { count, frame in
            if case .serverRequest(let request) = frame.envelope,
               request.method == method {
                count += 1
            }
        }
    }

    func requestWriteConnectionIDs(method: String) -> [Int] {
        frames.compactMap { frame in
            guard case .serverRequest(let request) = frame.envelope,
                  request.method == method else { return nil }
            return frame.connectionID
        }
    }

    func requestObjectParams(method: String) -> [[String: CodexJSONValue]] {
        frames.compactMap { frame in
            guard case .serverRequest(let request) = frame.envelope,
                  request.method == method else { return nil }
            return request.params
        }
    }

    func latestRequestID(method: String) -> CodexJSONRPCID? {
        frames.reversed().compactMap { frame -> CodexJSONRPCID? in
            guard case .serverRequest(let request) = frame.envelope,
                  request.method == method else { return nil }
            return request.id
        }.first
    }

    func responseWriteCount(id: CodexJSONRPCID) -> Int {
        frames.reduce(into: 0) { count, frame in
            if case .response(let response) = frame.envelope, response.id == id {
                count += 1
            }
        }
    }

    func responseResult(id: CodexJSONRPCID) -> CodexJSONValue? {
        frames.reversed().compactMap { frame -> CodexJSONValue? in
            guard case .response(let response) = frame.envelope,
                  response.id == id,
                  case .result(let result) = response.outcome else { return nil }
            return result
        }.first
    }

    func responseError(id: CodexJSONRPCID) -> CodexJSONRPCErrorObject? {
        frames.reversed().compactMap { frame -> CodexJSONRPCErrorObject? in
            guard case .response(let response) = frame.envelope,
                  response.id == id,
                  case .error(let error) = response.outcome else { return nil }
            return error
        }.first
    }

    func respondToLatestRequest(
        method: String,
        result: CodexJSONValue,
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        guard let request = frames.reversed().compactMap({ frame -> CodexJSONRPCServerRequestEnvelope? in
            guard frame.connectionID == connectionID,
                  case .serverRequest(let request) = frame.envelope,
                  request.method == method else { return nil }
            return request
        }).first else {
            throw OrderingTestError.requestNotFound(method)
        }
        connections[connectionID]?.continuation.yield(
            try CodexJSONRPCCodec.encodeResult(id: request.id, result: result)
        )
    }

    func respondErrorToLatestRequest(
        method: String,
        error: CodexJSONRPCErrorObject,
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        guard let request = frames.reversed().compactMap({ frame -> CodexJSONRPCServerRequestEnvelope? in
            guard frame.connectionID == connectionID,
                  case .serverRequest(let request) = frame.envelope,
                  request.method == method else { return nil }
            return request
        }).first else {
            throw OrderingTestError.requestNotFound(method)
        }
        connections[connectionID]?.continuation.yield(
            try CodexJSONRPCCodec.encodeError(id: request.id, error: error)
        )
    }

    func respondToRequest(
        method: String,
        parameter: String,
        equals expectedValue: CodexJSONValue,
        result: CodexJSONValue,
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        guard let request = frames.reversed().compactMap({ frame -> CodexJSONRPCServerRequestEnvelope? in
            guard frame.connectionID == connectionID,
                  case .serverRequest(let request) = frame.envelope,
                  request.method == method,
                  request.params[parameter] == expectedValue else { return nil }
            return request
        }).first else {
            throw OrderingTestError.requestNotFound("\(method)[\(parameter)]")
        }
        connections[connectionID]?.continuation.yield(
            try CodexJSONRPCCodec.encodeResult(id: request.id, result: result)
        )
    }

    func sendNotification(
        method: String,
        params: [String: CodexJSONValue],
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        connections[connectionID]?.continuation.yield(
            try CodexJSONRPCCodec.encodeNotification(method: method, objectParams: params)
        )
    }

    func sendRawFrame(
        _ frame: Data,
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        connections[connectionID]?.continuation.yield(frame)
    }

    func sendServerRequest(
        id: CodexJSONRPCID,
        method: String,
        params: [String: CodexJSONValue],
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        connections[connectionID]?.continuation.yield(
            try CodexJSONRPCCodec.encodeRequest(id: id, method: method, objectParams: params)
        )
    }

    func sendNotificationThenFinish(
        method: String,
        params: [String: CodexJSONValue],
        connectionID requestedConnectionID: Int? = nil
    ) throws {
        let connectionID = try resolvedConnectionID(requestedConnectionID)
        guard let connection = connections[connectionID] else {
            throw OrderingTestError.transportNotOpen
        }
        connection.continuation.yield(
            try CodexJSONRPCCodec.encodeNotification(method: method, objectParams: params)
        )
        connection.continuation.finish()
    }

    func finish(connectionID: Int) {
        connections[connectionID]?.continuation.finish()
    }

    private func resolvedConnectionID(_ requested: Int?) throws -> Int {
        if let requested, connections[requested] != nil { return requested }
        if requested != nil { throw OrderingTestError.transportNotOpen }
        guard let activeConnectionID else { throw OrderingTestError.transportNotOpen }
        return activeConnectionID
    }
}
