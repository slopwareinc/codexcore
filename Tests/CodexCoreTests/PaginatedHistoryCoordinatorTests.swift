import XCTest
@testable import CodexCore

final class PaginatedHistoryCoordinatorTests: XCTestCase {
    func testResumeAnchorsNeverFilterLiveFrames() throws {
        let threadID = ThreadID("thread-1")
        let command = reconciliation(threadID: threadID, epoch: 7, operation: 4)
        var coordinator = PaginatedHistoryCoordinator()

        let resume = try resumeRequest(coordinator.beginReconciliation(command))
        XCTAssertTrue(resume.excludeTurns)
        XCTAssertEqual(resume.reconciliation, command)

        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 7, ordinal: 8, method: "before-cut")
            ),
            .applyImmediately
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 7, ordinal: 12, method: "after-cut")
            ),
            .applyImmediately
        )

        XCTAssertTrue(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: .init(rawValue: resume.requestID.rawValue + 100),
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 7, ordinal: 10),
            resumeThread: .dictionary(["id": .string(threadID.rawValue)])
        ).isEmpty)

        let installation = try install(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 7, ordinal: 10),
            resumeThread: .dictionary(["id": .string(threadID.rawValue)])
        ))

        XCTAssertEqual(installation.resumeResponseCursor, .init(connectionEpoch: 7, ordinal: 10))
        XCTAssertTrue(installation.bufferedLiveEvents.isEmpty)
        XCTAssertTrue(installation.turns.isEmpty)
        XCTAssertTrue(installation.items.isEmpty)
        XCTAssertEqual(installation.historyState.mode, .paginated)
        XCTAssertEqual(installation.historyState.turnsCoverage, .full)
        XCTAssertTrue(installation.historyState.turnsPage.isExhausted)
        XCTAssertFalse(installation.historyState.isStaleAfterReconnect)
        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 7, ordinal: 13, method: "now-live")
            ),
            .applyImmediately
        )
    }

    func testPagesTurnsThenItemsWithBoundedParallelismDeduplicationAndStableOrder() throws {
        let threadID = ThreadID("thread-1")
        let command = reconciliation(threadID: threadID, epoch: 3, operation: 1)
        var coordinator = PaginatedHistoryCoordinator(policy: .init(
            turnPageLimit: 2,
            itemPageLimit: 3,
            maximumConcurrentItemPages: 2,
            maximumBufferedLiveEvents: 16
        ))

        let resume = try resumeRequest(coordinator.beginReconciliation(command))
        let firstTurns = try turnsRequest(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: "turn-head",
            itemsBackwardsCursor: "item-head",
            responseCursor: .init(connectionEpoch: 3, ordinal: 10),
            resumeThread: .dictionary(["id": .string(threadID.rawValue)])
        ))
        XCTAssertEqual(firstTurns.cursor, "turn-head")
        XCTAssertEqual(firstTurns.limit, 2)
        XCTAssertEqual(firstTurns.sortDirection, .descending)
        XCTAssertEqual(firstTurns.itemsView, .summary)

        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 3, ordinal: 14, method: "fourteen")
            ),
            .applyImmediately
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 3, ordinal: 12, method: "twelve")
            ),
            .applyImmediately
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(
                threadID: threadID,
                event: liveEvent(epoch: 3, ordinal: 12, method: "duplicate")
            ),
            .applyImmediately
        )

        let secondTurns = try turnsRequest(coordinator.receiveTurnsPage(
            threadID: threadID,
            requestID: firstTurns.requestID,
            data: [turn("turn-3"), turn("turn-2")],
            backwardsCursor: "turn-head",
            nextCursor: "turn-older"
        ))
        XCTAssertEqual(secondTurns.cursor, "turn-older")

        let firstItemEffects = coordinator.receiveTurnsPage(
            threadID: threadID,
            requestID: secondTurns.requestID,
            data: [turn("turn-2", marker: "duplicate-older"), turn("turn-1")],
            backwardsCursor: "turn-head",
            nextCursor: nil
        )
        let firstItemRequests = try itemRequests(firstItemEffects)
        XCTAssertEqual(firstItemRequests.count, 2)
        XCTAssertEqual(firstItemRequests.map(\.turnID), ["turn-3", "turn-2"])
        XCTAssertEqual(Set(firstItemRequests.map(\.cursor)), ["item-head"])
        XCTAssertEqual(Set(firstItemRequests.map(\.limit)), [3])

        let turn3Request = try XCTUnwrap(firstItemRequests.first { $0.turnID == "turn-3" })
        let turn2Request = try XCTUnwrap(firstItemRequests.first { $0.turnID == "turn-2" })
        let turn1Request = try itemsRequest(coordinator.receiveItemsPage(
            threadID: threadID,
            turnID: "turn-3",
            requestID: turn3Request.requestID,
            data: [item(turn: "turn-3", item: "item-3b"), item(turn: "turn-3", item: "item-3a")],
            backwardsCursor: "item-head",
            nextCursor: nil
        ))
        XCTAssertEqual(turn1Request.turnID, "turn-1")

        let turn2OlderRequest = try itemsRequest(coordinator.receiveItemsPage(
            threadID: threadID,
            turnID: "turn-2",
            requestID: turn2Request.requestID,
            data: [item(turn: "turn-2", item: "item-2b")],
            backwardsCursor: "item-head",
            nextCursor: "item-2-older"
        ))
        XCTAssertEqual(turn2OlderRequest.turnID, "turn-2")
        XCTAssertEqual(turn2OlderRequest.cursor, "item-2-older")

        XCTAssertTrue(coordinator.receiveItemsPage(
            threadID: threadID,
            turnID: "turn-1",
            requestID: turn1Request.requestID,
            data: [],
            backwardsCursor: "item-head",
            nextCursor: nil
        ).isEmpty)

        let installation = try install(coordinator.receiveItemsPage(
            threadID: threadID,
            turnID: "turn-2",
            requestID: turn2OlderRequest.requestID,
            data: [
                item(turn: "turn-2", item: "item-2b", marker: "overlap"),
                item(turn: "turn-2", item: "item-2a"),
            ],
            backwardsCursor: "item-head",
            nextCursor: nil
        ))

        XCTAssertEqual(installation.turns.map(\.turnID), ["turn-1", "turn-2", "turn-3"])
        XCTAssertEqual(
            installation.items.map(\.itemID),
            ["item-2a", "item-2b", "item-3a", "item-3b"]
        )
        XCTAssertTrue(installation.bufferedLiveEvents.isEmpty)
        XCTAssertEqual(installation.historyState.turnsCoverage, .full)
        XCTAssertTrue(installation.historyState.turnsPage.isExhausted)
        XCTAssertEqual(
            Set(installation.historyState.itemPagesByTurn.keys),
            ["turn-1", "turn-2", "turn-3"]
        )
        XCTAssertTrue(installation.historyState.itemPagesByTurn.values.allSatisfy(\.isExhausted))
        XCTAssertFalse(installation.crossedConnectionGap)
    }

    func testInitialTurnsPageSeedsRecordsAndContinuesBeforeAtomicInstall() throws {
        let threadID = ThreadID("thread-1")
        let command = reconciliation(threadID: threadID, epoch: 3, operation: 1)
        var coordinator = PaginatedHistoryCoordinator()

        let resume = try resumeRequest(coordinator.beginReconciliation(command))
        let olderTurns = try turnsRequest(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 3, ordinal: 10),
            resumeThread: .dictionary(["id": .string(threadID.rawValue)]),
            initialTurnsPage: .init(
                data: [turn("turn-3"), turn("turn-2")],
                backwardsCursor: "turn-newer",
                nextCursor: "turn-older"
            )
        ))
        XCTAssertEqual(olderTurns.cursor, "turn-older")
        XCTAssertEqual(coordinator.snapshot(for: threadID)?.phase, .paging(
            connectionEpoch: 3,
            resumeGeneration: 1
        ))

        let installation = try install(coordinator.receiveTurnsPage(
            threadID: threadID,
            requestID: olderTurns.requestID,
            data: [turn("turn-1")],
            backwardsCursor: "turn-newer",
            nextCursor: nil
        ))
        XCTAssertEqual(installation.turns.map(\.turnID), ["turn-1", "turn-2", "turn-3"])
        XCTAssertEqual(installation.historyState.turnsPage.backwardsCursor, "turn-newer")
        XCTAssertNil(installation.historyState.turnsPage.nextCursor)
        XCTAssertTrue(installation.historyState.turnsPage.isExhausted)
        XCTAssertEqual(installation.historyState.turnsCoverage, .full)
    }

    func testCursorCycleAndWrongTurnAreTerminalFailures() throws {
        let threadID = ThreadID("thread-1")
        var coordinator = PaginatedHistoryCoordinator()
        let resume = try resumeRequest(coordinator.beginReconciliation(
            reconciliation(threadID: threadID, epoch: 1, operation: 1)
        ))
        let turns = try turnsRequest(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: "turn-head",
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 1, ordinal: 1),
            resumeThread: .dictionary([:])
        ))
        let cursorFailure = try failure(coordinator.receiveTurnsPage(
            threadID: threadID,
            requestID: turns.requestID,
            data: [turn("turn-1")],
            backwardsCursor: "turn-head",
            nextCursor: "turn-head"
        ))
        XCTAssertEqual(cursorFailure.reason, .repeatedCursor(kind: .turns, cursor: "turn-head"))

        var wrongTurnCoordinator = PaginatedHistoryCoordinator()
        let secondResume = try resumeRequest(wrongTurnCoordinator.beginReconciliation(
            reconciliation(threadID: threadID, epoch: 2, operation: 2)
        ))
        let secondTurns = try turnsRequest(wrongTurnCoordinator.receiveResumeCut(
            threadID: threadID,
            requestID: secondResume.requestID,
            turnsBackwardsCursor: "turn-head",
            itemsBackwardsCursor: "item-head",
            responseCursor: .init(connectionEpoch: 2, ordinal: 1),
            resumeThread: .dictionary([:])
        ))
        let itemRequest = try itemsRequest(wrongTurnCoordinator.receiveTurnsPage(
            threadID: threadID,
            requestID: secondTurns.requestID,
            data: [turn("turn-1")],
            backwardsCursor: "turn-head",
            nextCursor: nil
        ))
        let wrongTurnFailure = try failure(wrongTurnCoordinator.receiveItemsPage(
            threadID: threadID,
            turnID: "turn-1",
            requestID: itemRequest.requestID,
            data: [item(turn: "turn-2", item: "item-1")],
            backwardsCursor: "item-head",
            nextCursor: nil
        ))
        XCTAssertEqual(
            wrongTurnFailure.reason,
            .itemReturnedForWrongTurn(expected: "turn-1", actual: "turn-2")
        )
    }

    func testLiveIngressHasNoArtificialHydrationBufferLimit() throws {
        let threadID = ThreadID("thread-1")
        let command = reconciliation(threadID: threadID, epoch: 1, operation: 1)
        var coordinator = PaginatedHistoryCoordinator(policy: .init(maximumBufferedLiveEvents: 2))
        let resume = try resumeRequest(coordinator.beginReconciliation(command))

        XCTAssertTrue(coordinator.requestFailed(
            threadID: threadID,
            requestID: .init(rawValue: resume.requestID.rawValue + 1),
            message: "stale"
        ).isEmpty)
        XCTAssertEqual(
            coordinator.receiveLiveEvent(threadID: threadID, event: liveEvent(epoch: 1, ordinal: 1)),
            .applyImmediately
        )
        XCTAssertEqual(
            coordinator.receiveLiveEvent(threadID: threadID, event: liveEvent(epoch: 1, ordinal: 2)),
            .applyImmediately
        )
        let third = coordinator.receiveLiveEvent(
            threadID: threadID,
            event: liveEvent(epoch: 1, ordinal: 3)
        )
        XCTAssertEqual(third, .applyImmediately)
        XCTAssertFalse(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: resume.requestID,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 1, ordinal: 4),
            resumeThread: .dictionary([:])
        ).isEmpty)
    }

    func testConnectionGapMarksStateStaleAndNextInstallRecordsGap() throws {
        let threadID = ThreadID("thread-1")
        var coordinator = PaginatedHistoryCoordinator()
        let firstResume = try resumeRequest(coordinator.beginReconciliation(
            reconciliation(threadID: threadID, epoch: 5, operation: 1)
        ))
        _ = try install(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: firstResume.requestID,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 5, ordinal: 2),
            resumeThread: .dictionary([:])
        ))

        let stale = coordinator.connectionLost(5)
        XCTAssertEqual(stale.count, 1)
        guard case .markStale(let transition) = try XCTUnwrap(stale.first) else {
            return XCTFail("Expected stale transition")
        }
        XCTAssertEqual(transition.connectionEpoch, 5)
        XCTAssertEqual(transition.previousCut?.connectionEpoch, 5)
        XCTAssertEqual(
            coordinator.receiveLiveEvent(threadID: threadID, event: liveEvent(epoch: 5, ordinal: 3)),
            .ignoredStale
        )

        let nextResume = try resumeRequest(coordinator.beginReconciliation(
            reconciliation(threadID: threadID, epoch: 6, operation: 2)
        ))
        let installation = try install(coordinator.receiveResumeCut(
            threadID: threadID,
            requestID: nextResume.requestID,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            responseCursor: .init(connectionEpoch: 6, ordinal: 1),
            resumeThread: .dictionary([:])
        ))
        XCTAssertTrue(installation.crossedConnectionGap)
        XCTAssertFalse(installation.historyState.isStaleAfterReconnect)
    }

    private func reconciliation(
        threadID: ThreadID,
        epoch: UInt64,
        operation: UInt64
    ) -> ThreadReconciliationCommand {
        .init(
            threadID: threadID,
            connectionEpoch: epoch,
            operationID: .init(rawValue: operation)
        )
    }

    private func turn(_ id: TurnID, marker: String? = nil) -> PaginatedHistoryTurnRecord {
        .init(
            turnID: id,
            value: .dictionary([
                "id": .string(id.rawValue),
                "marker": marker.map(CodexJSONValue.string) ?? .null,
            ])
        )
    }

    private func item(
        turn: TurnID,
        item: ItemID,
        marker: String? = nil
    ) -> PaginatedHistoryItemRecord {
        .init(
            turnID: turn,
            itemID: item,
            value: .dictionary([
                "turnId": .string(turn.rawValue),
                "item": .dictionary([
                    "id": .string(item.rawValue),
                    "marker": marker.map(CodexJSONValue.string) ?? .null,
                ]),
            ])
        )
    }

    private func liveEvent(
        epoch: UInt64,
        ordinal: UInt64,
        method: String = "event"
    ) -> PaginatedHistoryBufferedLiveEvent {
        .init(
            cursor: .init(connectionEpoch: epoch, ordinal: ordinal),
            method: method,
            params: .dictionary(["ordinal": .int(Int(ordinal))])
        )
    }

    private func resumeRequest(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PaginatedHistoryResumeRequest {
        guard effects.count == 1, case .requestResume(let request) = effects[0] else {
            XCTFail("Expected one resume request, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return request
    }

    private func turnsRequest(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PaginatedHistoryTurnsRequest {
        guard effects.count == 1, case .requestTurns(let request) = effects[0] else {
            XCTFail("Expected one turns request, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return request
    }

    private func itemsRequest(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PaginatedHistoryItemsRequest {
        guard effects.count == 1, case .requestItems(let request) = effects[0] else {
            XCTFail("Expected one items request, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return request
    }

    private func itemRequests(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [PaginatedHistoryItemsRequest] {
        let requests = effects.compactMap { effect -> PaginatedHistoryItemsRequest? in
            guard case .requestItems(let request) = effect else { return nil }
            return request
        }
        guard requests.count == effects.count else {
            XCTFail("Expected only item requests, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return requests
    }

    private func install(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PaginatedHistoryInstallation {
        guard effects.count == 1, case .install(let installation) = effects[0] else {
            XCTFail("Expected one installation, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return installation
    }

    private func failure(
        _ effects: [PaginatedHistoryEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PaginatedHistoryFailure {
        guard effects.count == 1, case .failed(let failure) = effects[0] else {
            XCTFail("Expected one failure, got \(effects)", file: file, line: line)
            throw TestFailure.unexpectedEffect
        }
        return failure
    }
}

private enum TestFailure: Error {
    case unexpectedEffect
}
