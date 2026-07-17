import XCTest
@testable import CodexCore

final class StateChangeJournalTests: XCTestCase {
    func testAllScopeRetainsGlobalOnlyChange() {
        let global = StateChangeSet(
            revision: StateRevision(1),
            fields: .connection
        )

        let filtered = global.filtered(to: .all)

        XCTAssertEqual(filtered?.revision, StateRevision(1))
        XCTAssertEqual(filtered?.fields, .connection)
        XCTAssertEqual(filtered?.threadIDs, [])
        XCTAssertEqual(filtered?.turnKeys, [])
        XCTAssertEqual(filtered?.itemKeys, [])
    }

    func testAtomicSeedUsesCurrentRevisionAndSignalBuffersOnlyNewestRevision() async throws {
        let journal = StateChangeJournal(seedRevision: StateRevision(7))
        let observation = journal.observe {
            "snapshot-at-\(journal.currentRevision.rawValue)"
        }

        XCTAssertEqual(observation.seed, "snapshot-at-7")
        XCTAssertEqual(observation.revision, StateRevision(7))
        XCTAssertEqual(journal.observerCount, 1)

        try journal.record(globalChange(revision: 8, fields: .connection))
        try journal.record(globalChange(revision: 9, fields: .account))
        try journal.record(globalChange(revision: 10, fields: .diagnostics))

        var iterator = observation.signals.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertEqual(signal?.latestRevision, StateRevision(10))

        guard case let .changes(changes, through) = journal.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected retained changes")
        }
        XCTAssertEqual(changes.map(\.revision), [StateRevision(8), StateRevision(9), StateRevision(10)])
        XCTAssertEqual(through, StateRevision(10))
    }

    func testThreadAndFieldScopesSuppressUnrelatedWakeupsAndCatchUpChanges() async throws {
        let threadA = ThreadID("thread-a")
        let threadB = ThreadID("thread-b")
        let journal = StateChangeJournal()
        let observation = journal.observe(
            scope: .thread(threadA, fields: .itemContent),
            seed: { "a" }
        )

        try journal.record(
            StateChangeSet(
                revision: StateRevision(1),
                fields: .itemContent,
                itemKeys: [itemKey(thread: threadB)]
            )
        )
        try journal.record(
            StateChangeSet(
                revision: StateRevision(2),
                fields: .threadStatus,
                threadIDs: [threadA]
            )
        )
        let matchingKey = itemKey(thread: threadA)
        try journal.record(
            StateChangeSet(
                revision: StateRevision(3),
                fields: [.itemContent, .usage],
                itemKeys: [matchingKey]
            )
        )

        var iterator = observation.signals.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertEqual(signal?.latestRevision, StateRevision(3))

        guard case let .changes(changes, through) = journal.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected scoped changes")
        }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].revision, StateRevision(3))
        XCTAssertEqual(changes[0].fields, .itemContent)
        XCTAssertEqual(changes[0].itemKeys, [matchingKey])
        XCTAssertEqual(through, StateRevision(3))
    }

    func testThreadAndTurnScopesIncludeDescendantItems() {
        let thread = ThreadID("thread")
        let turn = TurnKey(threadID: thread, turnID: TurnID("turn"))
        let item = ItemKey(threadID: thread, turnID: turn.turnID, itemID: ItemID("item"))
        let changes = StateChangeSet(
            revision: StateRevision(1),
            fields: .itemContent,
            itemKeys: [item]
        )

        XCTAssertTrue(changes.affects(.thread(thread, fields: .itemContent)))
        XCTAssertTrue(changes.affects(.turn(turn, fields: .itemContent)))
        XCTAssertTrue(changes.affects(.item(item, fields: .itemContent)))
        XCTAssertFalse(changes.affects(.global(fields: .itemContent)))
        XCTAssertFalse(changes.affects(.thread("other", fields: .itemContent)))
        XCTAssertFalse(changes.affects(.thread(thread, fields: .threadStatus)))
    }

    func testCanonicalBatchMapsToScopedFieldInvalidations() {
        let item = itemKey(thread: "thread")
        let batch = CanonicalStateChangeBatch(
            baseRevision: .zero,
            revision: StateRevision(1),
            changes: [
                .turnCompleted(item.turnKey),
                .itemDeltaAppended(item),
                .planReplaced(item.turnKey),
            ]
        )

        let changes = StateChangeSet(batch)

        XCTAssertEqual(changes.revision, StateRevision(1))
        XCTAssertEqual(changes.fields, [.turnStatus, .itemContent, .plan])
        XCTAssertEqual(changes.threadIDs, [item.threadID])
        XCTAssertEqual(changes.turnKeys, [item.turnKey])
        XCTAssertEqual(changes.itemKeys, [item])
    }

    func testDestructiveThreadRollbackInvalidatesTurnStructure() {
        let thread = ThreadID("thread")
        let batch = CanonicalStateChangeBatch(
            baseRevision: .zero,
            revision: StateRevision(1),
            changes: [.threadTurnsReplaced(thread)]
        )

        let changes = StateChangeSet(batch)

        XCTAssertEqual(changes.fields, .turnStructure)
        XCTAssertEqual(changes.threadIDs, [thread])
        XCTAssertTrue(changes.affects(.thread(thread, fields: .turnStructure)))
    }

    func testCountEvictionOfRelevantChangeRequiresReset() throws {
        let threadA = ThreadID("thread-a")
        let threadB = ThreadID("thread-b")
        let journal = StateChangeJournal(
            limits: StateChangeJournalLimits(maxChangeSets: 2, maxEstimatedBytes: 10_000)
        )
        let observation = journal.observe(scope: .thread(threadA), seed: { () })

        try journal.record(threadChange(revision: 1, threadID: threadA))
        try journal.record(threadChange(revision: 2, threadID: threadB))
        try journal.record(threadChange(revision: 3, threadID: threadB))

        XCTAssertEqual(journal.retainedChangeSetCount, 2)
        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: observation.revision),
            .reset(to: StateRevision(3))
        )
    }

    func testUnrelatedEvictionsDoNotForceScopedReset() throws {
        let threadA = ThreadID("thread-a")
        let threadB = ThreadID("thread-b")
        let journal = StateChangeJournal(
            limits: StateChangeJournalLimits(maxChangeSets: 2, maxEstimatedBytes: 10_000)
        )
        let observation = journal.observe(scope: .thread(threadA), seed: { () })

        try journal.record(threadChange(revision: 1, threadID: threadB))
        try journal.record(threadChange(revision: 2, threadID: threadB))
        try journal.record(threadChange(revision: 3, threadID: threadA))

        guard case let .changes(changes, through) = journal.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Unrelated eviction must not reset a scoped observer")
        }
        XCTAssertEqual(changes.map(\.revision), [StateRevision(3)])
        XCTAssertEqual(through, StateRevision(3))
    }

    func testByteBudgetEvictsOldestChangeAndTracksRetainedBytes() throws {
        let journal = StateChangeJournal(
            limits: StateChangeJournalLimits(maxChangeSets: 10, maxEstimatedBytes: 100)
        )
        let observation = journal.observe(seed: { () })

        try journal.record(globalChange(revision: 1, estimatedByteCount: 60))
        try journal.record(globalChange(revision: 2, estimatedByteCount: 60))

        XCTAssertEqual(journal.retainedChangeSetCount, 1)
        XCTAssertEqual(journal.retainedEstimatedBytes, 60)
        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: observation.revision),
            .reset(to: StateRevision(2))
        )
    }

    func testOversizedChangeSignalsThenRequiresReset() async throws {
        let journal = StateChangeJournal(
            limits: StateChangeJournalLimits(maxChangeSets: 10, maxEstimatedBytes: 100)
        )
        let observation = journal.observe(seed: { () })

        try journal.record(globalChange(revision: 1, estimatedByteCount: 101))

        XCTAssertEqual(journal.retainedChangeSetCount, 0)
        XCTAssertEqual(journal.retainedEstimatedBytes, 0)
        var iterator = observation.signals.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertEqual(signal?.latestRevision, StateRevision(1))
        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: observation.revision),
            .reset(to: StateRevision(1))
        )
    }

    func testProcessedEvictedRevisionDoesNotRequireReset() throws {
        let thread = ThreadID("thread")
        let journal = StateChangeJournal(
            limits: StateChangeJournalLimits(maxChangeSets: 1, maxEstimatedBytes: 10_000)
        )
        let observation = journal.observe(scope: .thread(thread), seed: { () })

        try journal.record(threadChange(revision: 1, threadID: thread))
        guard case let .changes(first, throughFirst) = journal.catchUp(
            observationID: observation.id,
            after: observation.revision
        ) else {
            return XCTFail("Expected first change")
        }
        XCTAssertEqual(first.map(\.revision), [StateRevision(1)])
        XCTAssertEqual(throughFirst, StateRevision(1))

        try journal.record(threadChange(revision: 2, threadID: thread))
        guard case let .changes(second, throughSecond) = journal.catchUp(
            observationID: observation.id,
            after: throughFirst
        ) else {
            return XCTFail("A processed eviction must not reset")
        }
        XCTAssertEqual(second.map(\.revision), [StateRevision(2)])
        XCTAssertEqual(throughSecond, StateRevision(2))
    }

    func testNoncontiguousRevisionIsRejectedWithoutAdvancingJournal() {
        let journal = StateChangeJournal()

        XCTAssertThrowsError(try journal.record(globalChange(revision: 2))) { error in
            XCTAssertEqual(
                error as? StateChangeJournalError,
                .noncontiguousRevision(expected: StateRevision(1), received: StateRevision(2))
            )
        }
        XCTAssertEqual(journal.currentRevision, .zero)
        XCTAssertEqual(journal.retainedChangeSetCount, 0)
    }

    func testInvalidCursorAndCancelledObservationRequireReset() async {
        let journal = StateChangeJournal(seedRevision: StateRevision(5))
        let observation = journal.observe(seed: { "seed" })

        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: StateRevision(4)),
            .reset(to: StateRevision(5))
        )
        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: StateRevision(6)),
            .reset(to: StateRevision(5))
        )

        journal.cancelObservation(observation.id)
        XCTAssertEqual(journal.observerCount, 0)
        XCTAssertEqual(
            journal.catchUp(observationID: observation.id, after: StateRevision(5)),
            .reset(to: StateRevision(5))
        )

        var iterator = observation.signals.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertNil(signal)
    }

    private func globalChange(
        revision: UInt64,
        fields: StateFieldMask = .diagnostics,
        estimatedByteCount: Int? = nil
    ) -> StateChangeSet {
        StateChangeSet(
            revision: StateRevision(revision),
            fields: fields,
            estimatedByteCount: estimatedByteCount
        )
    }

    private func threadChange(revision: UInt64, threadID: ThreadID) -> StateChangeSet {
        StateChangeSet(
            revision: StateRevision(revision),
            fields: .threadMetadata,
            threadIDs: [threadID]
        )
    }

    private func itemKey(thread: ThreadID) -> ItemKey {
        ItemKey(threadID: thread, turnID: TurnID("turn"), itemID: ItemID("item"))
    }
}
