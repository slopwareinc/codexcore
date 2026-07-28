@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexPresentationStoreTests {
    @Test func incompleteResumeShellDoesNotReplaceWarmCachedTranscript() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Cached", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )

        store.select(threadID: "thread")
        try await eventually {
            store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "Cached"
        }

        await source.install(
            emptyThreadState(revision: 2, coverage: .notLoaded),
            change: change(revision: 2, fields: [.thread, .turn, .item])
        )
        try await eventually { store.observedRevision == StateRevision(2) }

        #expect(store.isSelectionHydrated)
        #expect(store.activeCanonicalPresentation?.sourceRevision == StateRevision(1))
        #expect(store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "Cached")
        #expect(store.diagnostics.deferredIncompleteHistoryCount == 1)

        await source.install(
            emptyThreadState(revision: 3, coverage: .full),
            change: change(revision: 3, fields: [.thread, .turn, .item])
        )
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(3)
        }

        #expect(store.isSelectionHydrated)
        #expect(store.activePresentation?.transcript.turns.isEmpty == true)
    }

    @Test func coldSelectionWaitsThroughIncompleteThreadShellUntilEmptyHistoryIsAuthoritative() async throws {
        let source = PresentationStateFixture(
            initial: emptyThreadState(revision: 1, coverage: .notLoaded)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )

        store.select(threadID: "thread")
        try await eventually { store.observedRevision == StateRevision(1) }

        #expect(store.isSelectionHydrated == false)
        #expect(store.activeCanonicalPresentation == nil)
        #expect(store.diagnostics.deferredIncompleteHistoryCount == 1)

        await source.install(
            emptyThreadState(revision: 2, coverage: .full),
            change: change(revision: 2, fields: [.thread])
        )
        try await eventually {
            store.isSelectionHydrated
                && store.activeCanonicalPresentation?.sourceRevision == StateRevision(2)
        }

        #expect(store.activePresentation?.transcript.turns.isEmpty == true)
    }

    @Test func coldSelectionWaitsForThreadStateInsteadOfPublishingAnEmptyChat() async throws {
        let source = PresentationStateFixture(initial: sessionState(revision: 0))
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )

        store.select(threadID: "thread")
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.isSelectionHydrated == false)
        #expect(store.activePresentation?.transcript.turns.isEmpty == true)

        await source.install(
            sessionState(revision: 1, text: "Hydrated", turnRevision: 1),
            change: change(revision: 1, fields: [.thread, .turn, .item])
        )
        try await eventually {
            store.isSelectionHydrated
                && store.activePresentation?.transcript.turns.first?.finalAnswer?.text == "Hydrated"
        }
    }

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

    @Test func localStateIsStableAndStrictlyBoundedToTwentyThreads() async throws {
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
        store.selectDiffFile(index: 2, rowID: "diff", threadID: "thread")

        store.select(threadID: "warm-neighbor")
        #expect(store.isSelectionHydrated == false)
        #expect(store.containsCachedPresentation(for: "thread"))
        #expect(store.warmPresentationRetainedByteCount > 0)
        store.select(threadID: "thread")
        #expect(store.isSelectionHydrated)
        #expect(!store.containsCachedPresentation(for: "thread"))
        #expect(store.warmPresentationRetainedByteCount == 0)
        #expect(store.activePresentation?.transcript.turns.count == 1)
        #expect(store.diagnostics.presentationCacheHitCount == 1)
        #expect(store.activePresentation?.rawScrollOffset == 417)
        #expect(store.activePresentation?.isPinnedToBottom == false)
        #expect(store.activePresentation?.presentedAtByTurnID["turn"] == firstPresentedAt)
        #expect(store.activePresentation?.expandedWorkTurnIDs == ["turn"])
        #expect(store.activePresentation?.expandedRowIDs == ["answer"])
        #expect(store.activePresentation?.selectedDiffFileIndexByRowID == ["diff": 2])

        for index in 0..<20 {
            store.select(threadID: ThreadID("other-\(index)"))
        }
        #expect(!store.containsLocalState(for: "thread"))
        #expect(store.diagnostics.uiStateEvictionCount == 2)

        store.select(threadID: "thread")
        #expect(store.isSelectionHydrated == false)
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }
        #expect(store.activePresentation?.rawScrollOffset == 0)
        #expect(store.activePresentation?.isPinnedToBottom == true)
        #expect(store.activePresentation?.presentedAtByTurnID["turn"] == firstPresentedAt)

        // The deterministic clock gives a re-created thread the same value;
        // eviction is proven by the reset scroll/expansion state above.
        #expect(store.activePresentation?.expandedWorkTurnIDs.isEmpty == true)
        #expect(store.activePresentation?.expandedRowIDs.isEmpty == true)
        #expect(store.activePresentation?.selectedDiffFileIndexByRowID.isEmpty == true)
    }

    @Test func bytePressureEvictsOnlyWarmProjectionAndPreservesLocalState() async throws {
        let answer = String(repeating: "retained transcript payload ", count: 256)
        let source = PresentationStateFixture(
            initial: multiThreadAssistantState(
                revision: 1,
                threadIDs: ["one", "two"],
                text: answer
            )
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5),
            warmPresentationByteCapacity: 1_024
        )

        store.select(threadID: "one")
        try await eventually {
            (store.activeCanonicalPresentation?.estimatedRetainedByteCount ?? 0)
                > answer.utf8.count
        }
        #expect(store.activeCanonicalPresentation?.retainedPreparedUTF8ByteCount == 0)
        #expect(!store.containsCachedPresentation(for: "one"))
        #expect(store.warmPresentationRetainedByteCount == 0)
        #expect(store.diagnostics.presentationCacheByteEvictionCount == 0)
        store.updateScrollState(threadID: "one", rawOffset: 73, isPinnedToBottom: false)

        store.select(threadID: "two")

        #expect(!store.containsCachedPresentation(for: "one"))
        #expect(store.containsLocalState(for: "one"))
        #expect(store.localState(for: "one")?.rawScrollOffset == 73)
        #expect(store.warmPresentationRetainedByteCount <= 1_024)
        #expect(
            store.warmPresentationRetainedUTF8ByteCount
                == store.warmPresentationRetainedByteCount
        )
        #expect(store.diagnostics.presentationCacheByteEvictionCount == 1)
    }

    @Test func inclusiveEstimateChargesExactPatchBeyondPreparedDisplayBudget() {
        let exactDiff = "@@ -0,0 +1 @@\n+" + String(
            repeating: "x",
            count: CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes * 2
        )
        let row = CodexFileChangeRowV2(
            id: "patch",
            changes: [.init(
                id: "patch:file",
                path: "Sources/Large.swift",
                kind: .modified,
                diff: exactDiff
            )],
            status: .completed
        )
        let turnID: TurnID = "turn"
        let turn = CodexTurnV2(
            id: turnID.rawValue,
            narrative: [.workGroup(.init(
                id: "work",
                rows: [.fileChange(row)],
                isLive: false
            ))],
            status: .done(durationMs: 1)
        )
        let presentation = CodexCanonicalTranscriptPresentation(
            threadID: "thread",
            sourceRevision: StateRevision(1),
            turnOrder: [turnID],
            turnsByID: [turnID: turn],
            sourceTurnRevisions: [turnID: StateRevision(1)]
        )

        #expect(
            row.retainedPreparedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(presentation.estimatedRetainedByteCount > exactDiff.utf8.count)
    }

    @Test func disconnectedActiveProjectionCannotReenterWarmCache() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Prior adapter", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(1)
        }

        store.disconnect()
        store.select(threadID: "other")

        #expect(!store.containsCachedPresentation(for: "thread"))
        #expect(store.warmPresentationRetainedByteCount == 0)
    }

    @Test func adapterReplacementAcceptsLowerRevisionWithoutReusingPriorBaseline() async throws {
        let original = PresentationStateFixture(
            initial: sessionState(revision: 9, text: "Original", turnRevision: 9)
        )
        let replacement = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Replacement", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(original),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(9)
        }

        store.connect(adapter(replacement))

        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(1)
                && store.activePresentation?.transcript.turns.first?.finalAnswer?.text
                    == "Replacement"
        }
        #expect(store.warmPresentationRetainedByteCount == 0)
    }

    @Test func scrollPersistenceDoesNotRepublishActivePresentation() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Answer", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }
        let presentationRevision = store.presentationRevision

        store.updateScrollState(threadID: "thread", rawOffset: 417, isPinnedToBottom: false)

        #expect(store.localState(for: "thread")?.rawScrollOffset == 417)
        #expect(store.localState(for: "thread")?.isPinnedToBottom == false)
        #expect(store.presentationRevision == presentationRevision)
        #expect(store.activePresentation?.rawScrollOffset == 0)
        #expect(store.activePresentation?.isPinnedToBottom == true)
    }
}

private actor PresentationStateFixture: CodexSessionStateObserving {
    private var snapshot: CodexSessionStateSnapshot
    private let observations = ObservationHub()
    private var queuedAfterObservation: (CodexSessionStateSnapshot, StateInvalidation)?

    init(initial: CodexSessionStateSnapshot) {
        self.snapshot = initial
    }

    func canonicalSnapshot(scope: StateObservationScope) -> CanonicalStateSnapshot {
        snapshot.canonical.scoped(to: scope)
    }

    func observe(
        scope: StateObservationScope
    ) -> StateSnapshotObservation<CanonicalStateSnapshot> {
        observations.observe(scope: scope, revision: snapshot.stateRevision) {
            snapshot.canonical.scoped(to: scope)
        }
    }

    func sessionStateSnapshot(scope: StateObservationScope) -> CodexSessionStateSnapshot {
        scopedSnapshot(scope)
    }

    func observeSessionState(
        scope: StateObservationScope
    ) -> StateSnapshotObservation<CodexSessionStateSnapshot> {
        let observation = observations.observe(scope: scope, revision: snapshot.stateRevision) {
            scopedSnapshot(scope)
        }
        if let queuedAfterObservation {
            self.queuedAfterObservation = nil
            snapshot = queuedAfterObservation.0
            observations.publish(queuedAfterObservation.1)
        }
        return observation
    }

    func cancelObservation(_ observationID: StateObservationID) {
        observations.cancelObservation(observationID)
    }

    func install(_ snapshot: CodexSessionStateSnapshot, change: StateInvalidation) {
        self.snapshot = snapshot
        observations.publish(change)
    }

    func queueAfterNextObservation(
        _ snapshot: CodexSessionStateSnapshot,
        change: StateInvalidation
    ) {
        queuedAfterObservation = (snapshot, change)
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

    func emptyThreadState(
        revision: UInt64,
        coverage: StateCoverage
    ) -> CodexSessionStateSnapshot {
        let stateRevision = StateRevision(revision)
        let threadID: ThreadID = "thread"
        let thread = CanonicalThread(
            id: threadID,
            status: .idle,
            history: .init(turnsCoverage: coverage),
            isLoaded: true,
            consistency: coverage == .full ? .authoritative : .partial,
            lastChangedRevision: stateRevision
        )
        return .init(
            stateRevision: stateRevision,
            canonical: .init(
                revision: stateRevision,
                threadOrder: [threadID],
                threads: [threadID: thread]
            ),
            serverRequests: .init(revision: stateRevision, requests: []),
            lifecycle: .ready(connectionEpoch: 1)
        )
    }

    func multiThreadAssistantState(
        revision: UInt64,
        threadIDs: [ThreadID],
        text: String
    ) -> CodexSessionStateSnapshot {
        let stateRevision = StateRevision(revision)
        var threads: [ThreadID: CanonicalThread] = [:]
        var turns: [TurnKey: CanonicalTurn] = [:]
        var items: [ItemKey: CanonicalItem] = [:]

        for threadID in threadIDs {
            let turnID = TurnID("turn-\(threadID.rawValue)")
            let itemID: ItemID = "answer"
            let turnKey = TurnKey(threadID: threadID, turnID: turnID)
            let itemKey = ItemKey(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID
            )
            threads[threadID] = CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [turnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: stateRevision
            )
            turns[turnKey] = CanonicalTurn(
                key: turnKey,
                status: .completed,
                itemOrder: [itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative,
                lastChangedRevision: stateRevision
            )
            items[itemKey] = CanonicalItem(
                key: itemKey,
                kind: .agentMessage,
                payload: [
                    "phase": .string("final_answer"),
                    "text": .string(text),
                ],
                authority: .completed,
                consistency: .authoritative,
                lastChangedRevision: stateRevision
            )
        }

        let canonical = CanonicalStateSnapshot(
            revision: stateRevision,
            threadOrder: threadIDs,
            threads: threads,
            turns: turns,
            items: items
        )
        return .init(
            stateRevision: stateRevision,
            canonical: canonical,
            serverRequests: .init(revision: stateRevision, requests: []),
            lifecycle: .ready(connectionEpoch: 1)
        )
    }

    func change(revision: UInt64, fields: StateFieldMask) -> StateInvalidation {
        let threadID: ThreadID = "thread"
        let turnKey = TurnKey(threadID: threadID, turnID: "turn")
        let itemKey = ItemKey(threadID: threadID, turnID: "turn", itemID: "answer")
        return StateInvalidation(
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
