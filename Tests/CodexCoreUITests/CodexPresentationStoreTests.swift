@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
@Suite(.serialized)
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

    @Test func terminalSupersessionCancelsObsoleteProjectionWork() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Obsolete", turnRevision: 1)
        )
        let cancellationProbe = PresentationProjectionCancellationProbe()
        defer { cancellationProbe.release() }
        let policy = CodexTranscriptItemPresentationPolicyV2 { context in
            cancellationProbe.presentation(for: context)
        }
        let store = CodexPresentationStore(
            adapter: adapter(source),
            itemPresentationPolicy: policy,
            coalescingInterval: .milliseconds(5)
        )

        store.select(threadID: "thread")
        try await eventually { cancellationProbe.didStart }
        #expect(cancellationProbe.startedOnMainThread == false)

        await source.install(
            sessionState(
                revision: 2,
                text: "Newest",
                status: .completed,
                turnRevision: 2
            ),
            change: change(revision: 2, fields: .turnStatus)
        )

        try await eventually { cancellationProbe.didObserveCancellation }
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(2)
                && store.activePresentation?.transcript.turns.first?.finalAnswer?.text
                    == "Newest"
        }

        #expect(cancellationProbe.invocationCount == 2)
        #expect(store.diagnostics.projectionScheduleCount == 2)
        #expect(store.diagnostics.projectionPublishCount == 1)
        #expect(store.diagnostics.discardedProjectionCount == 0)
        #expect(store.diagnostics.terminalFlushCount == 1)
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
        store.select(threadID: "thread")
        #expect(store.isSelectionHydrated)
        #expect(store.containsCachedPresentation(for: "thread"))
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

    @Test func canonicalFileChangePermanentlyDisablesWarmCachingForLifecycle() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Initially cacheable", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activePresentation?.transcript.turns.first?.finalAnswer?.text
                == "Initially cacheable"
        }
        #expect(store.containsCachedPresentation(for: "thread"))

        await source.install(
            fileChangeSessionState(revision: 2, legacy: false),
            change: change(revision: 2, fields: [.turn, .item])
        )
        try await eventually {
            store.activePresentation?.transcript.turns.first?.narrative
                .contains(where: \.containsFileChangeForTesting) == true
        }
        #expect(!store.containsCachedPresentation(for: "thread"))

        await source.install(
            sessionState(revision: 3, text: "Cache remains disabled", turnRevision: 3),
            change: change(revision: 3, fields: [.turn, .item])
        )
        try await eventually {
            store.activePresentation?.transcript.turns.first?.finalAnswer?.text
                == "Cache remains disabled"
        }
        #expect(!store.containsCachedPresentation(for: "thread"))

        store.select(threadID: "neighbor")
        store.select(threadID: "thread")
        #expect(!store.isSelectionHydrated)
    }

    @Test func legacyFileChangeProjectionDoesNotEnterWarmCache() async throws {
        let source = PresentationStateFixture(
            initial: fileChangeSessionState(revision: 1, legacy: true)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually {
            store.activePresentation?.transcript.turns.first?.narrative
                .contains(where: \.containsFileChangeForTesting) == true
        }

        #expect(!store.containsCachedPresentation(for: "thread"))
        store.select(threadID: "neighbor")
        store.select(threadID: "thread")
        #expect(!store.isSelectionHydrated)
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

        #expect(store.activeCanonicalPresentation == nil)
        #expect(store.activeRenderUpdate == nil)
        #expect(store.activePendingRequests.isEmpty)
        #expect(store.activePresentation?.transcript.turns.isEmpty == true)
        #expect(store.observedRevision == .zero)
        #expect(!store.isSelectionHydrated)
        #expect(!store.containsCachedPresentation(for: "thread"))
        try await eventually {
            store.activeCanonicalPresentation?.sourceRevision == StateRevision(1)
                && store.activePresentation?.transcript.turns.first?.finalAnswer?.text
                    == "Replacement"
        }
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

    @Test func memoizesUnreadAttentionRevisionUntilSnapshotChanges() async throws {
        let source = PresentationStateFixture(
            initial: sessionState(revision: 1, text: "Answer", turnRevision: 1)
        )
        let store = CodexPresentationStore(
            adapter: adapter(source),
            coalescingInterval: .milliseconds(5)
        )
        store.select(threadID: "thread")
        try await eventually { store.activePresentation?.transcript.turns.count == 1 }

        for _ in 0..<100 {
            _ = store.hasUnreadAttention(for: "thread")
            store.markSeen(threadID: "thread")
        }

        #expect(store.diagnostics.attentionRevisionCacheMissCount == 1)

        await source.install(
            sessionState(revision: 2, text: "Updated", turnRevision: 2),
            change: change(revision: 2, fields: .itemContent)
        )
        try await eventually { store.observedRevision == StateRevision(2) }
        store.markSeen(threadID: "thread")

        #expect(store.diagnostics.attentionRevisionCacheMissCount == 2)
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

    func fileChangeSessionState(
        revision: UInt64,
        legacy: Bool
    ) -> CodexSessionStateSnapshot {
        let stateRevision = StateRevision(revision)
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let itemID: ItemID = "patch"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let itemKey = ItemKey(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        let payload: [String: CodexJSONValue] = legacy
            ? [
                "status": .string("completed"),
                "files": .array([.string("Sources/Legacy.swift")]),
                "diff": .string("@@ -1 +1 @@\n-old\n+new"),
            ]
            : [
                "status": .string("completed"),
                "changes": .array([.dictionary([
                    "path": .string("Sources/Canonical.swift"),
                    "kind": .dictionary(["type": .string("update")]),
                    "diff": .string("@@ -1 +1 @@\n-old\n+new"),
                ])]),
            ]
        let canonical = CanonicalStateSnapshot(
            revision: stateRevision,
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [turnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: stateRevision
            )],
            turns: [turnKey: CanonicalTurn(
                key: turnKey,
                status: .completed,
                itemOrder: [itemID],
                itemsCoverage: .full,
                itemsConsistency: .authoritative,
                lastChangedRevision: stateRevision
            )],
            items: [itemKey: CanonicalItem(
                key: itemKey,
                kind: .fileChange,
                payload: payload,
                authority: .completed,
                consistency: .authoritative,
                lastChangedRevision: stateRevision
            )]
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

    /// Generous enough that a loaded CI machine cannot fail a correct store, and
    /// still bounded so a genuinely stuck condition reports rather than hangs.
    func eventually(
        timeout: Duration = .seconds(15),
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

private final class PresentationProjectionCancellationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var observedCancellation = false
    private var wasStartedOnMainThread: Bool?
    private var invocations = 0
    private var isReleased = false

    var didStart: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    var didObserveCancellation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedCancellation
    }

    var startedOnMainThread: Bool? {
        condition.lock()
        defer { condition.unlock() }
        return wasStartedOnMainThread
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return invocations
    }

    func presentation(
        for _: CodexTranscriptItemContextV2
    ) -> CodexTranscriptItemPresentationV2 {
        condition.lock()
        invocations += 1
        let shouldWait = invocations == 1
        if shouldWait {
            started = true
            wasStartedOnMainThread = Thread.isMainThread
            condition.broadcast()
        }
        condition.unlock()
        guard shouldWait else { return .standard }

        let deadline = Date().addingTimeInterval(1)
        while true {
            if Task.isCancelled {
                condition.lock()
                observedCancellation = true
                condition.broadcast()
                condition.unlock()
                return .standard
            }
            if Date() >= deadline { return .standard }
            condition.lock()
            if !isReleased {
                _ = condition.wait(until: min(
                    deadline,
                    Date().addingTimeInterval(0.005)
                ))
            }
            let released = isReleased
            condition.unlock()
            if released { return .standard }
        }
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private extension CodexNarrativeEntry {
    var containsFileChangeForTesting: Bool {
        guard case .workGroup(let group) = self else { return false }
        return group.rows.contains { row in
            if case .fileChange = row { true } else { false }
        }
    }
}
