import CodexCore
import Foundation
import Observation

/// A stateless seam between `CodexSession` and presentation projection.
///
/// Every closure must forward to the same actor-owned canonical state engine.
/// In particular, `observe` must return its atomic seed/stream pair; this adapter
/// must never take its own snapshot and then subscribe separately.
public struct CodexPresentationStateAdapter: Sendable {
    public typealias Observe = @Sendable (
        StateObservationScope
    ) async -> StateSnapshotObservation<CodexSessionStateSnapshot>
    public typealias Cancel = @Sendable (StateObservationID) async -> Void
    public typealias CurrentSnapshot = @Sendable (
        StateObservationScope
    ) async -> CodexSessionStateSnapshot

    private let observeClosure: Observe
    private let cancelClosure: Cancel
    private let currentSnapshotClosure: CurrentSnapshot

    public init(
        observe: @escaping Observe,
        cancel: @escaping Cancel,
        currentSnapshot: @escaping CurrentSnapshot
    ) {
        self.observeClosure = observe
        self.cancelClosure = cancel
        self.currentSnapshotClosure = currentSnapshot
    }

    fileprivate func observe(
        scope: StateObservationScope
    ) async -> StateSnapshotObservation<CodexSessionStateSnapshot> {
        await observeClosure(scope)
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
    public var selectedDiffFileIndexByRowID: [String: Int]
    public var editingMessageID: String?
    public var editingMessageText: String
    public var bookmarkedTurnIDs: Set<String>
    public var outputBadgesByTurnID: [String: String]
    public var firstPresentedAtByTurnID: [String: Date]
    public var lastSeenAttentionRevision: StateRevision

    public init(
        rawScrollOffset: CGFloat = 0,
        isPinnedToBottom: Bool = true,
        expandedWorkTurnIDs: Set<String> = [],
        expandedRowIDs: Set<String> = [],
        selectedDiffFileIndexByRowID: [String: Int] = [:],
        editingMessageID: String? = nil,
        editingMessageText: String = "",
        bookmarkedTurnIDs: Set<String> = [],
        outputBadgesByTurnID: [String: String] = [:],
        firstPresentedAtByTurnID: [String: Date] = [:],
        lastSeenAttentionRevision: StateRevision = .zero
    ) {
        self.rawScrollOffset = rawScrollOffset
        self.isPinnedToBottom = isPinnedToBottom
        self.expandedWorkTurnIDs = expandedWorkTurnIDs
        self.expandedRowIDs = expandedRowIDs
        self.selectedDiffFileIndexByRowID = selectedDiffFileIndexByRowID
        self.editingMessageID = editingMessageID
        self.editingMessageText = editingMessageText
        self.bookmarkedTurnIDs = bookmarkedTurnIDs
        self.outputBadgesByTurnID = outputBadgesByTurnID
        self.firstPresentedAtByTurnID = firstPresentedAtByTurnID
        self.lastSeenAttentionRevision = lastSeenAttentionRevision
    }
}

public struct CodexPresentationStoreDiagnostics: Sendable, Equatable {
    public fileprivate(set) var invalidSnapshotCount = 0
    public fileprivate(set) var receivedSignalCount = 0
    public fileprivate(set) var projectionScheduleCount = 0
    public fileprivate(set) var projectionPublishCount = 0
    public fileprivate(set) var coalescedProjectionCount = 0
    public fileprivate(set) var terminalFlushCount = 0
    public fileprivate(set) var discardedProjectionCount = 0
    public fileprivate(set) var uiStateEvictionCount = 0
    public fileprivate(set) var presentationCacheHitCount = 0
    public fileprivate(set) var presentationCacheMissCount = 0
    public fileprivate(set) var deferredIncompleteHistoryCount = 0
    public fileprivate(set) var attentionRevisionCacheMissCount = 0

    public init() {}
}

/// Main-actor presentation state derived from `CodexSession`'s canonical graph.
///
/// Canonical snapshots and projected transcripts are disposable caches. The
/// bounded per-thread dictionaries retain UI state and recent projections; no
/// wire event is reduced here and no second protocol truth exists in this type.
@MainActor
@Observable
public final class CodexPresentationStore {
    public static let uiStateCapacity = 20

    public private(set) var selectedThreadID: ThreadID?
    public private(set) var activePresentation: CodexThreadUIPresentation?
    public private(set) var activeCanonicalPresentation: CodexCanonicalTranscriptPresentation?
    public private(set) var activeRenderUpdate: CodexCanonicalTranscriptRenderUpdate?
    public private(set) var activePendingRequests: [CodexTranscriptRequestPresentation] = []
    public private(set) var observedRevision: StateRevision = .zero
    public private(set) var presentationRevision = 0
    public private(set) var isSelectionHydrated = true
    public private(set) var diagnostics = CodexPresentationStoreDiagnostics()

    @ObservationIgnored private let coalescingInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let projector: CodexCanonicalTranscriptProjector
    @ObservationIgnored private var adapter: CodexPresentationStateAdapter?
    @ObservationIgnored private var localStateByThreadID: [ThreadID: CodexThreadPresentationLocalState] = [:]
    @ObservationIgnored private var presentationCacheByThreadID: [
        ThreadID: CachedThreadPresentation
    ] = [:]
    @ObservationIgnored private var warmCacheIneligibleThreadIDs: Set<ThreadID> = []
    @ObservationIgnored private var leastToMostRecentThreadIDs: [ThreadID] = []
    @ObservationIgnored private var latestSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var latestAttentionRevisionByThreadID: [
        ThreadID: StateRevision
    ] = [:]
    @ObservationIgnored private var latestRequestBatch = CodexPendingInteractionSnapshotBatch(
        revision: .zero,
        requests: []
    )
    @ObservationIgnored private var pendingSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var pendingRequestBatch = CodexPendingInteractionSnapshotBatch(
        revision: .zero,
        requests: []
    )
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private var projectionGeneration: UInt64 = 0

    private struct CachedThreadPresentation {
        var canonical: CodexCanonicalTranscriptPresentation
        var renderUpdate: CodexCanonicalTranscriptRenderUpdate
        var pendingRequests: [CodexTranscriptRequestPresentation]
        var approvals: [CodexApprovalPrompt]
    }

    public init(
        adapter: CodexPresentationStateAdapter? = nil,
        itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2? = nil,
        coalescingInterval: Duration = .milliseconds(17),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.projector = CodexCanonicalTranscriptProjector(
            itemPresentationPolicy: itemPresentationPolicy
        )
        self.coalescingInterval = coalescingInterval
        self.now = now
    }

    deinit {
        observationTask?.cancel()
        projectionTask?.cancel()
    }

    /// Attaches a stateless adapter. Observation begins when a thread is selected.
    public func connect(_ adapter: CodexPresentationStateAdapter) {
        resetPresentationForAdapterReplacement()
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
        presentationCacheByThreadID.removeAll(keepingCapacity: true)
        warmCacheIneligibleThreadIDs.removeAll(keepingCapacity: true)
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
        latestAttentionRevisionByThreadID.removeAll(keepingCapacity: true)
        activeCanonicalPresentation = nil
        activeRenderUpdate = nil
        activePendingRequests = []
        isSelectionHydrated = threadID == nil
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
        if let cached = presentationCacheByThreadID[threadID] {
            activeCanonicalPresentation = cached.canonical
            activeRenderUpdate = cached.renderUpdate
            activePendingRequests = cached.pendingRequests
            activePresentation = Self.presentation(
                threadID: threadID,
                transcript: cached.canonical.transcript,
                localState: local,
                pendingApprovals: cached.approvals
            )
            isSelectionHydrated = true
            diagnostics.presentationCacheHitCount &+= 1
        } else {
            activePresentation = Self.presentation(
                threadID: threadID,
                transcript: .init(),
                localState: local,
                pendingApprovals: []
            )
            diagnostics.presentationCacheMissCount &+= 1
        }
        presentationRevision &+= 1
        restartObservation()
    }

    public func localState(for threadID: ThreadID) -> CodexThreadPresentationLocalState? {
        localStateByThreadID[threadID]
    }

    public func containsLocalState(for threadID: ThreadID) -> Bool {
        localStateByThreadID[threadID] != nil
    }

    public func containsCachedPresentation(for threadID: ThreadID) -> Bool {
        presentationCacheByThreadID[threadID] != nil
    }

    public func hasUnreadAttention(for threadID: ThreadID) -> Bool {
        guard let local = localStateByThreadID[threadID],
              let snapshot = latestSnapshot
        else { return false }
        return local.lastSeenAttentionRevision < cachedLatestAttentionRevision(
            threadID: threadID,
            snapshot: snapshot,
            requests: latestRequestBatch.requests,
            requestRevision: latestRequestBatch.revision
        )
    }

    public func markSeen(threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.lastSeenAttentionRevision = cachedLatestAttentionRevision(
            threadID: threadID,
            snapshot: latestSnapshot,
            requests: latestRequestBatch.requests,
            requestRevision: latestRequestBatch.revision,
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
        // Scrolling is owned live by the AppKit transcript coordinator and can
        // update every frame. Persist it for restoration without republishing
        // the observable presentation and feeding the scroll event back through
        // SwiftUI's NSViewRepresentable update/layout path.
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

    public func selectDiffFile(index: Int, rowID: String, threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.selectedDiffFileIndexByRowID[rowID] = max(0, index)
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    /// Starts an inline edit without changing canonical transcript content.
    public func beginEditingMessage(
        messageID: String,
        text: String,
        threadID: ThreadID
    ) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.editingMessageID = messageID
        local.editingMessageText = text
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    public func updateEditingMessageText(_ text: String, threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID], local.editingMessageID != nil else { return }
        local.editingMessageText = text
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    @discardableResult
    public func commitEditingMessage(threadID: ThreadID) -> String? {
        guard var local = localStateByThreadID[threadID], local.editingMessageID != nil else { return nil }
        let text = local.editingMessageText
        local.editingMessageID = nil
        local.editingMessageText = ""
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
        return text
    }

    public func cancelEditingMessage(threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        local.editingMessageID = nil
        local.editingMessageText = ""
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
    }

    @discardableResult
    public func toggleBookmark(turnID: String, threadID: ThreadID) -> Bool {
        guard var local = localStateByThreadID[threadID] else { return false }
        if local.bookmarkedTurnIDs.contains(turnID) {
            local.bookmarkedTurnIDs.remove(turnID)
        } else {
            local.bookmarkedTurnIDs.insert(turnID)
        }
        localStateByThreadID[threadID] = local
        if selectedThreadID == threadID { refreshActiveLocalState() }
        touch(threadID)
        return local.bookmarkedTurnIDs.contains(turnID)
    }

    public func setOutputBadge(_ badge: String?, turnID: String, threadID: ThreadID) {
        guard var local = localStateByThreadID[threadID] else { return }
        if let badge = badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            local.outputBadgesByTurnID[turnID] = String(badge.prefix(120))
        } else {
            local.outputBadgesByTurnID.removeValue(forKey: turnID)
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
        latestAttentionRevisionByThreadID.removeValue(forKey: threadID)
        presentationCacheByThreadID.removeValue(forKey: threadID)
        warmCacheIneligibleThreadIDs.remove(threadID)
        leastToMostRecentThreadIDs.removeAll { $0 == threadID }
        if selectedThreadID == threadID { select(threadID: nil) }
    }

    public func resetLocalState() {
        select(threadID: nil)
        localStateByThreadID.removeAll(keepingCapacity: false)
        presentationCacheByThreadID.removeAll(keepingCapacity: false)
        warmCacheIneligibleThreadIDs.removeAll(keepingCapacity: false)
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

    /// Adapter revisions are independent domains. Drop every selected-thread
    /// baseline before observing the replacement so a lower revision can seed
    /// it and no projection launched by the old adapter can publish afterward.
    func resetPresentationForAdapterReplacement() {
        presentationCacheByThreadID.removeAll(keepingCapacity: true)
        warmCacheIneligibleThreadIDs.removeAll(keepingCapacity: true)
        cancelProjection()
        latestSnapshot = nil
        latestRequestBatch = .init(revision: .zero, requests: [])
        latestAttentionRevisionByThreadID.removeAll(keepingCapacity: true)
        observedRevision = .zero
        activeCanonicalPresentation = nil
        activeRenderUpdate = nil
        activePendingRequests = []
        isSelectionHydrated = selectedThreadID == nil

        guard let threadID = selectedThreadID else {
            activePresentation = nil
            return
        }
        var local = localStateByThreadID[threadID] ?? .init()
        local.lastSeenAttentionRevision = .zero
        localStateByThreadID[threadID] = local
        activePresentation = Self.presentation(
            threadID: threadID,
            transcript: .init(),
            localState: local,
            pendingApprovals: []
        )
        presentationRevision &+= 1
    }

    func restartObservation() {
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil

        guard let adapter, let threadID = selectedThreadID else { return }
        let generation = observationGeneration
        let scope = StateObservationScope.thread(threadID, fields: Self.presentationFields)

        observationTask = Task { [weak self, adapter] in
            let observation = await adapter.observe(scope: scope)
            defer {
                Task { await adapter.cancel(observationID: observation.id) }
            }
            guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                return
            }

            guard observation.seed.stateRevision == observation.revision,
                  observation.seed.canonical.revision == observation.revision
            else {
                self?.noteInvalidSnapshot()
                return
            }

            self?.accept(
                sessionSnapshot: observation.seed,
                forceImmediate: true
            )

            for await signal in observation.signals {
                guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                    return
                }
                let snapshot = await adapter.currentSnapshot(scope: scope)
                guard self?.isCurrentObservation(generation: generation, threadID: threadID) == true else {
                    return
                }
                guard snapshot.stateRevision >= signal.latestRevision,
                      snapshot.canonical.revision == snapshot.stateRevision
                else {
                    self?.noteInvalidSnapshot()
                    continue
                }
                self?.noteReceivedSignal()
                self?.accept(
                    sessionSnapshot: snapshot,
                    forceImmediate: false
                )
            }
        }
    }

    func isCurrentObservation(generation: UInt64, threadID: ThreadID) -> Bool {
        !Task.isCancelled
            && observationGeneration == generation
            && selectedThreadID == threadID
    }

    func noteInvalidSnapshot() {
        diagnostics.invalidSnapshotCount &+= 1
    }

    func noteReceivedSignal() {
        diagnostics.receivedSignalCount &+= 1
    }

    func accept(
        sessionSnapshot: CodexSessionStateSnapshot,
        forceImmediate: Bool
    ) {
        guard let threadID = selectedThreadID else { return }
        let snapshot = sessionSnapshot.canonical
        let requestBatch = sessionSnapshot.serverRequests
        let previousObservedRevision = observedRevision
        observedRevision = sessionSnapshot.stateRevision
        latestSnapshot = snapshot
        latestRequestBatch = requestBatch
        latestAttentionRevisionByThreadID.removeAll(keepingCapacity: true)
        let containsSelectedThread = snapshot.threads[threadID] != nil
            || snapshot.turns.keys.contains(where: { $0.threadID == threadID })
        guard containsSelectedThread else {
            clearPendingProjection()
            return
        }
        guard Self.hasDisplayableHistory(snapshot, threadID: threadID) else {
            diagnostics.deferredIncompleteHistoryCount &+= 1
            clearPendingProjection()
            return
        }
        pendingSnapshot = snapshot
        pendingRequestBatch = requestBatch

        let baseline = activeCanonicalPresentation?.sourceRevision
            ?? previousObservedRevision
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
            diagnostics.coalescedProjectionCount &+= 1
        }
    }

    /// A resume may first install a metadata-only thread shell whose history is
    /// explicitly not loaded. That shell is not an empty transcript: publishing
    /// it would erase a warm cached presentation until the first history page
    /// arrives. Full coverage is authoritative even when it contains zero turns.
    static func hasDisplayableHistory(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> Bool {
        if snapshot.threads[threadID]?.history.turnsCoverage == .full {
            return true
        }
        if snapshot.turns.keys.contains(where: { $0.threadID == threadID }) {
            return true
        }
        return snapshot.submissionIntents.values.contains { intent in
            guard intent.threadID == threadID else { return false }
            if case .reconciled = intent.state { return false }
            return true
        }
    }
}

private extension CodexTurnV2 {
    var containsFileChangeRow: Bool {
        narrative.contains(where: \.containsFileChangeRow)
            || conversationSegments.contains { segment in
                segment.narrative.contains(where: \.containsFileChangeRow)
            }
    }
}

private extension CodexNarrativeEntry {
    var containsFileChangeRow: Bool {
        guard case .workGroup(let group) = self else { return false }
        return group.rows.contains { row in
            if case .fileChange = row { true } else { false }
        }
    }
}

// MARK: - Projection and publication

private extension CodexPresentationStore {
    struct ProjectionJob: Sendable {
        var threadID: ThreadID
        var snapshot: CanonicalStateSnapshot
        var requestBatch: CodexPendingInteractionSnapshotBatch
        var previous: CodexCanonicalTranscriptPresentation?
    }

    struct CompletedProjection: Sendable {
        var result: CodexCanonicalTranscriptProjectionResult
        var excludesWarmCache: Bool
    }

    func launchProjection(afterCoalescingDelay: Bool) {
        guard projectionTask == nil, pendingSnapshot != nil else { return }
        projectionGeneration &+= 1
        let generation = projectionGeneration
        let delay = coalescingInterval
        diagnostics.projectionScheduleCount &+= 1

        projectionTask = Task(priority: .userInitiated) { [weak self, projector] in
            if afterCoalescingDelay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let job = self?.takeProjectionJob() else { return }

            let completed: CompletedProjection
            do {
                completed = try await Self.performProjection(
                    job,
                    projector: projector
                )
            } catch is CancellationError {
                return
            } catch {
                self?.abandonProjection(
                    generation: generation,
                    threadID: job.threadID
                )
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishProjection(
                completed.result,
                excludesWarmCache: completed.excludesWarmCache,
                requestSnapshots: job.requestBatch.requests,
                generation: generation,
                threadID: job.threadID
            )
        }
    }

    @concurrent
    nonisolated static func performProjection(
        _ job: ProjectionJob,
        projector: CodexCanonicalTranscriptProjector
    ) async throws -> CompletedProjection {
        try Task.checkCancellation()
        let result: CodexCanonicalTranscriptProjectionResult
        do {
            result = try projector.project(
                snapshot: job.snapshot,
                threadID: job.threadID,
                requests: job.requestBatch.requests,
                requestRevision: job.requestBatch.revision.rawValue,
                previous: job.previous
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexCanonicalTranscriptProjectionError {
            switch error {
            case .staleSourceRevision, .staleRequestRevision:
                break
            }
            try Task.checkCancellation()
            result = try projector.project(
                snapshot: job.snapshot,
                threadID: job.threadID,
                requests: job.requestBatch.requests,
                requestRevision: job.requestBatch.revision.rawValue,
                previous: nil
            )
        }
        try Task.checkCancellation()
        return CompletedProjection(
            result: result,
            excludesWarmCache: result.update.upsertedTurns.contains {
                $0.containsFileChangeRow
            }
        )
    }

    func takeProjectionJob() -> ProjectionJob? {
        guard let threadID = selectedThreadID, let snapshot = pendingSnapshot else { return nil }
        let job = ProjectionJob(
            threadID: threadID,
            snapshot: snapshot,
            requestBatch: pendingRequestBatch,
            previous: activeCanonicalPresentation
        )
        clearPendingProjection()
        return job
    }

    func finishProjection(
        _ result: CodexCanonicalTranscriptProjectionResult,
        excludesWarmCache: Bool,
        requestSnapshots: [CodexPendingInteractionSnapshot],
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
            publish(
                result,
                excludesWarmCache: excludesWarmCache,
                requestSnapshots: requestSnapshots,
                threadID: threadID
            )
        }

        if pendingSnapshot != nil {
            launchProjection(afterCoalescingDelay: true)
        }
    }

    func abandonProjection(generation: UInt64, threadID: ThreadID) {
        guard projectionGeneration == generation, selectedThreadID == threadID else {
            return
        }
        projectionTask = nil
        diagnostics.discardedProjectionCount &+= 1
        if pendingSnapshot != nil {
            launchProjection(afterCoalescingDelay: true)
        }
    }

    func publish(
        _ result: CodexCanonicalTranscriptProjectionResult,
        excludesWarmCache: Bool,
        requestSnapshots: [CodexPendingInteractionSnapshot],
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
        if excludesWarmCache {
            warmCacheIneligibleThreadIDs.insert(threadID)
        }
        if warmCacheIneligibleThreadIDs.contains(threadID) {
            presentationCacheByThreadID.removeValue(forKey: threadID)
        } else {
            presentationCacheByThreadID[threadID] = CachedThreadPresentation(
                canonical: result.presentation,
                renderUpdate: result.update,
                pendingRequests: result.presentation.pendingRequests,
                approvals: approvals
            )
        }
        touch(threadID)
        isSelectionHydrated = true
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
            latestAttentionRevisionByThreadID.removeValue(forKey: candidate)
            presentationCacheByThreadID.removeValue(forKey: candidate)
            warmCacheIneligibleThreadIDs.remove(candidate)
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
        presentation.selectedDiffFileIndexByRowID = local.selectedDiffFileIndexByRowID
        presentation.editingMessageID = local.editingMessageID
        presentation.editingMessageText = local.editingMessageText
        presentation.bookmarkedTurnIDs = local.bookmarkedTurnIDs
        presentation.outputBadgesByTurnID = local.outputBadgesByTurnID
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
            selectedDiffFileIndexByRowID: localState.selectedDiffFileIndexByRowID,
            editingMessageID: localState.editingMessageID,
            editingMessageText: localState.editingMessageText,
            bookmarkedTurnIDs: localState.bookmarkedTurnIDs,
            outputBadgesByTurnID: localState.outputBadgesByTurnID,
            presentedAtByTurnID: localState.firstPresentedAtByTurnID,
            pendingApprovals: pendingApprovals
        )
    }

    static func latestAttentionRevision(
        threadID: ThreadID,
        snapshot: CanonicalStateSnapshot?,
        requests: [CodexPendingInteractionSnapshot],
        requestRevision: StateRevision,
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
        if requests.contains(where: { $0.scope.threadID == threadID.rawValue }) {
            revision = max(revision, requestRevision)
        }
        return revision
    }

    func cachedLatestAttentionRevision(
        threadID: ThreadID,
        snapshot: CanonicalStateSnapshot?,
        requests: [CodexPendingInteractionSnapshot],
        requestRevision: StateRevision,
        fallback: StateRevision = .zero
    ) -> StateRevision {
        guard snapshot != nil else { return fallback }
        if let cached = latestAttentionRevisionByThreadID[threadID] {
            return cached
        }
        diagnostics.attentionRevisionCacheMissCount &+= 1
        let revision = Self.latestAttentionRevision(
            threadID: threadID,
            snapshot: snapshot,
            requests: requests,
            requestRevision: requestRevision,
            fallback: fallback
        )
        latestAttentionRevisionByThreadID[threadID] = revision
        return revision
    }

    static func approvalPrompts(
        _ requests: [CodexPendingInteractionSnapshot],
        threadID: ThreadID,
        createdAt: Date
    ) -> [CodexApprovalPrompt] {
        requests.compactMap { request in
            guard request.scope.threadID == threadID.rawValue else { return nil }
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
