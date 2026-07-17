import CodexCore
import Foundation
import Observation

/// A stateless seam between `CodexSession` and presentation projection.
///
/// Every closure must forward to the same actor-owned canonical state journal.
/// In particular, `observe` must return the journal's atomic seed/stream pair;
/// this adapter must never take its own snapshot and then subscribe separately.
public struct CodexPresentationStateAdapter: Sendable {
    public typealias Observe = @Sendable (
        StateObservationScope
    ) async -> StateObservation<CodexSessionStateSnapshot>
    public typealias CatchUp = @Sendable (
        StateObservationID,
        StateRevision
    ) async -> StateCatchUp
    public typealias Cancel = @Sendable (StateObservationID) async -> Void
    public typealias CurrentSnapshot = @Sendable (
        StateObservationScope
    ) async -> CodexSessionStateSnapshot

    private let observeClosure: Observe
    private let catchUpClosure: CatchUp
    private let cancelClosure: Cancel
    private let currentSnapshotClosure: CurrentSnapshot

    public init(
        observe: @escaping Observe,
        catchUp: @escaping CatchUp,
        cancel: @escaping Cancel,
        currentSnapshot: @escaping CurrentSnapshot
    ) {
        self.observeClosure = observe
        self.catchUpClosure = catchUp
        self.cancelClosure = cancel
        self.currentSnapshotClosure = currentSnapshot
    }

    fileprivate func observe(
        scope: StateObservationScope
    ) async -> StateObservation<CodexSessionStateSnapshot> {
        await observeClosure(scope)
    }

    fileprivate func catchUp(
        observationID: StateObservationID,
        after revision: StateRevision
    ) async -> StateCatchUp {
        await catchUpClosure(observationID, revision)
    }

    fileprivate func cancel(observationID: StateObservationID) async {
        await cancelClosure(observationID)
    }

    fileprivate func currentSnapshot(
        scope: StateObservationScope
    ) async -> CodexSessionStateSnapshot {
        await currentSnapshotClosure(scope)
    }
}

public extension CodexPresentationStateAdapter {
    /// Adapter for the canonical observation Interface implemented by the sole
    /// ordered session actor and by deterministic fixtures.
    init<Source: CodexSessionStateObserving>(stateSource: Source) {
        self.init(
            observe: { scope in
                await stateSource.observeSessionState(scope: scope)
            },
            catchUp: { observationID, revision in
                await stateSource.catchUp(observationID: observationID, after: revision)
            },
            cancel: { observationID in
                await stateSource.cancelObservation(observationID)
            },
            currentSnapshot: { scope in
                await stateSource.sessionStateSnapshot(scope: scope)
            }
        )
    }

    /// Explicit convenience for application composition roots.
    init(session: CodexSession) {
        self.init(stateSource: session)
    }
}

/// The only durable state owned by the presentation layer for one thread.
public struct CodexThreadPresentationLocalState: Sendable, Equatable {
    public var rawScrollOffset: CGFloat
    public var isPinnedToBottom: Bool
    public var expandedWorkTurnIDs: Set<String>
    public var expandedRowIDs: Set<String>
    public var firstPresentedAtByTurnID: [String: Date]
    public var lastSeenAttentionRevision: StateRevision

    public init(
        rawScrollOffset: CGFloat = 0,
        isPinnedToBottom: Bool = true,
        expandedWorkTurnIDs: Set<String> = [],
        expandedRowIDs: Set<String> = [],
        firstPresentedAtByTurnID: [String: Date] = [:],
        lastSeenAttentionRevision: StateRevision = .zero
    ) {
        self.rawScrollOffset = rawScrollOffset
        self.isPinnedToBottom = isPinnedToBottom
        self.expandedWorkTurnIDs = expandedWorkTurnIDs
        self.expandedRowIDs = expandedRowIDs
        self.firstPresentedAtByTurnID = firstPresentedAtByTurnID
        self.lastSeenAttentionRevision = lastSeenAttentionRevision
    }
}

public struct CodexPresentationStoreDiagnostics: Sendable, Equatable {
    public fileprivate(set) var observationResetCount = 0
    public fileprivate(set) var receivedChangeSetCount = 0
    public fileprivate(set) var projectionScheduleCount = 0
    public fileprivate(set) var projectionPublishCount = 0
    public fileprivate(set) var coalescedChangeSetCount = 0
    public fileprivate(set) var terminalFlushCount = 0
    public fileprivate(set) var discardedProjectionCount = 0
    public fileprivate(set) var uiStateEvictionCount = 0

    public init() {}
}

/// Main-actor presentation state derived from `CodexSession`'s canonical graph.
///
/// Canonical snapshots and projected transcripts are disposable caches. The
/// bounded per-thread dictionary below contains UI state only; no wire event is
/// reduced here and no second protocol truth exists in this type.
@MainActor
@Observable
public final class CodexPresentationStore {
    public static let uiStateCapacity = 12

    public private(set) var selectedThreadID: ThreadID?
    public private(set) var activePresentation: CodexThreadUIPresentation?
    public private(set) var activeCanonicalPresentation: CodexCanonicalTranscriptPresentation?
    public private(set) var activeRenderUpdate: CodexCanonicalTranscriptRenderUpdate?
    public private(set) var activePendingRequests: [CodexTranscriptRequestPresentation] = []
    public private(set) var observedRevision: StateRevision = .zero
    public private(set) var presentationRevision = 0
    public private(set) var diagnostics = CodexPresentationStoreDiagnostics()

    @ObservationIgnored private let coalescingInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let projector = CodexCanonicalTranscriptProjector()
    @ObservationIgnored private var adapter: CodexPresentationStateAdapter?
    @ObservationIgnored private var localStateByThreadID: [ThreadID: CodexThreadPresentationLocalState] = [:]
    @ObservationIgnored private var leastToMostRecentThreadIDs: [ThreadID] = []
    @ObservationIgnored private var latestSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var latestRequestBatch = CodexServerRequestSnapshotBatch(
        revision: .zero,
        requests: []
    )
    @ObservationIgnored private var pendingSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var pendingRequestBatch = CodexServerRequestSnapshotBatch(
        revision: .zero,
        requests: []
    )
    @ObservationIgnored private var pendingDirtyTurns: Set<TurnKey> = []
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var projectionGeneration: UInt64 = 0

    public init(
        adapter: CodexPresentationStateAdapter? = nil,
        coalescingInterval: Duration = .milliseconds(17),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.coalescingInterval = coalescingInterval
        self.now = now
    }

    deinit {
        observationTask?.cancel()
        projectionTask?.cancel()
    }

    /// Attaches a stateless adapter. Observation begins when a thread is selected.
    public func connect(_ adapter: CodexPresentationStateAdapter) {
        self.adapter = adapter
        restartObservation()
    }

    public func disconnect() {
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        projectionGeneration &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        adapter = nil
        clearPendingProjection()
    }

    public func select(threadID: ThreadID?) {
        guard selectedThreadID != threadID else {
            if let threadID { touch(threadID) }
            return
        }

        selectedThreadID = threadID
        latestSnapshot = nil
        latestRequestBatch = .init(revision: .zero, requests: [])
        activeCanonicalPresentation = nil
        activeRenderUpdate = nil
        activePendingRequests = []
        cancelProjection()

        guard let threadID else {
            activePresentation = nil
            presentationRevision &+= 1
            restartObservation()
            return
        }

        ensureLocalState(for: threadID)
        touch(threadID)
        var local = localStateByThreadID[threadID] ?? .init()
        local.lastSeenAttentionRevision = observedRevision
        localStateByThreadID[threadID] = local
        activePresentation = Self.presentation(
            threadID: threadID,
            transcript: .init(),
            localState: local,
            pendingApprovals: []
        )
        presentationRevision &+= 1
        restartObservation()
    }

    public func localState(for threadID: ThreadID) -> CodexThreadPresentationLocalState? {
        localStateByThreadID[threadID]
    }

    public func containsLocalState(for threadID: ThreadID) -> Bool {
        localStateByThreadID[threadID] != nil
    }

    public func hasUnreadAttention(for threadID: ThreadID) -> Bool {
        guard let local = localStateByThreadID[threadID],
              let snapshot = latestSnapshot
        else { return false }
        return local.lastSeenAttentionRevision < Self.latestAttentionRevision(
            threadID: threadID,
            snapshot: snapshot,
            requests: latestRequestBatch.requests
        )
    }

    public func markSeen(threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.lastSeenAttentionRevision = Self.latestAttentionRevision(
            threadID: threadID,
            snapshot: latestSnapshot,
            requests: latestRequestBatch.requests,
            fallback: observedRevision
        )
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    public func updateScrollState(
        threadID: ThreadID,
        rawOffset: CGFloat,
        isPinnedToBottom: Bool
    ) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.rawScrollOffset = rawOffset
        local.isPinnedToBottom = isPinnedToBottom
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    public func setWorkExpanded(_ expanded: Bool, turnID: String, threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        if expanded {
            local.expandedWorkTurnIDs.insert(turnID)
        } else {
            local.expandedWorkTurnIDs.remove(turnID)
        }
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    public func setRowExpanded(_ expanded: Bool, rowID: String, threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        if expanded {
            local.expandedRowIDs.insert(rowID)
        } else {
            local.expandedRowIDs.remove(rowID)
        }
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    /// Flushes the latest selected-thread projection without waiting for a frame.
    public func synchronizePresentation() {
        guard pendingSnapshot != nil else { return }
        cancelProjection(clearPending: false)
        launchProjection(afterCoalescingDelay: false)
    }

    public func removeLocalState(for threadID: ThreadID) {
        localStateByThreadID.removeValue(forKey: threadID)
        leastToMostRecentThreadIDs.removeAll { $0 == threadID }
        if selectedThreadID == threadID { select(threadID: nil) }
    }

    public func resetLocalState() {
        select(threadID: nil)
        localStateByThreadID.removeAll(keepingCapacity: false)
        leastToMostRecentThreadIDs.removeAll(keepingCapacity: false)
        diagnostics = .init()
    }
}

// MARK: - Atomic observation

private extension CodexPresentationStore {
    static let presentationFields: StateFieldMask = [
        .thread,
        .turn,
        .item,
        .requests,
        .submissionIntents,
    ]

    func restartObservation() {
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil

        guard let adapter, let threadID = selectedThreadID else { return }
        let generation = observationGeneration
        let scope = StateObservationScope.thread(threadID, fields: Self.presentationFields)

        observationTask = Task { [weak self, adapter] in
            var shouldReseed = true
            while shouldReseed, !Task.isCancelled {
                shouldReseed = false
                let observation = await adapter.observe(scope: scope)
                guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                    await adapter.cancel(observationID: observation.id)
                    return
                }

                guard observation.seed.stateRevision == observation.revision,
                      observation.seed.canonical.revision == observation.revision
                else {
                    self?.noteObservationReset()
                    await adapter.cancel(observationID: observation.id)
                    shouldReseed = true
                    continue
                }

                self?.accept(
                    sessionSnapshot: observation.seed,
                    changes: [],
                    forceImmediate: true
                )

                var cursor = observation.revision
                var iterator = observation.signals.makeAsyncIterator()
                while !Task.isCancelled, await iterator.next() != nil {
                    guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                        break
                    }

                    let catchUp = await adapter.catchUp(
                        observationID: observation.id,
                        after: cursor
                    )
                    guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                        break
                    }

                    switch catchUp {
                    case .reset:
                        self?.noteObservationReset()
                        shouldReseed = true

                    case .changes(let changes, let through):
                        let snapshot = await adapter.currentSnapshot(scope: scope)
                        guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                            break
                        }
                        guard snapshot.stateRevision >= through,
                              snapshot.canonical.revision == snapshot.stateRevision
                        else {
                            self?.noteObservationReset()
                            shouldReseed = true
                            break
                        }
                        cursor = snapshot.stateRevision
                        self?.accept(
                            sessionSnapshot: snapshot,
                            changes: changes,
                            forceImmediate: false
                        )
                    }

                    if shouldReseed { break }
                }

                await adapter.cancel(observationID: observation.id)
            }
        }
    }

    func isCurrentObservation(generation: UInt64, threadID: ThreadID) -> Bool {
        !Task.isCancelled
            && observationGeneration == generation
            && selectedThreadID == threadID
    }

    func noteObservationReset() {
        diagnostics.observationResetCount &+= 1
    }

    func accept(
        sessionSnapshot: CodexSessionStateSnapshot,
        changes: [StateChangeSet],
        forceImmediate: Bool
    ) {
        guard let threadID = selectedThreadID else { return }
        let snapshot = sessionSnapshot.canonical
        let requestBatch = sessionSnapshot.serverRequests
        let previousObservedRevision = observedRevision
        observedRevision = sessionSnapshot.stateRevision
        latestSnapshot = snapshot
        latestRequestBatch = requestBatch
        diagnostics.receivedChangeSetCount &+= changes.count

        var dirtyTurns = Set(changes.flatMap(\.turnKeys))
        dirtyTurns.formUnion(changes.flatMap(\.itemKeys).map(\.turnKey))
        // `canonicalSnapshot()` may run one actor turn after `catchUp()`. If the
        // graph advanced in that interval, parent turn revisions recover the
        // complete dirty set without rescanning item payloads.
        let previousTurnRevisions = activeCanonicalPresentation?.sourceTurnRevisions ?? [:]
        for turn in snapshot.turns.values where turn.key.threadID == threadID {
            if turn.lastChangedRevision > (previousTurnRevisions[turn.key.turnID] ?? .zero) {
                dirtyTurns.insert(turn.key)
            }
        }
        pendingDirtyTurns.formUnion(dirtyTurns)
        pendingSnapshot = snapshot
        pendingRequestBatch = requestBatch

        let baseline = activeCanonicalPresentation?.sourceRevision ?? previousObservedRevision
        let terminalChanged = snapshot.turns.values.contains { turn in
            turn.key.threadID == threadID
                && turn.lastChangedRevision > baseline
                && turn.status.isTerminal
        }
        if terminalChanged {
            diagnostics.terminalFlushCount &+= 1
        }

        let immediately = forceImmediate || terminalChanged
        if immediately {
            cancelProjection(clearPending: false)
            launchProjection(afterCoalescingDelay: false)
        } else if projectionTask == nil {
            launchProjection(afterCoalescingDelay: true)
        } else {
            diagnostics.coalescedChangeSetCount &+= max(1, changes.count)
        }
    }
}

// MARK: - Projection and publication

private extension CodexPresentationStore {
    struct ProjectionJob: Sendable {
        var threadID: ThreadID
        var snapshot: CanonicalStateSnapshot
        var requestBatch: CodexServerRequestSnapshotBatch
        var dirtyTurns: Set<TurnKey>
        var previous: CodexCanonicalTranscriptPresentation?
    }

    func launchProjection(afterCoalescingDelay: Bool) {
        guard projectionTask == nil, pendingSnapshot != nil else { return }
        projectionGeneration &+= 1
        let generation = projectionGeneration
        let delay = coalescingInterval
        diagnostics.projectionScheduleCount &+= 1

        projectionTask = Task { [weak self, projector] in
            if afterCoalescingDelay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let job = self?.takeProjectionJob() else { return }

            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return try projector.project(
                        snapshot: job.snapshot,
                        threadID: job.threadID,
                        requests: job.requestBatch.requests,
                        requestRevision: job.requestBatch.revision.rawValue,
                        dirtyTurns: job.dirtyTurns,
                        previous: job.previous
                    )
                } catch {
                    return projector.rebuild(
                        snapshot: job.snapshot,
                        threadID: job.threadID,
                        requests: job.requestBatch.requests,
                        requestRevision: job.requestBatch.revision.rawValue
                    )
                }
            }.value

            guard !Task.isCancelled else { return }
            self?.finishProjection(
                result,
                requestSnapshots: job.requestBatch.requests,
                generation: generation,
                threadID: job.threadID
            )
        }
    }

    func takeProjectionJob() -> ProjectionJob? {
        guard let threadID = selectedThreadID, let snapshot = pendingSnapshot else { return nil }
        let job = ProjectionJob(
            threadID: threadID,
            snapshot: snapshot,
            requestBatch: pendingRequestBatch,
            dirtyTurns: pendingDirtyTurns,
            previous: activeCanonicalPresentation
        )
        clearPendingProjection()
        return job
    }

    func finishProjection(
        _ result: CodexCanonicalTranscriptProjectionResult,
        requestSnapshots: [CodexServerRequestSnapshot],
        generation: UInt64,
        threadID: ThreadID
    ) {
        guard projectionGeneration == generation, selectedThreadID == threadID else {
            diagnostics.discardedProjectionCount &+= 1
            return
        }
        projectionTask = nil

        if let current = activeCanonicalPresentation,
           result.presentation.sourceRevision < current.sourceRevision {
            diagnostics.discardedProjectionCount &+= 1
        } else {
            publish(result, requestSnapshots: requestSnapshots, threadID: threadID)
        }

        if pendingSnapshot != nil {
            launchProjection(afterCoalescingDelay: true)
        }
    }

    func publish(
        _ result: CodexCanonicalTranscriptProjectionResult,
        requestSnapshots: [CodexServerRequestSnapshot],
        threadID: ThreadID
    ) {
        ensureLocalState(for: threadID)
        guard var local = localStateByThreadID[threadID] else { return }
        let presentedAt = now()
        for turn in result.presentation.transcript.turns
            where local.firstPresentedAtByTurnID[turn.id] == nil {
            local.firstPresentedAtByTurnID[turn.id] = presentedAt
        }
        local.lastSeenAttentionRevision = max(
            local.lastSeenAttentionRevision,
            result.presentation.sourceRevision
        )
        localStateByThreadID[threadID] = local

        let approvals = Self.approvalPrompts(
            requestSnapshots,
            threadID: threadID,
            createdAt: presentedAt
        )
        activeCanonicalPresentation = result.presentation
        activeRenderUpdate = result.update
        activePendingRequests = result.presentation.pendingRequests
        activePresentation = Self.presentation(
            threadID: threadID,
            transcript: result.presentation.transcript,
            localState: local,
            pendingApprovals: approvals
        )
        diagnostics.projectionPublishCount &+= 1
        presentationRevision &+= 1
    }

    func cancelProjection(clearPending: Bool = true) {
        projectionGeneration &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        if clearPending { clearPendingProjection() }
    }

    func clearPendingProjection() {
        pendingSnapshot = nil
        pendingRequestBatch = .init(revision: .zero, requests: [])
        pendingDirtyTurns = []
    }
}

// MARK: - UI-local state

private extension CodexPresentationStore {
    func ensureLocalState(for threadID: ThreadID) {
        guard localStateByThreadID[threadID] == nil else { return }
        localStateByThreadID[threadID] = .init()
        touch(threadID)
        evictLocalStateIfNeeded()
    }

    func touch(_ threadID: ThreadID) {
        leastToMostRecentThreadIDs.removeAll { $0 == threadID }
        leastToMostRecentThreadIDs.append(threadID)
    }

    func evictLocalStateIfNeeded() {
        while localStateByThreadID.count > Self.uiStateCapacity {
            guard let candidate = leastToMostRecentThreadIDs.first(where: {
                $0 != selectedThreadID
            }) else { return }
            localStateByThreadID.removeValue(forKey: candidate)
            leastToMostRecentThreadIDs.removeAll { $0 == candidate }
            diagnostics.uiStateEvictionCount &+= 1
        }
    }

    func refreshActiveLocalState() {
        guard let threadID = selectedThreadID,
              let local = localStateByThreadID[threadID],
              var presentation = activePresentation
        else { return }
        presentation.rawScrollOffset = local.rawScrollOffset
        presentation.isPinnedToBottom = local.isPinnedToBottom
        presentation.expandedWorkTurnIDs = local.expandedWorkTurnIDs
        presentation.expandedRowIDs = local.expandedRowIDs
        presentation.presentedAtByTurnID = local.firstPresentedAtByTurnID
        activePresentation = presentation
        presentationRevision &+= 1
    }

    static func presentation(
        threadID: ThreadID,
        transcript: CodexTranscriptV2,
        localState: CodexThreadPresentationLocalState,
        pendingApprovals: [CodexApprovalPrompt]
    ) -> CodexThreadUIPresentation {
        CodexThreadUIPresentation(
            threadID: threadID.rawValue,
            transcript: transcript,
            rawScrollOffset: localState.rawScrollOffset,
            isPinnedToBottom: localState.isPinnedToBottom,
            expandedWorkTurnIDs: localState.expandedWorkTurnIDs,
            expandedRowIDs: localState.expandedRowIDs,
            presentedAtByTurnID: localState.firstPresentedAtByTurnID,
            pendingApprovals: pendingApprovals
        )
    }

    static func latestAttentionRevision(
        threadID: ThreadID,
        snapshot: CanonicalStateSnapshot?,
        requests: [CodexServerRequestSnapshot],
        fallback: StateRevision = .zero
    ) -> StateRevision {
        guard let snapshot else { return fallback }
        var revision = snapshot.threads[threadID]?.lastChangedRevision ?? fallback
        for turn in snapshot.turns.values where turn.key.threadID == threadID {
            revision = max(revision, turn.lastChangedRevision)
        }
        for item in snapshot.items.values where item.key.threadID == threadID {
            revision = max(revision, item.lastChangedRevision)
        }
        for intent in snapshot.submissionIntents.values where intent.threadID == threadID {
            revision = max(revision, intent.lastChangedRevision)
        }
        for request in requests
            where request.isPending && request.scope.threadID == threadID.rawValue {
            revision = max(revision, StateRevision(request.registeredRevision))
        }
        return revision
    }

    static func approvalPrompts(
        _ requests: [CodexServerRequestSnapshot],
        threadID: ThreadID,
        createdAt: Date
    ) -> [CodexApprovalPrompt] {
        requests.compactMap { request in
            guard request.isPending, request.scope.threadID == threadID.rawValue else { return nil }
            let content: (CodexApprovalPromptKind, String, String)
            switch request.kind {
            case .commandApproval:
                content = (.command, "Approve command?", "Codex wants to run a command.")
            case .fileChangeApproval:
                content = (.fileChange, "Approve file change?", "Codex wants to edit files.")
            case .permissionsApproval:
                content = (.permissions, "Grant permissions?", "Codex needs additional permissions.")
            case .legacyApplyPatchApproval:
                content = (.applyPatch, "Approve patch?", "Codex wants to apply a patch.")
            case .legacyExecCommandApproval:
                content = (.execCommand, "Approve command?", "Codex wants to run a command.")
            default:
                return nil
            }

            return CodexApprovalPrompt(
                id: request.key,
                method: request.method,
                kind: content.0,
                title: content.1,
                detail: content.2,
                threadId: request.scope.threadID,
                turnId: request.scope.turnID,
                itemId: request.scope.itemID,
                approvalId: request.approvalCorrelation?.approvalID,
                createdAt: createdAt
            )
        }
    }
}
