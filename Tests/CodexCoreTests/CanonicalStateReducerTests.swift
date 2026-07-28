import XCTest
@testable import CodexCore

final class CanonicalStateReducerTests: XCTestCase {
    func testHistoryPageCannotRegressLiveTerminalTurnOrCompletedItem() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let turnKey = TurnKey(threadID: "thread", turnID: "turn")
        let key = ItemKey(threadID: turnKey.threadID, turnID: turnKey.turnID, itemID: "item")

        _ = reducer.apply(.turnCompleted(
            CanonicalTurn(
                key: turnKey,
                status: .completed,
                itemOrder: [key.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative,
                diff: "live diff"
            ),
            items: [item(
                key,
                payload: ["text": .string("live final")],
                authority: .completed,
                consistency: .authoritative
            )],
            itemPolicy: .authoritativeReplacement
        ), to: &graph)

        _ = reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: turnKey,
                status: .inProgress,
                itemOrder: [key.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative,
                diff: "stale history diff"
            ),
            items: [item(
                key,
                payload: ["text": .string("stale history final")],
                authority: .completed,
                consistency: .authoritative
            )],
            itemPolicy: .historyPage
        ), to: &graph)

        XCTAssertEqual(graph.turns[turnKey]?.status, .completed)
        XCTAssertEqual(graph.turns[turnKey]?.diff, "live diff")
        XCTAssertEqual(graph.items[key]?.payload["text"], .string("live final"))
    }

    func testHistoryPageCompletionCanUpgradeLiveStartedItem() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()
        _ = reducer.apply(.itemStarted(item(
            key,
            payload: ["text": .string("draft")]
        )), to: &graph)

        _ = reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: key.turnKey,
                status: .completed,
                itemOrder: [key.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative
            ),
            items: [item(
                key,
                payload: ["text": .string("durable final")],
                authority: .completed,
                consistency: .authoritative
            )],
            itemPolicy: .historyPage
        ), to: &graph)

        XCTAssertEqual(graph.items[key]?.authority, .completed)
        XCTAssertEqual(graph.items[key]?.payload["text"], .string("durable final"))
    }

    func testFullThreadSnapshotClearsNullableMetadataWithoutErasingLoadedHistory() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let id: ThreadID = "thread"
        let turnID: TurnID = "loaded-turn"
        _ = reducer.apply(.threadSnapshotReplaced(CanonicalThread(
            id: id,
            metadata: .init(gitInfo: .string("git"), name: "old name", parentThreadID: "parent"),
            status: .active(flags: []),
            turnOrder: [turnID],
            history: .init(turnsCoverage: .full),
            isLoaded: true,
            consistency: .authoritative
        )), to: &graph)

        _ = reducer.apply(.threadSnapshotReplaced(CanonicalThread(
            id: id,
            metadata: .init(),
            status: .idle,
            turnOrder: [],
            history: .init(turnsCoverage: .notLoaded),
            consistency: .authoritative
        )), to: &graph)

        let thread = try XCTUnwrap(graph.threads[id])
        XCTAssertNil(thread.metadata.name)
        XCTAssertNil(thread.metadata.parentThreadID)
        XCTAssertNil(thread.metadata.gitInfo)
        XCTAssertEqual(thread.status, .idle)
        XCTAssertEqual(thread.turnOrder, [turnID])
        XCTAssertEqual(thread.history.turnsCoverage, .full)
        XCTAssertTrue(thread.isLoaded)
    }

    func testRollbackIsTheOnlyAuthoritativeTurnAndItemRemovalPath() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let threadID: ThreadID = "thread"
        let firstTurnKey = TurnKey(threadID: threadID, turnID: "turn-1")
        let secondTurnKey = TurnKey(threadID: threadID, turnID: "turn-2")
        let retainedItem = itemKey(turn: "turn-1", item: "retained")
        let removedFromRetainedTurn = itemKey(turn: "turn-1", item: "removed-sibling")
        let removedWithTurn = itemKey(turn: "turn-2", item: "removed-turn-item")

        _ = reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: firstTurnKey,
                status: .completed,
                itemOrder: [retainedItem.itemID, removedFromRetainedTurn.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative
            ),
            items: [
                item(retainedItem, authority: .completed, consistency: .authoritative),
                item(removedFromRetainedTurn, authority: .completed, consistency: .authoritative),
            ],
            itemPolicy: .authoritativeReplacement
        ), to: &graph)
        _ = reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: secondTurnKey,
                status: .completed,
                itemOrder: [removedWithTurn.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative
            ),
            items: [item(removedWithTurn, authority: .completed, consistency: .authoritative)],
            itemPolicy: .authoritativeReplacement
        ), to: &graph)

        let rollbackTurn = CanonicalTurn(
            key: firstTurnKey,
            status: .completed,
            itemOrder: [retainedItem.itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative
        )
        _ = reducer.apply(.threadRollbackReplaced(
            thread: CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [firstTurnKey.turnID],
                consistency: .authoritative
            ),
            turns: [rollbackTurn],
            items: [item(retainedItem, authority: .completed, consistency: .authoritative)]
        ), to: &graph)

        XCTAssertEqual(graph.threads[threadID]?.turnOrder, [firstTurnKey.turnID])
        XCTAssertNotNil(graph.turns[firstTurnKey])
        XCTAssertNil(graph.turns[secondTurnKey])
        XCTAssertNotNil(graph.items[retainedItem])
        XCTAssertNil(graph.items[removedFromRetainedTurn])
        XCTAssertNil(graph.items[removedWithTurn])
    }

    func testCompositeItemKeysPreventCrossThreadLeakage() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let first = itemKey(thread: "thread-a", turn: "turn", item: "shared-item")
        let second = itemKey(thread: "thread-b", turn: "turn", item: "shared-item")

        XCTAssertNotNil(reducer.apply(.itemStarted(item(first)), to: &graph))
        XCTAssertNotNil(reducer.apply(.itemStarted(item(second)), to: &graph))
        XCTAssertNotNil(reducer.apply(.itemDelta(key: first, delta: .agentMessage("A")), to: &graph))
        XCTAssertNotNil(reducer.apply(.itemDelta(key: second, delta: .agentMessage("B")), to: &graph))

        XCTAssertEqual(graph.items[first]?.liveOverlay.agentMessage.joined(), "A")
        XCTAssertEqual(graph.items[second]?.liveOverlay.agentMessage.joined(), "B")
        XCTAssertEqual(graph.items.count, 2)
    }

    func testIdenticalConsecutiveDeltasAreNeverContentDeduplicated() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()
        _ = reducer.apply(.itemStarted(item(key)), to: &graph)

        let first = try XCTUnwrap(
            reducer.apply(.itemDelta(key: key, delta: .agentMessage("same")), to: &graph)
        )
        let second = try XCTUnwrap(
            reducer.apply(.itemDelta(key: key, delta: .agentMessage("same")), to: &graph)
        )

        XCTAssertEqual(first.revision.rawValue + 1, second.revision.rawValue)
        XCTAssertEqual(graph.items[key]?.liveOverlay.agentMessage.chunks, ["same", "same"])
        XCTAssertEqual(graph.items[key]?.liveOverlay.agentMessage.joined(), "samesame")
    }

    func testItemOnlyDeltaBumpsItsAggregateTurnRevisionWithoutTouchingOtherTurns() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let changedKey = itemKey(turn: "changed", item: "changed-item")
        let untouchedKey = itemKey(turn: "untouched", item: "untouched-item")
        _ = reducer.apply(.itemStarted(item(changedKey)), to: &graph)
        _ = reducer.apply(.itemStarted(item(untouchedKey)), to: &graph)
        let untouchedRevision = try XCTUnwrap(graph.turns[untouchedKey.turnKey]).lastChangedRevision

        let batch = try XCTUnwrap(reducer.apply(
            .itemDelta(key: changedKey, delta: .agentMessage("delta")),
            to: &graph
        ))

        XCTAssertEqual(graph.turns[changedKey.turnKey]?.lastChangedRevision, batch.revision)
        XCTAssertEqual(graph.turns[untouchedKey.turnKey]?.lastChangedRevision, untouchedRevision)
    }

    func testSubmissionIntentChangesBumpExpectedTurnAggregateRevision() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = TurnKey(threadID: "thread", turnID: "turn")
        _ = reducer.apply(.turnStarted(CanonicalTurn(key: key), items: []), to: &graph)
        let intent = SubmissionIntent(
            id: "intent",
            threadID: key.threadID,
            expectedTurnID: key.turnID,
            input: [.string("hello")],
            localOrdinal: 1
        )

        let inserted = try XCTUnwrap(reducer.apply(.submissionIntentRegistered(intent), to: &graph))
        XCTAssertEqual(graph.turns[key]?.lastChangedRevision, inserted.revision)

        let failed = try XCTUnwrap(reducer.apply(
            .submissionIntentFailed(id: intent.id, message: "failed"),
            to: &graph
        ))
        XCTAssertEqual(graph.turns[key]?.lastChangedRevision, failed.revision)
    }

    func testRepeatedTerminalInteractionsRemainLossless() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()
        _ = reducer.apply(.itemStarted(item(key, kind: .commandExecution)), to: &graph)

        let interaction = ItemDelta.terminalInteraction(processID: "process", stdin: "yes\n")
        _ = reducer.apply(.itemDelta(key: key, delta: interaction), to: &graph)
        _ = reducer.apply(.itemDelta(key: key, delta: interaction), to: &graph)

        XCTAssertEqual(graph.items[key]?.liveOverlay.terminalInteractions, [
            .init(processID: "process", stdin: "yes\n"),
            .init(processID: "process", stdin: "yes\n"),
        ])
    }

    func testCompletionReplacesSpeculativeOverlayAndCannotBeRegressed() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()
        _ = reducer.apply(
            .itemStarted(item(key, payload: ["text": .string("draft")], startedAt: 100)),
            to: &graph
        )
        _ = reducer.apply(.itemDelta(key: key, delta: .agentMessage("streamed")), to: &graph)

        var completed = item(
            key,
            payload: ["text": .string("server final")],
            authority: .completed,
            completedAt: 200,
            consistency: .authoritative
        )
        completed.liveOverlay.agentMessage.append("must be discarded")
        let completion = try XCTUnwrap(reducer.apply(.itemCompleted(completed), to: &graph))

        let finalItem = try XCTUnwrap(graph.items[key])
        XCTAssertEqual(finalItem.authority, .completed)
        XCTAssertEqual(finalItem.payload["text"], .string("server final"))
        XCTAssertEqual(finalItem.startedAt, ProtocolMilliseconds(100))
        XCTAssertEqual(finalItem.completedAt, ProtocolMilliseconds(200))
        XCTAssertTrue(finalItem.liveOverlay.isEmpty)

        let staleStart = item(key, payload: ["text": .string("stale start")], startedAt: 100)
        XCTAssertNil(reducer.apply(.itemStarted(staleStart), to: &graph))
        XCTAssertNil(reducer.apply(.itemDelta(key: key, delta: .agentMessage("late")), to: &graph))
        XCTAssertEqual(graph.revision, completion.revision)
        XCTAssertEqual(graph.items[key]?.payload["text"], .string("server final"))
    }

    func testCompletionWithoutStartIsAuthoritativeAndDiscardsOrphans() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()

        _ = reducer.apply(.itemDelta(key: key, delta: .agentMessage("untrusted prefix")), to: &graph)
        XCTAssertNil(graph.items[key])
        XCTAssertEqual(reducer.bufferedOrphanDeltaCount, 1)

        _ = reducer.apply(
            .itemCompleted(item(
                key,
                payload: ["text": .string("authoritative")],
                authority: .completed,
                completedAt: 500,
                consistency: .authoritative
            )),
            to: &graph
        )

        XCTAssertEqual(graph.items[key]?.payload["text"], .string("authoritative"))
        XCTAssertTrue(try XCTUnwrap(graph.items[key]).liveOverlay.isEmpty)
        XCTAssertEqual(reducer.bufferedOrphanDeltaCount, 0)
    }

    func testPartialTerminalHistoryDoesNotEraseRicherLiveContent() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey()
        let turnKey = key.turnKey
        _ = reducer.apply(.itemStarted(item(
            key,
            payload: ["text": .string("")],
            consistency: .partial
        )), to: &graph)
        _ = reducer.apply(.itemDelta(key: key, delta: .agentMessage("rich live text")), to: &graph)

        _ = reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: turnKey,
                status: .completed,
                itemOrder: [key.itemID],
                itemsCoverage: .summary,
                itemsConsistency: .partial
            ),
            items: [item(
                key,
                payload: ["status": .string("completed")],
                authority: .completed,
                consistency: .partial
            )],
            itemPolicy: .mergePreservingExistingOrder
        ), to: &graph)

        let partial = try XCTUnwrap(graph.items[key])
        XCTAssertEqual(partial.authority, .completed)
        XCTAssertEqual(partial.consistency, .partial)
        XCTAssertEqual(partial.liveOverlay.agentMessage.joined(), "rich live text")
        XCTAssertEqual(partial.payload["status"], .string("completed"))
    }

    func testNonArrayLiveFileChangesCannotMaskPartialPayloadRevision() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = itemKey(item: "patch")
        let oldChanges: CodexJSONValue = .array([.dictionary([
            "path": .string("Sources/App.swift"),
            "kind": .dictionary(["type": .string("update")]),
            "diff": .string("@@ -1 +1 @@\n-old\n+new"),
        ])])
        let newChanges: CodexJSONValue = .array([.dictionary([
            "path": .string("Sources/App.swift"),
            "kind": .dictionary(["type": .string("update")]),
            "diff": .string("@@ -1 +1 @@\n-old\n+newer"),
        ])])

        _ = reducer.apply(.itemStarted(item(
            key,
            kind: .fileChange,
            payload: ["changes": oldChanges]
        )), to: &graph)
        _ = reducer.apply(.itemLiveFieldReplaced(
            item: key,
            key: "fileChanges",
            value: .dictionary(["malformed": .bool(true)])
        ), to: &graph)
        let priorContentRevision = try XCTUnwrap(
            graph.items[key]?.fileChangeContentRevision
        )

        let completion = try XCTUnwrap(reducer.apply(.turnSnapshot(
            CanonicalTurn(
                key: key.turnKey,
                status: .completed,
                itemOrder: [key.itemID],
                itemsCoverage: .summary,
                itemsConsistency: .partial
            ),
            items: [item(
                key,
                kind: .fileChange,
                payload: [
                    "status": .string("completed"),
                    "changes": newChanges,
                ],
                authority: .completed,
                consistency: .partial
            )],
            itemPolicy: .mergePreservingExistingOrder
        ), to: &graph))

        let completed = try XCTUnwrap(graph.items[key])
        XCTAssertEqual(completed.payload["changes"], newChanges)
        XCTAssertGreaterThan(completed.fileChangeContentRevision, priorContentRevision)
        XCTAssertEqual(completed.fileChangeContentRevision, completion.revision)
    }

    func testCoverageNeverRegressesAndPartialEmptySnapshotDoesNotEraseItems() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let turnKey = TurnKey(threadID: "thread", turnID: "turn")
        let key = itemKey()
        let fullTurn = CanonicalTurn(
            key: turnKey,
            status: .completed,
            itemOrder: [key.itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative
        )
        _ = reducer.apply(
            .turnSnapshot(
                fullTurn,
                items: [item(key, authority: .completed, consistency: .authoritative)],
                itemPolicy: .authoritativeReplacement
            ),
            to: &graph
        )

        let sparseTurn = CanonicalTurn(
            key: turnKey,
            status: .inProgress,
            itemsCoverage: .notLoaded,
            itemsConsistency: .partial
        )
        _ = reducer.apply(
            .turnSnapshot(sparseTurn, items: [], itemPolicy: .mergePreservingExistingOrder),
            to: &graph
        )

        XCTAssertEqual(graph.turns[turnKey]?.itemsCoverage, .full)
        XCTAssertEqual(graph.turns[turnKey]?.status, .completed)
        XCTAssertEqual(graph.turns[turnKey]?.itemOrder, [key.itemID])
        XCTAssertNotNil(graph.items[key])
    }

    func testFullAuthoritativeReplacementRemovesAbsentItemsAndClearsUncertainty() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let turnKey = TurnKey(threadID: "thread", turnID: "turn")
        let first = itemKey(item: "first")
        let second = itemKey(item: "second")
        let initial = CanonicalTurn(
            key: turnKey,
            status: .inProgress,
            itemOrder: [first.itemID, second.itemID],
            itemsCoverage: .summary,
            itemsConsistency: .uncertain
        )
        _ = reducer.apply(
            .turnSnapshot(
                initial,
                items: [item(first), item(second)],
                itemPolicy: .mergePreservingExistingOrder
            ),
            to: &graph
        )

        let final = CanonicalTurn(
            key: turnKey,
            status: .completed,
            itemOrder: [second.itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative
        )
        _ = reducer.apply(
            .turnCompleted(
                final,
                items: [item(second, authority: .completed, consistency: .authoritative)],
                itemPolicy: .authoritativeReplacement
            ),
            to: &graph
        )

        XCTAssertNil(graph.items[first])
        XCTAssertNotNil(graph.items[second])
        XCTAssertEqual(graph.turns[turnKey]?.itemOrder, [second.itemID])
        XCTAssertEqual(graph.turns[turnKey]?.itemsCoverage, .full)
        XCTAssertEqual(graph.turns[turnKey]?.itemsConsistency, .authoritative)
    }

    func testErrorNotificationNeverTerminatesAndTerminalStatusNeverRegresses() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = TurnKey(threadID: "thread", turnID: "turn")
        _ = reducer.apply(.turnStarted(CanonicalTurn(key: key), items: []), to: &graph)

        let retryable = CanonicalTurnError(message: "temporary")
        _ = reducer.apply(.turnErrorReported(turn: key, error: retryable, willRetry: true), to: &graph)
        XCTAssertEqual(graph.turns[key]?.status, .inProgress)
        XCTAssertEqual(graph.turns[key]?.error, retryable)
        XCTAssertEqual(graph.turns[key]?.extensions["lastErrorWillRetry"], .bool(true))

        let failed = CanonicalTurnError(message: "terminal")
        _ = reducer.apply(
            .turnCompleted(
                CanonicalTurn(key: key, status: .failed, error: failed),
                items: [],
                itemPolicy: .mergePreservingExistingOrder
            ),
            to: &graph
        )
        _ = reducer.apply(
            .turnSnapshot(
                CanonicalTurn(key: key, status: .inProgress),
                items: [],
                itemPolicy: .mergePreservingExistingOrder
            ),
            to: &graph
        )

        XCTAssertEqual(graph.turns[key]?.status, .failed)
        XCTAssertEqual(graph.turns[key]?.error, failed)
    }

    func testPlanAndDiffNotificationsReplaceRatherThanAppend() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = TurnKey(threadID: "thread", turnID: "turn")
        let oldPlan = [CanonicalPlanStep(step: "old", status: .inProgress)]
        let newPlan = [CanonicalPlanStep(step: "new", status: .completed)]

        _ = reducer.apply(.planReplaced(turn: key, steps: oldPlan, explanation: "old explanation"), to: &graph)
        _ = reducer.apply(.planReplaced(turn: key, steps: newPlan, explanation: nil), to: &graph)
        _ = reducer.apply(.diffReplaced(turn: key, diff: "old diff"), to: &graph)
        _ = reducer.apply(.diffReplaced(turn: key, diff: "new diff"), to: &graph)

        XCTAssertEqual(graph.turns[key]?.plan, newPlan)
        XCTAssertNil(graph.turns[key]?.planExplanation)
        XCTAssertEqual(graph.turns[key]?.diff, "new diff")
    }

    func testOrphanBufferIsBoundedAndReplaysRetainedDeltasInOrder() throws {
        var reducer = CanonicalStateReducer(configuration: .init(
            maximumOrphanDeltaCount: 2,
            maximumOrphanUTF8Bytes: 100,
            maximumOrphanDeltasPerItem: 2
        ))
        var graph = CanonicalStateGraph()
        let key = itemKey()

        _ = reducer.apply(.itemDelta(key: key, delta: .agentMessage("one")), to: &graph)
        _ = reducer.apply(.itemDelta(key: key, delta: .agentMessage("two")), to: &graph)
        let overflow = try XCTUnwrap(
            reducer.apply(.itemDelta(key: key, delta: .agentMessage("three")), to: &graph)
        )

        XCTAssertTrue(overflow.changes.contains(.orphanDeltaDropped(key)))
        XCTAssertEqual(reducer.bufferedOrphanDeltaCount, 2)
        XCTAssertNil(graph.items[key])

        _ = reducer.apply(.itemStarted(item(key)), to: &graph)
        XCTAssertEqual(graph.items[key]?.liveOverlay.agentMessage.chunks, ["two", "three"])
        XCTAssertEqual(reducer.bufferedOrphanDeltaCount, 0)
        XCTAssertEqual(reducer.bufferedOrphanUTF8ByteCount, 0)
    }

    func testUserMessageEchoReconcilesIntentByClientIdentifier() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let intentID: SubmissionIntentID = "client-message"
        let intent = SubmissionIntent(
            id: intentID,
            threadID: "thread",
            input: [.dictionary(["type": .string("text"), "text": .string("hello")])],
            localOrdinal: 1
        )
        _ = reducer.apply(.submissionIntentRegistered(intent), to: &graph)

        let key = itemKey()
        _ = reducer.apply(
            .itemStarted(item(key, kind: .userMessage, clientUserMessageID: intentID)),
            to: &graph
        )

        XCTAssertEqual(graph.submissionIntents[intentID]?.state, .reconciled(item: key))
    }

    func testFailedSteerIntentCanBeRearmedForExactRecoveryPayload() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let intentID: SubmissionIntentID = "steer-client"
        let input: [CodexJSONValue] = [
            .dictionary(["type": .string("text"), "text": .string("redirect")]),
        ]
        let stale = SubmissionIntent(
            id: intentID,
            threadID: "thread",
            expectedTurnID: "turn-old",
            input: input,
            localOrdinal: 1
        )
        _ = reducer.apply(.submissionIntentRegistered(stale), to: &graph)
        _ = reducer.apply(.submissionIntentFailed(id: intentID, message: "turn changed"), to: &graph)

        let retry = SubmissionIntent(
            id: intentID,
            threadID: "thread",
            expectedTurnID: "turn-current",
            input: input,
            localOrdinal: 2
        )
        _ = reducer.apply(.submissionIntentRegistered(retry), to: &graph)

        XCTAssertEqual(graph.submissionIntents[intentID]?.state, .pending)
        XCTAssertEqual(graph.submissionIntents[intentID]?.expectedTurnID, "turn-current")
        XCTAssertEqual(graph.submissionIntents[intentID]?.localOrdinal, 2)
    }

    func testProtocolAdaptationMutationsCommitAtOneSharedRevision() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let threadID: ThreadID = "thread"
        let turnKey = TurnKey(threadID: threadID, turnID: "turn")
        let key = ItemKey(threadID: threadID, turnID: turnKey.turnID, itemID: "item")

        let batch = try XCTUnwrap(reducer.apply([
            .threadSnapshotReplaced(CanonicalThread(
                id: threadID,
                metadata: .init(name: "atomic"),
                status: .active(flags: []),
                turnOrder: [turnKey.turnID],
                consistency: .authoritative
            )),
            .turnSnapshot(
                CanonicalTurn(
                    key: turnKey,
                    status: .inProgress,
                    itemOrder: [key.itemID],
                    itemsCoverage: .summary
                ),
                items: [item(key)],
                itemPolicy: .mergePreservingExistingOrder
            ),
            .itemDelta(key: key, delta: .agentMessage("same")),
            .itemDelta(key: key, delta: .agentMessage("same")),
        ], to: &graph))

        XCTAssertEqual(batch.baseRevision, .zero)
        XCTAssertEqual(batch.revision, StateRevision(1))
        XCTAssertEqual(graph.revision, batch.revision)
        XCTAssertEqual(graph.threads[threadID]?.lastChangedRevision, batch.revision)
        XCTAssertEqual(graph.turns[turnKey]?.lastChangedRevision, batch.revision)
        XCTAssertEqual(graph.items[key]?.lastChangedRevision, batch.revision)
        XCTAssertEqual(graph.items[key]?.liveOverlay.agentMessage.chunks, ["same", "same"])
        XCTAssertEqual(batch.changes.filter { $0 == .itemDeltaAppended(key) }.count, 1)
    }

    func testMultiMutationNoOpsAndRejectionsDoNotCreatePartialState() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let rejectedTurn = TurnKey(threadID: "rejected", turnID: "turn")

        XCTAssertNil(reducer.apply([
            .turnCompleted(
                CanonicalTurn(key: rejectedTurn, status: .inProgress),
                items: [],
                itemPolicy: .mergePreservingExistingOrder
            ),
            .threadNameReplaced(id: "accepted", name: "name"),
        ], to: &graph))

        XCTAssertEqual(graph.revision, .zero)
        XCTAssertTrue(graph.threads.isEmpty)
        XCTAssertTrue(graph.turns.isEmpty)

        let batch = try XCTUnwrap(reducer.apply([
            .threadNameReplaced(id: "accepted", name: "name"),
            .threadNameReplaced(id: "accepted", name: "name"),
        ], to: &graph))

        XCTAssertNil(graph.threads[rejectedTurn.threadID])
        XCTAssertNil(graph.turns[rejectedTurn])
        XCTAssertEqual(graph.threads["accepted"]?.metadata.name, "name")
        XCTAssertEqual(graph.threads["accepted"]?.lastChangedRevision, batch.revision)
        XCTAssertEqual(batch.changes.filter { $0 == .threadNameReplaced("accepted") }.count, 1)

        let revision = graph.revision
        XCTAssertNil(reducer.apply([
            .threadNameReplaced(id: "accepted", name: "name"),
        ], to: &graph))
        XCTAssertEqual(graph.revision, revision)
    }

    func testSparseSettingsPatchRetainsAbsentKeysAndExplicitNull() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let threadID: ThreadID = "thread"

        _ = reducer.apply(.threadSettingsReplaced(id: threadID, settings: [
            "model": .string("gpt-5.6"),
            "sandbox": .dictionary(["type": .string("workspaceWrite")]),
        ]), to: &graph)
        let batch = try XCTUnwrap(reducer.apply(.threadSettingsPatched(id: threadID, patch: [
            "model": .null,
            "memoryMode": .string("enabled"),
        ]), to: &graph))

        let settings = try XCTUnwrap(graph.threads[threadID]?.settings)
        XCTAssertEqual(settings["model"], .null)
        XCTAssertEqual(settings["memoryMode"], .string("enabled"))
        XCTAssertEqual(settings["sandbox"], .dictionary(["type": .string("workspaceWrite")]))
        XCTAssertTrue(batch.changes.contains(.threadSettingsReplaced(threadID)))
    }

    func testThreadDetailEvictionIsAtomicAndRetainsLightweightIndexSummary() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let threadID: ThreadID = "thread"
        let otherThreadID: ThreadID = "other"
        let turnKey = TurnKey(threadID: threadID, turnID: "latest-turn")
        let key = ItemKey(threadID: threadID, turnID: turnKey.turnID, itemID: "large-item")
        let otherTurn = TurnKey(threadID: otherThreadID, turnID: "other-turn")

        _ = reducer.apply(.threadSnapshotReplaced(CanonicalThread(
            id: threadID,
            metadata: .init(name: "Keep me", preview: "summary"),
            status: .idle,
            turnOrder: [turnKey.turnID],
            history: .init(
                mode: .paginated,
                turnsCoverage: .full,
                resumeCut: .init(
                    connectionEpoch: 1,
                    resumeGeneration: 1,
                    turnsBackwardsCursor: "turn-cursor",
                    itemsBackwardsCursor: "item-cursor"
                ),
                turnsPage: .init(backwardsCursor: "turn-cursor", isExhausted: true),
                itemPagesByTurn: [
                    turnKey.turnID: .init(backwardsCursor: "item-cursor", isExhausted: true)
                ],
                protocolMetadata: ["historyMode": .string("paginated")]
            ),
            isArchived: false,
            isLoaded: true,
            consistency: .authoritative
        )), to: &graph)
        _ = reducer.apply(.turnCompleted(
            CanonicalTurn(
                key: turnKey,
                status: .failed,
                itemOrder: [key.itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative,
                diff: String(repeating: "x", count: 1_024)
            ),
            items: [item(
                key,
                payload: ["text": .string(String(repeating: "payload", count: 256))],
                authority: .completed,
                consistency: .authoritative
            )],
            itemPolicy: .authoritativeReplacement
        ), to: &graph)
        _ = reducer.apply(.turnStarted(CanonicalTurn(key: otherTurn), items: []), to: &graph)

        let beforeRevision = graph.revision
        let batch = try XCTUnwrap(
            reducer.apply(.threadDetailEvicted(threadID), to: &graph)
        )

        XCTAssertEqual(batch.baseRevision, beforeRevision)
        XCTAssertEqual(batch.revision, beforeRevision.successor)
        XCTAssertTrue(batch.changes.contains(.threadDetailEvicted(threadID)))
        XCTAssertTrue(batch.changes.contains(.turnRemoved(turnKey)))
        XCTAssertTrue(batch.changes.contains(.itemRemoved(key)))

        let retained = try XCTUnwrap(graph.threads[threadID])
        XCTAssertEqual(retained.metadata.name, "Keep me")
        XCTAssertEqual(retained.metadata.preview, "summary")
        XCTAssertEqual(retained.status, .idle)
        XCTAssertEqual(retained.isArchived, false)
        XCTAssertFalse(retained.isLoaded)
        XCTAssertEqual(retained.turnOrder, [])
        XCTAssertEqual(
            retained.retainedLatestTurn,
            .init(id: turnKey.turnID, status: .failed)
        )
        XCTAssertEqual(retained.history.mode, .paginated)
        XCTAssertEqual(retained.history.turnsCoverage, .notLoaded)
        XCTAssertNil(retained.history.resumeCut)
        XCTAssertEqual(retained.history.turnsPage, .init())
        XCTAssertTrue(retained.history.itemPagesByTurn.isEmpty)
        XCTAssertEqual(
            retained.history.protocolMetadata["historyMode"],
            .string("paginated")
        )
        XCTAssertNil(graph.turns[turnKey])
        XCTAssertNil(graph.items[key])
        XCTAssertNotNil(graph.turns[otherTurn])

        let index = graph.threadIndexSnapshot(
            attentionRevisions: [:],
            pendingRequestThreadIDs: []
        )
        XCTAssertEqual(index.summary(for: threadID)?.latestTurnID, turnKey.turnID)
        XCTAssertEqual(index.summary(for: threadID)?.latestTurnStatus, .failed)

        let revisionAfterEviction = graph.revision
        XCTAssertNil(reducer.apply(.threadDetailEvicted(threadID), to: &graph))
        XCTAssertEqual(graph.revision, revisionAfterEviction)
    }

    func testMCPStartupStatusRetainsExactGeneratedFieldsAndDeduplicatesEqualUpdates() throws {
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        let key = CanonicalMCPServerStartupKey(
            threadID: "thread",
            serverName: "filesystem"
        )
        let status = CanonicalMCPServerStartupStatus(
            status: .failed,
            error: "OAuth expired",
            failureReason: .reauthenticationRequired
        )

        let batch = try XCTUnwrap(reducer.apply(
            .mcpServerStartupStatusUpdated(key: key, status: status),
            to: &graph
        ))
        let stored = try XCTUnwrap(graph.mcpServerStartupStatuses[key])

        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.error, "OAuth expired")
        XCTAssertEqual(stored.failureReason, .reauthenticationRequired)
        XCTAssertEqual(stored.lastChangedRevision, batch.revision)
        XCTAssertEqual(batch.changes, [.mcpServerStartupStatusUpdated(key)])

        XCTAssertNil(reducer.apply(
            .mcpServerStartupStatusUpdated(key: key, status: status),
            to: &graph
        ))
        XCTAssertEqual(graph.revision, batch.revision)
    }

    func testMCPStartupStatusRetentionUsesBoundedNotificationRecency() throws {
        var reducer = CanonicalStateReducer(configuration: .init(
            maximumMCPServerStartupStatusCount: 2
        ))
        var graph = CanonicalStateGraph()
        let first = CanonicalMCPServerStartupKey(serverName: "first")
        let second = CanonicalMCPServerStartupKey(serverName: "second")
        let third = CanonicalMCPServerStartupKey(serverName: "third")
        let ready = CanonicalMCPServerStartupStatus(status: .ready)

        _ = reducer.apply(.mcpServerStartupStatusUpdated(key: first, status: ready), to: &graph)
        _ = reducer.apply(.mcpServerStartupStatusUpdated(key: second, status: ready), to: &graph)

        // An equal notification still makes `first` most recent without
        // manufacturing an observable canonical revision.
        let revisionBeforeTouch = graph.revision
        XCTAssertNil(reducer.apply(
            .mcpServerStartupStatusUpdated(key: first, status: ready),
            to: &graph
        ))
        XCTAssertEqual(graph.revision, revisionBeforeTouch)

        _ = reducer.apply(.mcpServerStartupStatusUpdated(key: third, status: ready), to: &graph)

        XCTAssertEqual(Set(graph.mcpServerStartupStatuses.keys), [first, third])
        XCTAssertEqual(graph.mcpServerStartupStatusLRU, [first, third])
        XCTAssertNil(graph.mcpServerStartupStatuses[second])
    }

    private func itemKey(
        thread: ThreadID = "thread",
        turn: TurnID = "turn",
        item: ItemID = "item"
    ) -> ItemKey {
        ItemKey(threadID: thread, turnID: turn, itemID: item)
    }

    private func item(
        _ key: ItemKey,
        kind: ThreadItemKind = .agentMessage,
        payload: [String: CodexJSONValue] = [:],
        authority: ItemAuthority = .started,
        startedAt: Int64? = nil,
        completedAt: Int64? = nil,
        clientUserMessageID: SubmissionIntentID? = nil,
        consistency: StateConsistency = .partial
    ) -> CanonicalItem {
        CanonicalItem(
            key: key,
            kind: kind,
            payload: payload,
            authority: authority,
            startedAt: startedAt.map { ProtocolMilliseconds($0) },
            completedAt: completedAt.map { ProtocolMilliseconds($0) },
            clientUserMessageID: clientUserMessageID,
            consistency: consistency
        )
    }
}
