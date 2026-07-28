import CodexCore
import Foundation
import Observation

public struct CodexSubagentPresentationDiagnostics: Sendable, Equatable {
    public fileprivate(set) var parentSnapshotCount = 0
    public fileprivate(set) var indexSnapshotCount = 0
    public fileprivate(set) var childLeaseAcquisitionCount = 0
    public fileprivate(set) var childLeaseReleaseCount = 0
    public fileprivate(set) var childProjectionCount = 0
    public fileprivate(set) var childProjectionScheduleCount = 0
    public fileprivate(set) var childProjectionDiscardCount = 0
    public fileprivate(set) var childSnapshotCoalescingCount = 0
    public fileprivate(set) var projectionEvictionCount = 0

    public init() {}
}

private struct CodexCompletedChildProjection: Sendable {
    var result: CodexCanonicalTranscriptProjectionResult
    var transcript: CodexTranscriptV2
    var retentionMetrics: CodexCanonicalTranscriptRetentionMetrics
    var isTerminalAndHydrated: Bool
}

private struct CodexPendingChildProjection: Sendable {
    var snapshot: CanonicalStateSnapshot
    var summary: CodexSubagentChildSnapshotSummary
}

/// Canonical coordinator for direct child-agent presentation.
///
/// The selected parent is observed only for collaboration items. Direct child
/// relationships and names also arrive through the lightweight thread index.
/// Each child receives its own exact retention lease and scoped observation;
/// no `.all` canonical graph is copied into UI and no notification is replayed.
@MainActor
@Observable
public final class CodexSubagentPresentationCoordinator {
    public static let defaultProjectionCapacity = 8
    public static let defaultProjectionByteCapacity = 8 * 1_024 * 1_024

    public private(set) var parentThreadID: ThreadID?
    public private(set) var agents: [CodexSubagentV2] = []
    public private(set) var panelSubagents: [CodexSubagentState] = []
    public private(set) var lifecycleEvents: [CodexAgentLifecycleEvent] = []
    public private(set) var changeRevision: UInt64 = 0
    public private(set) var diagnostics = CodexSubagentPresentationDiagnostics()

    @ObservationIgnored private let codex: Codex
    @ObservationIgnored private let projectionCapacity: Int
    @ObservationIgnored private let projectionByteCapacity: Int
    @ObservationIgnored private let projectionOperation: @Sendable (
        CanonicalStateSnapshot,
        ThreadID,
        CodexCanonicalTranscriptPresentation?
    ) -> CodexCanonicalTranscriptProjectionResult
    @ObservationIgnored private var store = CodexSubagentStoreV2()
    @ObservationIgnored private var mapper = CodexAgentStateMapper()
    @ObservationIgnored private var latestParentSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var parentDiscoveredIDs: Set<ThreadID> = []
    @ObservationIgnored private var indexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var seenIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var removedIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var terminalChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var projectionLRU: [ThreadID] = []
    @ObservationIgnored private var suppressedProjectionThreadIDs: Set<ThreadID> = []
    @ObservationIgnored private var demandedProjectionThreadID: ThreadID?
    @ObservationIgnored private var childRuntimes: [ThreadID: ChildRuntime] = [:]
    @ObservationIgnored private var parentObservationTask: Task<Void, Never>?
    @ObservationIgnored private var indexObservationTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var nextProjectionID: UInt64 = 0

    private struct ChildRuntime {
        var generation: UInt64
        var lease: CodexThreadLease?
        var observationTask: Task<Void, Never>?
        var projectionTask: Task<Void, Never>?
        var projectionID: UInt64?
        var latestSnapshotRevision: StateRevision?
        var pendingProjection: CodexPendingChildProjection?
    }

    public init(
        codex: Codex,
        projectionCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionCapacity,
        projectionByteCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionByteCapacity
    ) {
        self.codex = codex
        self.projectionCapacity = max(1, projectionCapacity)
        self.projectionByteCapacity = max(0, projectionByteCapacity)
        self.projectionOperation = CodexSubagentStoreV2.projectChildSnapshot
    }

    init(
        codex: Codex,
        projectionCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionCapacity,
        projectionByteCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionByteCapacity,
        projectionOperation: @escaping @Sendable (
            CanonicalStateSnapshot,
            ThreadID,
            CodexCanonicalTranscriptPresentation?
        ) -> CodexCanonicalTranscriptProjectionResult
    ) {
        self.codex = codex
        self.projectionCapacity = max(1, projectionCapacity)
        self.projectionByteCapacity = max(0, projectionByteCapacity)
        self.projectionOperation = projectionOperation
    }

    deinit {
        parentObservationTask?.cancel()
        indexObservationTask?.cancel()
        for runtime in childRuntimes.values {
            runtime.observationTask?.cancel()
            runtime.projectionTask?.cancel()
        }
    }

    /// Switches the direct-parent scope. Old child tasks are cancelled
    /// immediately and their leases are released asynchronously.
    public func selectParent(_ threadID: ThreadID?) {
        guard parentThreadID != threadID else { return }
        generation &+= 1
        let outgoing = Array(childRuntimes.values.compactMap(\.lease))
        cancelObservationTasks()
        childRuntimes.removeAll(keepingCapacity: false)
        clearProjectionState()
        parentThreadID = threadID

        if !outgoing.isEmpty {
            diagnostics.childLeaseReleaseCount += outgoing.count
            Task {
                for lease in outgoing { await lease.close() }
            }
        }
        guard let threadID else {
            publish()
            return
        }
        startParentObservation(threadID: threadID, generation: generation)
        startIndexObservation(parentThreadID: threadID, generation: generation)
    }

    /// Deterministically releases every child lease and stops observing.
    public func disconnect() async {
        generation &+= 1
        parentThreadID = nil
        cancelObservationTasks()
        let leases = Array(childRuntimes.values.compactMap(\.lease))
        childRuntimes.removeAll(keepingCapacity: false)
        diagnostics.childLeaseReleaseCount += leases.count
        for lease in leases { await lease.close() }
        clearProjectionState()
        publish()
    }

    public func reset() async {
        await disconnect()
        diagnostics = .init()
    }

    public func agent(threadID: ThreadID) -> CodexSubagentV2? {
        store.agent(threadID: threadID.rawValue)
    }

    public var retainedProjectionEstimatedByteCount: Int {
        store.retainedProjectionEstimatedByteCount
    }

    /// Selects the child transcript that is currently visible in the agent panel.
    ///
    /// Selection is the only demand signal that can reacquire a projection
    /// suppressed by the retention limits. Repeating the same selection is a
    /// no-op so an oversized projection cannot rebuild/evict in a loop.
    func selectTranscript(_ threadID: ThreadID?) {
        guard demandedProjectionThreadID != threadID else { return }
        demandedProjectionThreadID = threadID
        guard let threadID,
              store.contains(threadID: threadID.rawValue)
        else {
            publish()
            return
        }

        suppressedProjectionThreadIDs.remove(threadID)
        let didEvict = touchProjection(threadID, protecting: threadID)
        let transcript = store.agent(threadID: threadID.rawValue)?.transcript
        if transcript?.turns.isEmpty == true,
           childRuntimes[threadID] == nil,
           let parentThreadID {
            terminalChildIDs.remove(threadID)
            acquireChild(threadID, parentThreadID: parentThreadID, generation: generation)
        }
        if didEvict {
            refreshMapperAndPublish()
        } else {
            publish()
        }
    }

    /// Returns the currently cached child transcript and marks it as selected.
    public func transcript(threadID: ThreadID) -> CodexTranscriptV2? {
        guard store.contains(threadID: threadID.rawValue) else { return nil }
        selectTranscript(threadID)
        return store.agent(threadID: threadID.rawValue)?.transcript
    }
}

// MARK: - Parent and index observation

private extension CodexSubagentPresentationCoordinator {
    func startParentObservation(threadID: ThreadID, generation: UInt64) {
        let codex = self.codex
        parentObservationTask = Task { [weak self] in
            let fields: StateFieldMask = [
                .threadMetadata,
                .turnStructure,
                .turnStatus,
                .itemStructure,
                .itemLifecycle,
                .itemContent,
            ]
            let observation = await codex.session.observeSessionState(
                scope: .thread(threadID, fields: fields)
            )
            defer {
                Task { await codex.session.cancelObservation(observation.id) }
            }
            guard let self, self.isCurrent(generation, parentThreadID: threadID) else { return }
            self.applyParentSnapshot(observation.seed.canonical, parentThreadID: threadID)

            for await _ in observation.signals {
                guard !Task.isCancelled,
                      self.isCurrent(generation, parentThreadID: threadID) else { return }
                let snapshot = await codex.session.canonicalSnapshot(
                    scope: .thread(threadID, fields: fields)
                )
                self.applyParentSnapshot(snapshot, parentThreadID: threadID)
            }
        }
    }

    func startIndexObservation(parentThreadID: ThreadID, generation: UInt64) {
        let codex = self.codex
        indexObservationTask = Task { [weak self] in
            let observation = await codex.session.observeThreadIndex()
            defer {
                Task { await codex.session.cancelObservation(observation.id) }
            }
            guard let self, self.isCurrent(generation, parentThreadID: parentThreadID) else { return }
            self.applyThreadIndex(observation.seed, parentThreadID: parentThreadID)

            for await _ in observation.signals {
                guard !Task.isCancelled,
                      self.isCurrent(generation, parentThreadID: parentThreadID) else { return }
                self.applyThreadIndex(
                    await codex.session.threadIndexSnapshot(),
                    parentThreadID: parentThreadID
                )
            }
        }
    }

    func applyParentSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        parentThreadID: ThreadID
    ) {
        guard isCurrent(generation, parentThreadID: parentThreadID) else { return }
        latestParentSnapshot = snapshot
        let discoveries = store.applyParentSnapshot(snapshot, parentThreadID: parentThreadID)
        parentDiscoveredIDs = Set(discoveries.map { ThreadID($0.threadID) })
        diagnostics.parentSnapshotCount += 1
        reconcileChildren(parentThreadID: parentThreadID)
        releaseClosedChildren()
        refreshMapperAndPublish()
    }

    func applyThreadIndex(
        _ index: CanonicalThreadIndexSnapshot,
        parentThreadID: ThreadID
    ) {
        guard isCurrent(generation, parentThreadID: parentThreadID) else { return }
        let discoveries = store.applyThreadIndex(index, parentThreadID: parentThreadID)
        indexedChildIDs = Set(discoveries.map { ThreadID($0.threadID) })
        seenIndexedChildIDs.formUnion(indexedChildIDs)
        removedIndexedChildIDs = seenIndexedChildIDs.subtracting(indexedChildIDs)
        for summary in index.threads where summary.parentThreadID == parentThreadID {
            if summary.status.isActive || summary.latestTurnStatus == .inProgress {
                terminalChildIDs.remove(summary.id)
            }
        }
        diagnostics.indexSnapshotCount += 1
        reconcileChildren(parentThreadID: parentThreadID)
        refreshMapperAndPublish()
    }
}

// MARK: - Exact child leases and scoped projections

private extension CodexSubagentPresentationCoordinator {
    var desiredChildIDs: Set<ThreadID> {
        parentDiscoveredIDs.subtracting(removedIndexedChildIDs).union(indexedChildIDs)
    }

    func reconcileChildren(parentThreadID: ThreadID) {
        let desired = desiredChildIDs
        for id in Array(childRuntimes.keys) where !desired.contains(id) {
            releaseAndRemoveChild(id)
        }
        for id in store.threadIDs where !desired.contains(id) {
            store.remove(threadID: id)
            projectionLRU.removeAll { $0 == id }
            suppressedProjectionThreadIDs.remove(id)
            if demandedProjectionThreadID == id {
                demandedProjectionThreadID = nil
            }
        }
        for id in desired
        where childRuntimes[id] == nil
            && !terminalChildIDs.contains(id)
            && !suppressedProjectionThreadIDs.contains(id) {
            acquireChild(id, parentThreadID: parentThreadID, generation: generation)
        }
    }

    func acquireChild(
        _ threadID: ThreadID,
        parentThreadID: ThreadID,
        generation: UInt64
    ) {
        guard childRuntimes[threadID] == nil else { return }
        let codex = self.codex
        let observationTask = Task { [weak self] in
            let lease = await codex.retainThread(
                threadID,
                reason: .subagentObserver(parentThreadID)
            )
            guard let self,
                  self.isCurrent(generation, parentThreadID: parentThreadID),
                  self.desiredChildIDs.contains(threadID)
            else {
                await lease.close()
                return
            }
            self.installLease(lease, threadID: threadID, generation: generation)

            do {
                let observation = try await lease.observe(fields: .all)
                defer { Task { await lease.cancel(observation) } }
                self.applyChildSnapshot(
                    observation.seed,
                    threadID: threadID,
                    generation: generation
                )
                for await _ in observation.signals {
                    guard !Task.isCancelled,
                          self.isCurrent(generation, parentThreadID: parentThreadID),
                          self.childRuntimes[threadID]?.lease === lease else { return }
                    self.applyChildSnapshot(
                        try await lease.snapshot(fields: .all),
                        threadID: threadID,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(generation, parentThreadID: parentThreadID) else { return }
                self.markChildFailure(threadID, message: String(describing: error))
            }
        }
        childRuntimes[threadID] = ChildRuntime(
            generation: generation,
            lease: nil,
            observationTask: observationTask,
            projectionTask: nil,
            projectionID: nil,
            latestSnapshotRevision: nil,
            pendingProjection: nil
        )
    }

    func installLease(
        _ lease: CodexThreadLease,
        threadID: ThreadID,
        generation: UInt64
    ) {
        guard var runtime = childRuntimes[threadID], runtime.generation == generation else {
            Task { await lease.close() }
            return
        }
        runtime.lease = lease
        childRuntimes[threadID] = runtime
        diagnostics.childLeaseAcquisitionCount += 1
    }

    func applyChildSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        generation: UInt64
    ) {
        guard let parentThreadID,
              isCurrent(generation, parentThreadID: parentThreadID),
              var runtime = childRuntimes[threadID],
              runtime.generation == generation,
              let summary = CodexSubagentChildSnapshotSummary(
                  snapshot: snapshot,
                  threadID: threadID
              )
        else {
            return
        }
        if let latest = runtime.latestSnapshotRevision, snapshot.revision < latest {
            return
        }
        guard store.applyChildSnapshotMetadata(summary) else {
            return
        }

        if runtime.projectionTask != nil || runtime.pendingProjection != nil {
            diagnostics.childSnapshotCoalescingCount += 1
        }
        runtime.latestSnapshotRevision = snapshot.revision
        runtime.pendingProjection = .init(snapshot: snapshot, summary: summary)
        childRuntimes[threadID] = runtime
        launchChildProjectionIfNeeded(
            threadID,
            parentThreadID: parentThreadID,
            generation: generation
        )
    }

    func launchChildProjectionIfNeeded(
        _ threadID: ThreadID,
        parentThreadID: ThreadID,
        generation: UInt64
    ) {
        guard isCurrent(generation, parentThreadID: parentThreadID),
              var runtime = childRuntimes[threadID],
              runtime.generation == generation,
              runtime.projectionTask == nil,
              let pending = runtime.pendingProjection
        else {
            return
        }

        runtime.pendingProjection = nil
        nextProjectionID &+= 1
        let projectionID = nextProjectionID
        let previous = store.canonicalPresentation(threadID: threadID)
        let previousMetrics = store.retentionMetrics(threadID: threadID)
        let operation = projectionOperation
        let projectionTask = Task { [weak self] in
            let completed = await Task.detached(priority: .userInitiated) {
                let result = operation(pending.snapshot, threadID, previous)
                return CodexCompletedChildProjection(
                    result: result,
                    transcript: result.presentation.transcript,
                    retentionMetrics: result.presentation.retentionMetrics(
                        previous: previousMetrics,
                        update: result.update
                    ),
                    isTerminalAndHydrated: CodexSubagentStoreV2.isTerminalAndHydrated(
                        pending.snapshot,
                        summary: pending.summary
                    )
                )
            }.value
            self?.finishChildProjection(
                completed,
                pending: pending,
                threadID: threadID,
                parentThreadID: parentThreadID,
                generation: generation,
                projectionID: projectionID
            )
        }
        runtime.projectionID = projectionID
        runtime.projectionTask = projectionTask
        childRuntimes[threadID] = runtime
        diagnostics.childProjectionScheduleCount += 1
    }

    func finishChildProjection(
        _ completed: CodexCompletedChildProjection,
        pending: CodexPendingChildProjection,
        threadID: ThreadID,
        parentThreadID: ThreadID,
        generation: UInt64,
        projectionID: UInt64
    ) {
        guard var runtime = childRuntimes[threadID],
              runtime.generation == generation,
              runtime.projectionID == projectionID
        else {
            diagnostics.childProjectionDiscardCount += 1
            return
        }

        runtime.projectionTask = nil
        runtime.projectionID = nil
        let hasNewerSnapshot = runtime.pendingProjection != nil
            || runtime.latestSnapshotRevision != pending.snapshot.revision
        childRuntimes[threadID] = runtime
        let result = completed.result

        guard isCurrent(generation, parentThreadID: parentThreadID),
              desiredChildIDs.contains(threadID),
              !hasNewerSnapshot,
              result.presentation.threadID == threadID,
              result.presentation.sourceRevision == pending.snapshot.revision,
              store.applyChildProjection(
                  result,
                  threadID: threadID,
                  expectedRevision: pending.snapshot.revision,
                  transcript: completed.transcript,
                  retentionMetrics: completed.retentionMetrics
              )
        else {
            diagnostics.childProjectionDiscardCount += 1
            launchChildProjectionIfNeeded(
                threadID,
                parentThreadID: parentThreadID,
                generation: generation
            )
            return
        }

        diagnostics.childProjectionCount += 1
        touchProjection(threadID, protecting: demandedProjectionThreadID)
        if completed.isTerminalAndHydrated {
            terminalChildIDs.insert(threadID)
            releaseChildLease(threadID, retainProjection: true)
        }
        evictProjectionOverflow(protecting: demandedProjectionThreadID)
        refreshMapperAndPublish()
    }

    func markChildFailure(_ threadID: ThreadID, message: String) {
        store.updateStatus(threadID: threadID, status: .failed(message: message))
        releaseChildLease(threadID, retainProjection: true)
        evictProjectionOverflow()
        refreshMapperAndPublish()
    }

    func releaseAndRemoveChild(_ threadID: ThreadID) {
        releaseChildLease(threadID, retainProjection: false)
        terminalChildIDs.remove(threadID)
        suppressedProjectionThreadIDs.remove(threadID)
        if demandedProjectionThreadID == threadID {
            demandedProjectionThreadID = nil
        }
        projectionLRU.removeAll { $0 == threadID }
        store.remove(threadID: threadID)
    }

    func releaseChildLease(_ threadID: ThreadID, retainProjection: Bool) {
        guard let runtime = childRuntimes.removeValue(forKey: threadID) else { return }
        runtime.observationTask?.cancel()
        runtime.projectionTask?.cancel()
        if let lease = runtime.lease {
            diagnostics.childLeaseReleaseCount += 1
            Task { await lease.close() }
        }
        if !retainProjection { store.evictTranscript(threadID: threadID) }
    }

    func releaseClosedChildren() {
        for id in desiredChildIDs {
            guard case .closed? = store.agent(threadID: id.rawValue)?.status else { continue }
            terminalChildIDs.insert(id)
            releaseChildLease(id, retainProjection: true)
        }
        evictProjectionOverflow()
    }

}

// MARK: - Projection retention and publication

private extension CodexSubagentPresentationCoordinator {
    @discardableResult
    func touchProjection(
        _ threadID: ThreadID,
        protecting protectedThreadID: ThreadID? = nil
    ) -> Bool {
        projectionLRU.removeAll { $0 == threadID }
        projectionLRU.append(threadID)
        return evictProjectionOverflow(protecting: protectedThreadID)
    }

    @discardableResult
    func evictProjectionOverflow(protecting protectedThreadID: ThreadID? = nil) -> Bool {
        var didEvict = false
        while projectionLRU.count > projectionCapacity
            || store.retainedProjectionEstimatedByteCount > projectionByteCapacity {
            guard let candidate = projectionLRU.first(where: {
                $0 != protectedThreadID
            }) ?? projectionLRU.first else { return didEvict }
            projectionLRU.removeAll { $0 == candidate }
            let suppressesActiveProjection = childRuntimes[candidate] != nil
            let exceedsHardLimitWhileDemanded = candidate == protectedThreadID
            if suppressesActiveProjection || exceedsHardLimitWhileDemanded {
                suppressedProjectionThreadIDs.insert(candidate)
            }
            if suppressesActiveProjection {
                releaseChildLease(candidate, retainProjection: false)
            } else {
                store.evictTranscript(threadID: candidate)
            }
            diagnostics.projectionEvictionCount += 1
            didEvict = true
        }
        return didEvict
    }

    func refreshMapperAndPublish() {
        let projectedAgents = store.agents
        if let latestParentSnapshot, let parentThreadID {
            _ = mapper.applyCanonicalSnapshot(
                latestParentSnapshot,
                parentThreadID: parentThreadID,
                projectedChildren: projectedAgents
            )
        }
        publish(projectedAgents)
    }

    func publish(_ projectedAgents: [CodexSubagentV2]? = nil) {
        agents = projectedAgents ?? store.agents
        panelSubagents = mapper.subagents.map { subagent in
            var subagent = subagent
            let threadID = ThreadID(subagent.id)
            if demandedProjectionThreadID == threadID,
               suppressedProjectionThreadIDs.contains(threadID) {
                subagent.transcriptAvailability = .exceedsDisplayLimit
            }
            return subagent
        }
        lifecycleEvents = mapper.lifecycleEvents
        changeRevision &+= 1
    }

    func clearProjectionState() {
        latestParentSnapshot = nil
        parentDiscoveredIDs.removeAll(keepingCapacity: false)
        indexedChildIDs.removeAll(keepingCapacity: false)
        seenIndexedChildIDs.removeAll(keepingCapacity: false)
        removedIndexedChildIDs.removeAll(keepingCapacity: false)
        terminalChildIDs.removeAll(keepingCapacity: false)
        projectionLRU.removeAll(keepingCapacity: false)
        suppressedProjectionThreadIDs.removeAll(keepingCapacity: false)
        demandedProjectionThreadID = nil
        store.removeAll()
        mapper.reset()
    }

    func cancelObservationTasks() {
        parentObservationTask?.cancel()
        parentObservationTask = nil
        indexObservationTask?.cancel()
        indexObservationTask = nil
        for runtime in childRuntimes.values {
            runtime.observationTask?.cancel()
            runtime.projectionTask?.cancel()
        }
    }

    func isCurrent(_ generation: UInt64, parentThreadID: ThreadID) -> Bool {
        self.generation == generation && self.parentThreadID == parentThreadID
    }
}
