@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexPresentationStoreTests {
    @Test func atomicSeedCannotMissAChangeBufferedDuringSubscription() async throws {
        let source = PresentationStateFixture(initial: sessionState(revision: 0))
        let changed = sessionState(revision: 1, text: "Buffered")
        await source.queueAfterNextObservation(
            changed,
            change: change(revision: 1, fields: [.turn, .item])
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5),
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.select(threadID: "thread")
        try await eventually {
            store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "Buffered"
        }

        #expect(store.activeCanonicalPresentation?.sourceRevision == StateRevision(1))
        #expect(store.observedRevision == StateRevision(1))
        #expect(store.diagnostics.invalidSnapshotCount == 0)
        let catchUpCalls = await source.catchUpCallCount()
        #expect(catchUpCalls == 0)
    }

    @Test func coalescesStreamingChangesButFlushesTerminalTurnImmediately() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "A", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(250)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(1)
        }

        await source.install(
            sessionState(revision: 2, text: "AB", turnRevision: 2),
            change: change(revision: 2, fields: .itemContent)
        )
        await source.install(
            sessionState(revision: 3, text: "ABC", turnRevision: 3),
            change: change(revision: 3, fields: .itemContent)
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.activeCanonicalPresentation?.sourceRevision == StateRevision(1))

        try await eventually(timeout: .seconds(1)) {
            store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "ABC"
        }
        #expect(store.activeCanonicalPresentation?.sourceRevision == StateRevision(3))

        await source.install(
            sessionState(
                revision: 4,
                text: "Done",
                status: .completed,
                turnRevision: 4
            ),
            change: change(revision: 4, fields: .turnStatus)
        )
        try await Task.sleep(for: .milliseconds(80))

        #expect(store.activeCanonicalPresentation?.sourceRevision == StateRevision(4))
        #expect(store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "Done")
        #expect(store.diagnostics.terminalFlushCount == 1)
        #expect(store.diagnostics.receivedSignalCount >= 2)
    }

    @Test func revisionedEmptyRequestBatchRemovesLastApproval() async throws {
        let pending = request(revision: 1)
        let source = PresentationStateFixture(initial: sessionState(
            revision: 1,
            text: "Waiting",
            turnRevision: 1,
            requests: [pending]
        ))
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activePresentation?.pendingApprovals.count == 1
        }
        #expect(store.activeCanonicalPresentation?.requestSourceRevision == 1)

        await source.install(
            sessionState(
                revision: 2,
                text: "Waiting",
                turnRevision: 1,
                requests: []
            ),
            change: change(revision: 2, fields: .requests)
        )
        try await eventually {
            store.activeCanonicalPresentation?.requestSourceRevision == 2
        }

        #expect(store.activePresentation?.pendingApprovals.isEmpty == true)
        #expect(store.activePendingRequests.isEmpty)
    }

    @Test func localStateIsStableAndStrictlyBoundedToTwelveThreads() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Answer", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5),
            now: { Date(timeIntervalSince1970: 123) }
        )
        store.select(threadID: "thread")
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }
        let firstPresentedAt = store.activePresentation?.presentedAtByTurnID["turn"]
        store.updateScrollState(threadID: "thread", rawOffset: 417, isPinnedToBottom: false)
        store.setWorkExpanded(true, turnID: "turn", threadID: "thread")
        store.setRowExpanded(true, rowID: "answer", threadID: "thread")

        store.select(threadID: "warm-neighbor")
        store.select(threadID: "thread")
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }
        #expect(store.activePresentation?.rawScrollOffset == 417)
        #expect(store.activePresentation?.isPinnedToBottom == false)
        #expect(store.activePresentation?.presentedAtByTurnID["turn"] == firstPresentedAt)
        #expect(store.activePresentation?.expandedWorkTurnIDs == ["turn"])
        #expect(store.activePresentation?.expandedRowIDs == ["answer"])

        for index in 0..<12 {
            store.select(threadID: ThreadID("other-\(index)"))
        }
        #expect(!store.containsLocalState(for: "thread"))
        #expect(store.diagnostics.uiStateEvictionCount == 2)

        store.select(threadID: "thread")
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }
        #expect(store.activePresentation?.rawScrollOffset == 0)
        #expect(store.activePresentation?.isPinnedToBottom == true)
        #expect(store.activePresentation?.presentedAtByTurnID["turn"] == firstPresentedAt)

        // The deterministic clock gives a re-created thread the same value;
        // eviction is proven by the reset scroll/expansion state above.
        #expect(store.activePresentation?.expandedWorkTurnIDs.isEmpty == true)
        #expect(store.activePresentation?.expandedRowIDs.isEmpty == true)
    }
}

private actor PresentationStateFixture: CodexSessionStateObserving {
    private var snapshot: CodexSessionStateSnapshot
    private let journal: StateChangeJournal
    private var queuedAfterObservation: (CodexSessionStateSnapshot, StateChangeSet)?
    private var catchUpCalls = 0

    init(initial: CodexSessionStateSnapshot) {
        self.snapshot = initial
        self.journal = StateChangeJournal(seedRevision: initial.stateRevision)
    }

    func canonicalSnapshot(scope: StateObservationScope) -> CanonicalStateSnapshot {
        snapshot.canonical.scoped(to: scope)
    }

    func observe(
        scope: StateObservationScope
    ) -> StateObservation<CanonicalStateSnapshot> {
        journal.observe(scope: scope) {
            snapshot.canonical.scoped(to: scope)
        }
    }

    func sessionStateSnapshot(scope: StateObservationScope) -> CodexSessionStateSnapshot {
        scopedSnapshot(scope)
    }

    func observeSessionState(
        scope: StateObservationScope
    ) -> StateObservation<CodexSessionStateSnapshot> {
        let observation = journal.observe(scope: scope) {
            scopedSnapshot(scope)
        }
        if let queuedAfterObservation {
            self.queuedAfterObservation = nil
            snapshot = queuedAfterObservation.0
            try! journal.record(queuedAfterObservation.1)
        }
        return observation
    }

    func catchUp(
        observationID: StateObservationID,
        after revision: StateRevision
    ) -> StateCatchUp {
        catchUpCalls += 1
        return journal.catchUp(observationID: observationID, after: revision)
    }

    func cancelObservation(_ observationID: StateObservationID) {
        journal.cancelObservation(observationID)
    }

    func install(_ snapshot: CodexSessionStateSnapshot, change: StateChangeSet) {
        self.snapshot = snapshot
        try! journal.record(change)
    }

    func queueAfterNextObservation(
        _ snapshot: CodexSessionStateSnapshot,
        change: StateChangeSet
    ) {
        queuedAfterObservation = (snapshot, change)
    }

    func catchUpCallCount() -> Int {
        catchUpCalls
    }

    private func scopedSnapshot(_ scope: StateObservationScope) -> CodexSessionStateSnapshot {
        CodexSessionStateSnapshot(
            stateRevision: snapshot.stateRevision,
            canonical: snapshot.canonical.scoped(to: scope),
            serverRequests: snapshot.serverRequests,
            lifecycle: snapshot.lifecycle
        )
    }
}

private extension CodexPresentationStoreTests {
    func adapter(_ source: PresentationStateFixture) -> CodexPresentationStateAdapter {
        CodexPresentationStateAdapter(stateSource: source)
    }

    func sessionState(
        revision: UInt64,
        text: String? = nil,
        status: CanonicalTurnStatus = .inProgress,
        turnRevision: UInt64? = nil,
        requests: [CodexPendingInteractionSnapshot] = []
    ) -> CodexSessionStateSnapshot {
        let stateRevision = StateRevision(revision)
        guard let text else {
            return .init(
                stateRevision: stateRevision,
                canonical: .init(revision: stateRevision),
                serverRequests: .init(revision: stateRevision, requests: requests),
                lifecycle: .ready(connectionEpoch: 1)
            )
        }

        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let sourceRevision = StateRevision(turnRevision ?? revision)
        let thread = CanonicalThread(
            id: threadID,
            status: .active(flags: []),
            turnOrder: [turnID],
            history: .init(turnsCoverage: .full),
            consistency: .authoritative,
            lastChangedRevision: sourceRevision
        )
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: status,
            itemOrder: ["answer"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: sourceRevision
        )
        let item = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "answer"),
            kind: .agentMessage,
            payload: [
                "phase": .string("final_answer"),
                "text": .string(text),
            ],
            authority: status.isTerminal ? .completed : .started,
            consistency: .authoritative,
            lastChangedRevision: sourceRevision
        )
        let canonical = CanonicalStateSnapshot(
            revision: stateRevision,
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: [turn.key: turn],
            items: [item.key: item]
        )
        return .init(
            stateRevision: stateRevision,
            canonical: canonical,
            serverRequests: .init(revision: stateRevision, requests: requests),
            lifecycle: .ready(connectionEpoch: 1)
        )
    }

    func change(revision: UInt64, fields: StateFieldMask) -> StateChangeSet {
        let threadID: ThreadID = "thread"
        let turnKey = TurnKey(threadID: threadID, turnID: "turn")
        let itemKey = ItemKey(threadID: threadID, turnID: "turn", itemID: "answer")
        return StateChangeSet(
            revision: StateRevision(revision),
            fields: fields,
            threadIDs: [threadID],
            turnKeys: [turnKey],
            itemKeys: fields.contains(.itemContent) ? [itemKey] : []
        )
    }

    func request(revision: UInt64) -> CodexPendingInteractionSnapshot {
        .init(
            key: .init(connectionEpoch: 1, requestID: .integer(7)),
            method: CodexServerRequestKind.commandApproval.method,
            kind: .commandApproval,
            scope: .init(threadID: "thread", turnID: "turn", itemID: "answer"),
            approvalCorrelation: nil,
            arrivalOrdinal: revision
        )
    }

    func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PresentationWaitError.timedOut
    }
}

private enum PresentationWaitError: Error {
    case timedOut
}
