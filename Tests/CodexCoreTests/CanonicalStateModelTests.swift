import XCTest
@testable import CodexCore

final class CanonicalStateModelTests: XCTestCase {
    func testCompositeKeysKeepIdenticalProtocolIDsIsolatedByThread() {
        let first = ItemKey(threadID: "thread-a", turnID: "turn-1", itemID: "item-1")
        let second = ItemKey(threadID: "thread-b", turnID: "turn-1", itemID: "item-1")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.turnKey, second.turnKey)

        let items = [
            first: CanonicalItem(key: first, kind: .agentMessage),
            second: CanonicalItem(key: second, kind: .agentMessage),
        ]
        XCTAssertEqual(items.count, 2)
    }

    func testCoverageMergeNeverDowngradesRicherState() {
        XCTAssertEqual(StateCoverage.full.merged(with: .notLoaded), .full)
        XCTAssertEqual(StateCoverage.summary.merged(with: .full), .full)
        XCTAssertEqual(StateCoverage.notLoaded.merged(with: .summary), .summary)
    }

    func testOpenProtocolEnumsPreserveUnknownValues() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let itemKind = try decoder.decode(ThreadItemKind.self, from: Data(#""futureItem""#.utf8))
        let turnStatus = try decoder.decode(CanonicalTurnStatus.self, from: Data(#""pausing""#.utf8))
        let activeFlag = try decoder.decode(ThreadActiveFlag.self, from: Data(#""waitingOnNetwork""#.utf8))

        XCTAssertEqual(itemKind, .unknown("futureItem"))
        XCTAssertEqual(turnStatus, .unknown("pausing"))
        XCTAssertEqual(activeFlag, .unknown("waitingOnNetwork"))
        XCTAssertEqual(try encoder.encode(itemKind), Data(#""futureItem""#.utf8))
    }

    func testTypedOverlayRetainsIdenticalConsecutiveDeltasAndIndexesReasoning() {
        var overlay = ItemLiveOverlay()
        overlay.append(.agentMessage("same"))
        overlay.append(.agentMessage("same"))
        overlay.append(.reasoningSummary(index: 1, delta: "summary-b"))
        overlay.append(.reasoningSummary(index: 0, delta: "summary-a"))
        overlay.append(.reasoningContent(index: 0, delta: "detail"))

        XCTAssertEqual(overlay.agentMessage.chunks, ["same", "same"])
        XCTAssertEqual(overlay.agentMessage.joined(), "samesame")
        XCTAssertEqual(overlay.agentMessage.utf8ByteCount, 8)
        XCTAssertEqual(overlay.reasoningSummary[0]?.joined(), "summary-a")
        XCTAssertEqual(overlay.reasoningSummary[1]?.joined(), "summary-b")
        XCTAssertEqual(overlay.reasoningContent[0]?.joined(), "detail")
    }

    func testSnapshotQueriesUseCanonicalOrderAndDeduplicateIDs() {
        let threadID: ThreadID = "thread-1"
        let firstTurn = TurnKey(threadID: threadID, turnID: "turn-1")
        let secondTurn = TurnKey(threadID: threadID, turnID: "turn-2")
        let item = ItemKey(threadID: threadID, turnID: firstTurn.turnID, itemID: "item-1")

        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(4),
            threadOrder: [threadID, threadID],
            threads: [
                threadID: CanonicalThread(
                    id: threadID,
                    turnOrder: [secondTurn.turnID, firstTurn.turnID, firstTurn.turnID]
                )
            ],
            turns: [
                firstTurn: CanonicalTurn(key: firstTurn, itemOrder: [item.itemID, item.itemID]),
                secondTurn: CanonicalTurn(key: secondTurn),
            ],
            items: [item: CanonicalItem(key: item, kind: .userMessage)]
        )

        XCTAssertEqual(snapshot.threadOrder, [threadID])
        XCTAssertEqual(snapshot.turns(in: threadID).map(\.key), [secondTurn, firstTurn])
        XCTAssertEqual(snapshot.items(in: firstTurn).map(\.key), [item])
    }

    func testLifecycleTypesAndAuthorityRemainDistinct() {
        let key = ItemKey(threadID: "thread", turnID: "turn", itemID: "item")
        let item = CanonicalItem(
            key: key,
            kind: .commandExecution,
            authority: .completed,
            startedAt: ProtocolMilliseconds(1_700_000_000_001),
            completedAt: ProtocolMilliseconds(1_700_000_000_250),
            consistency: .authoritative,
            lastChangedRevision: StateRevision(9)
        )
        let turn = CanonicalTurn(
            key: key.turnKey,
            status: .completed,
            startedAt: ProtocolSeconds(1_700_000_000),
            completedAt: ProtocolSeconds(1_700_000_001),
            duration: DurationMilliseconds(250),
            itemsCoverage: .full,
            itemsConsistency: .authoritative
        )

        XCTAssertTrue(item.authority > .started)
        XCTAssertEqual(item.completedAt?.rawValue, 1_700_000_000_250)
        XCTAssertEqual(turn.completedAt?.rawValue, 1_700_000_001)
        XCTAssertEqual(turn.duration?.rawValue, 250)
        XCTAssertTrue(turn.status.isTerminal)
    }

    func testSubmissionIntentSeparatesLocalIntentFromServerFacts() {
        let itemKey = ItemKey(threadID: "thread", turnID: "turn", itemID: "message")
        let intent = SubmissionIntent(
            id: "client-message",
            threadID: itemKey.threadID,
            expectedTurnID: itemKey.turnID,
            input: [.dictionary(["type": .string("text"), "text": .string("hello")])],
            localOrdinal: 7,
            state: .reconciled(item: itemKey),
            lastChangedRevision: StateRevision(12)
        )

        XCTAssertEqual(intent.state, .reconciled(item: itemKey))
        XCTAssertEqual(intent.id.rawValue, "client-message")
        XCTAssertEqual(intent.lastChangedRevision, StateRevision(12))
    }

    func testUncertainResumedTurnExplicitlyRequiresResync() {
        let turn = CanonicalTurn(
            key: TurnKey(threadID: "thread", turnID: "active-turn"),
            status: .inProgress,
            itemsCoverage: .summary,
            itemsConsistency: .uncertain
        )

        XCTAssertTrue(turn.itemsConsistency.requiresResync)
        XCTAssertFalse(StateConsistency.authoritative.requiresResync)
    }

    func testGlobalSnapshotRetainsDistinctGlobalAndThreadMCPStartupStatuses() {
        let global = CanonicalMCPServerStartupKey(serverName: "filesystem")
        let scoped = CanonicalMCPServerStartupKey(
            threadID: "thread-1",
            serverName: "filesystem"
        )
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(3),
            mcpServerStartupStatuses: [
                global: .init(status: .ready, lastChangedRevision: StateRevision(1)),
                scoped: .init(
                    status: .failed,
                    error: "Sign in",
                    failureReason: .reauthenticationRequired,
                    lastChangedRevision: StateRevision(3)
                ),
            ]
        )

        let globalSnapshot = snapshot.scoped(to: .global(fields: .mcpServerStartup))

        XCTAssertEqual(globalSnapshot.mcpServerStartupStatuses.count, 2)
        XCTAssertEqual(globalSnapshot.mcpServerStartupStatuses[global]?.status, .ready)
        XCTAssertEqual(globalSnapshot.mcpServerStartupStatuses[scoped]?.status, .failed)
        XCTAssertNotEqual(global, scoped)
    }

    func testCanonicalTurnErrorExposesTypedCodexInfoWithoutDroppingRawValue() {
        let raw = CodexJSONValue.dictionary([
            "type": .string("responseStreamConnectionFailed"),
            "httpStatusCode": .int(503),
            "future": .string("retained"),
        ])
        let error = CanonicalTurnError(
            message: "stream failed",
            codexErrorInfo: raw
        )

        guard case .responseStreamConnectionFailed(let statusCode) = error.typedCodexErrorInfo else {
            return XCTFail("Expected typed response-stream error")
        }
        XCTAssertEqual(statusCode, 503)
        XCTAssertEqual(error.httpStatusCode, 503)
        XCTAssertEqual(error.codexErrorInfo, raw)

        let unknown = CanonicalTurnError(
            message: "future",
            codexErrorInfo: .dictionary(["type": .string("futureError")])
        )
        guard case .unknown(let type, _) = unknown.typedCodexErrorInfo else {
            return XCTFail("Unknown error variants must remain representable")
        }
        XCTAssertEqual(type, "futureError")
    }
}
