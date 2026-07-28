import CodexCore
import Foundation
import Observation

public struct CodexSubagentPresentationDiagnostics: Sendable, Equatable {
    public fileprivate(set) var parentSnapshotCount = 0
    public fileprivate(set) var indexSnapshotCount = 0
    public fileprivate(set) var childLeaseAcquisitionCount = 0
    public fileprivate(set) var childLeaseReleaseCount = 0
    public fileprivate(set) var childProjectionCount = 0
    public fileprivate(set) var projectionEvictionCount = 0

    public init() {}
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
    @ObservationIgnored private var store = CodexSubagentStoreV2()
    @ObservationIgnored private var mapper = CodexAgentStateMapper()
    @ObservationIgnored private var latestParentSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored private var parentDiscoveredIDs: Set<ThreadID> = []
    @ObservationIgnored private var indexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var seenIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var removedIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var terminalChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var projectionLRU: [ThreadID] = []
    @ObservationIgnored private var childRuntimes: [ThreadID: ChildRuntime] = [:]
    @ObservationIgnored private var parentObservationTask: Task<Void, Never>?
    @ObservationIgnored private var indexObservationTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    private struct ChildRuntime {
        var generation: UInt64
        var lease: CodexThreadLease?
        var task: Task<Void, Never>?
    }

    public init(
        codex: Codex,
        projectionCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionCapacity,
        projectionByteCapacity: Int = CodexSubagentPresentationCoordinator.defaultProjectionByteCapacity
    ) {
        self.codex = codex
        self.projectionCapacity = max(1, projectionCapacity)
        self.projectionByteCapacity = max(0, projectionByteCapacity)
    }

    deinit {
        parentObservationTask?.cancel()
        indexObservationTask?.cancel()
        for runtime in childRuntimes.values { runtime.task?.cancel() }
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

    public var retainedProjectionPreparedUTF8ByteCount: Int {
        store.retainedPreparedUTF8ByteCount
    }

    /// Returns the currently cached child transcript and marks it most recent.
    /// If a terminal projection was evicted, this starts a fresh exact lease so
    /// the caller eventually receives a complete canonical projection again.
    public func transcript(threadID: ThreadID) -> CodexTranscriptV2? {
        guard store.contains(threadID: threadID.rawValue) else { return nil }
        if touchProjection(threadID, protecting: threadID) {
            refreshMapperAndPublish()
        }
        let transcript = store.agent(threadID: threadID.rawValue)?.transcript
        if transcript?.turns.isEmpty == true,
           childRuntimes[threadID] == nil,
           let parentThreadID {
            terminalChildIDs.remove(threadID)
            acquireChild(threadID, parentThreadID: parentThreadID, generation: generation)
        }
        return transcript
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
        }
        for id in desired where childRuntimes[id] == nil && !terminalChildIDs.contains(id) {
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
        let task = Task { [weak self] in
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
            task: task
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
        guard childRuntimes[threadID]?.generation == generation else { return }
        guard store.applyChildSnapshot(snapshot, threadID: threadID) else { return }
        diagnostics.childProjectionCount += 1
        touchProjection(threadID)

        if Self.isTerminalAndHydrated(snapshot, threadID: threadID) {
            terminalChildIDs.insert(threadID)
            releaseChildLease(threadID, retainProjection: true)
            evictProjectionOverflow()
        } else {
            evictProjectionOverflow()
        }
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
        projectionLRU.removeAll { $0 == threadID }
        store.remove(threadID: threadID)
    }

    func releaseChildLease(_ threadID: ThreadID, retainProjection: Bool) {
        guard let runtime = childRuntimes.removeValue(forKey: threadID) else { return }
        runtime.task?.cancel()
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

    static func isTerminalAndHydrated(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> Bool {
        guard let thread = snapshot.threads[threadID] else { return false }
        let turns = snapshot.turns(in: threadID)
        guard let latest = turns.last, latest.status.isTerminal else { return false }
        if thread.history.turnsCoverage == .full,
           turns.allSatisfy({ $0.itemsCoverage == .full }) {
            return true
        }
        // Live child threads can be complete before they have ever needed a
        // history resume. An authoritative terminal turn is already sufficient.
        return latest.itemsConsistency == .authoritative && latest.itemsCoverage == .full
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
            || store.retainedPreparedUTF8ByteCount > projectionByteCapacity {
            guard let candidate = projectionLRU.first(where: {
                $0 != protectedThreadID && childRuntimes[$0] == nil
            }) else { return didEvict }
            projectionLRU.removeAll { $0 == candidate }
            store.evictTranscript(threadID: candidate)
            diagnostics.projectionEvictionCount += 1
            didEvict = true
        }
        return didEvict
    }

    func refreshMapperAndPublish() {
        if let latestParentSnapshot, let parentThreadID {
            _ = mapper.applyCanonicalSnapshot(
                latestParentSnapshot,
                parentThreadID: parentThreadID,
                projectedChildren: store.agents
            )
        }
        publish()
    }

    func publish() {
        agents = store.agents
        panelSubagents = mapper.subagents
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
        store.removeAll()
        mapper.reset()
    }

    func cancelObservationTasks() {
        parentObservationTask?.cancel()
        parentObservationTask = nil
        indexObservationTask?.cancel()
        indexObservationTask = nil
        for runtime in childRuntimes.values { runtime.task?.cancel() }
    }

    func isCurrent(_ generation: UInt64, parentThreadID: ThreadID) -> Bool {
        self.generation == generation && self.parentThreadID == parentThreadID
    }
}
