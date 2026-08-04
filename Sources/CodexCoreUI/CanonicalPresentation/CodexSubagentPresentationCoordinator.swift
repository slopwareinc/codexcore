import CodexCore
import Foundation
import Observation

public struct CodexSubagentPresentationDiagnostics: Sendable, Equatable {
    public internal(set) var parentSnapshotCount = 0
    public internal(set) var indexSnapshotCount = 0
    public internal(set) var childLeaseAcquisitionCount = 0
    public internal(set) var childLeaseReleaseCount = 0
    public internal(set) var childProjectionCount = 0
    public internal(set) var childProjectionScheduleCount = 0
    public internal(set) var childProjectionDiscardCount = 0
    public internal(set) var childSnapshotCoalescingCount = 0
    public internal(set) var projectionEvictionCount = 0

    public init() {}
}

/// Canonical coordinator for recursive descendant-agent presentation.
///
/// The canonical session is observed across threads because child lifecycle is
/// multiplexed into parent items at every depth. Direct child relationships and
/// names also arrive through the lightweight thread index.
/// Only the child transcript visible in the side panel receives an exact
/// retention lease and scoped projection. Unselected children remain lightweight
/// metadata derived from the parent and thread index.
@MainActor
@Observable
public final class CodexSubagentPresentationCoordinator {
    @available(*, deprecated, message: "Only the selected transcript is retained.")
    public static let defaultProjectionCapacity = 8
    public static let defaultProjectionByteCapacity = 8 * 1_024 * 1_024

    public private(set) var parentThreadID: ThreadID?
    public private(set) var agents: [CodexSubagentV2] = []
    public private(set) var panelSubagents: [CodexSubagentState] = []
    public private(set) var lifecycleEvents: [CodexAgentLifecycleEvent] = []
    public private(set) var changeRevision: UInt64 = 0
    public internal(set) var diagnostics = CodexSubagentPresentationDiagnostics()

    @ObservationIgnored let codex: Codex
    @ObservationIgnored let projectionByteCapacity: Int
    @ObservationIgnored let projectionOperation: @Sendable (
        CanonicalStateSnapshot,
        ThreadID,
        CodexCanonicalTranscriptPresentation?,
        Set<TurnID>,
        Int
    ) throws -> CodexSelectedChildProjectionOutput
    @ObservationIgnored var store = CodexSubagentStoreV2()
    @ObservationIgnored private var mapper = CodexAgentStateMapper()
    @ObservationIgnored private var latestParentSnapshot: CanonicalStateSnapshot?
    @ObservationIgnored var parentDiscoveredIDs: Set<ThreadID> = []
    @ObservationIgnored var indexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored private var seenIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored var removedIndexedChildIDs: Set<ThreadID> = []
    @ObservationIgnored var selectedProjection: CodexSelectedSubagentProjection?
    @ObservationIgnored private var parentObservationTask: Task<Void, Never>?
    @ObservationIgnored private var indexObservationTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var nextSelectionID: UInt64 = 0
    @ObservationIgnored var nextProjectionID: UInt64 = 0

    public convenience init(codex: Codex) {
        self.init(
            codex: codex,
            projectionByteCapacity: Self.defaultProjectionByteCapacity
        )
    }

    @available(*, deprecated, message: "Only the selected transcript is retained.")
    public convenience init(codex: Codex, projectionCapacity: Int) {
        self.init(codex: codex)
        _ = projectionCapacity
    }

    public convenience init(codex: Codex, projectionByteCapacity: Int) {
        self.init(
            codex: codex,
            projectionCapacity: 8,
            projectionByteCapacity: projectionByteCapacity
        )
    }

    public init(
        codex: Codex,
        projectionCapacity: Int,
        projectionByteCapacity: Int
    ) {
        self.codex = codex
        _ = projectionCapacity
        self.projectionByteCapacity = max(0, projectionByteCapacity)
        self.projectionOperation = CodexSubagentStoreV2.projectSelectedChildSnapshot
    }

    init(
        codex: Codex,
        projectionByteCapacity: Int =
            CodexSubagentPresentationCoordinator.defaultProjectionByteCapacity,
        projectionOperation: @escaping @Sendable (
            CanonicalStateSnapshot,
            ThreadID,
            CodexCanonicalTranscriptPresentation?,
            Set<TurnID>,
            Int
        ) throws -> CodexSelectedChildProjectionOutput
    ) {
        self.codex = codex
        self.projectionByteCapacity = max(0, projectionByteCapacity)
        self.projectionOperation = projectionOperation
    }

    func inheritedTurnIDs(for parentThreadID: ThreadID?) -> Set<TurnID> {
        guard let parentThreadID,
              let parent = latestParentSnapshot?.threads[parentThreadID]
        else {
            return []
        }
        return Set(parent.turnOrder)
    }

    isolated deinit {
        parentObservationTask?.cancel()
        indexObservationTask?.cancel()
        selectedProjection?.observationTask?.cancel()
        selectedProjection?.projectionTask?.cancel()
        if let lease = selectedProjection?.lease {
            Task { await lease.close() }
        }
    }

    /// Switches the direct-parent scope. Old child tasks are cancelled
    /// immediately and their leases are released asynchronously.
    public func selectParent(_ threadID: ThreadID?) {
        guard parentThreadID != threadID else { return }
        generation &+= 1
        let outgoing = stopSelectedProjection(discardContent: true)
        cancelParentObservationTasks()
        clearProjectionState()
        parentThreadID = threadID

        if let outgoing {
            Task { await outgoing.close() }
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
        cancelParentObservationTasks()
        let lease = stopSelectedProjection(discardContent: true)
        if let lease { await lease.close() }
        clearProjectionState()
        publish()
    }

    public func reset() async {
        await disconnect()
        diagnostics = .init()
    }

    public func agent(threadID: ThreadID) -> CodexSubagentV2? {
        guard var agent = store.agent(threadID: threadID.rawValue) else {
            return nil
        }
        if selectedProjection?.threadID == threadID {
            agent.transcript = selectedProjection?.transcript ?? .init()
        }
        return agent
    }

    public var retainedProjectionEstimatedByteCount: Int {
        selectedProjection?.estimatedByteCount ?? 0
    }

    /// Selects the child transcript that is currently visible in the agent panel.
    func selectTranscript(_ threadID: ThreadID?) {
        guard selectedProjection?.threadID != threadID else { return }
        closeSelectedProjection(discardContent: true)
        guard let threadID,
              store.contains(threadID: threadID.rawValue),
              let parentThreadID
        else {
            refreshMapperAndPublish()
            return
        }

        nextSelectionID &+= 1
        selectedProjection = CodexSelectedSubagentProjection(
            threadID: threadID,
            selectionID: nextSelectionID
        )
        startSelectedChild(parentThreadID: parentThreadID)
        refreshMapperAndPublish()
    }

    /// Returns the selected child's current disposable transcript projection.
    public func transcript(threadID: ThreadID) -> CodexTranscriptV2? {
        guard store.contains(threadID: threadID.rawValue) else { return nil }
        selectTranscript(threadID)
        guard selectedProjection?.threadID == threadID else { return .init() }
        return selectedProjection?.transcript ?? .init()
    }
}

// MARK: - Parent and index observation

private extension CodexSubagentPresentationCoordinator {
    func startParentObservation(threadID: ThreadID, generation: UInt64) {
        let codex = self.codex
        parentObservationTask = Task { [weak self] in
            let scope = StateObservationScope(
                entities: .all,
                fields: [
                    .threadMetadata,
                    .turnStructure,
                    .turnStatus,
                    .itemStructure,
                    .itemLifecycle,
                ]
            )
            let observation = await codex.session.observeSessionState(
                scope: scope
            )
            defer {
                Task { await codex.session.cancelObservation(observation.id) }
            }
            guard self?.isCurrent(generation, parentThreadID: threadID) == true else { return }
            self?.applyParentSnapshot(observation.seed.canonical, parentThreadID: threadID)

            for await _ in observation.signals {
                guard !Task.isCancelled,
                      self?.isCurrent(generation, parentThreadID: threadID) == true
                else { return }
                let snapshot = await codex.session.canonicalSnapshot(
                    scope: scope
                )
                self?.applyParentSnapshot(snapshot, parentThreadID: threadID)
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
            guard self?.isCurrent(generation, parentThreadID: parentThreadID) == true
            else { return }
            self?.applyThreadIndex(observation.seed, parentThreadID: parentThreadID)

            for await _ in observation.signals {
                guard !Task.isCancelled,
                      self?.isCurrent(generation, parentThreadID: parentThreadID) == true
                else { return }
                self?.applyThreadIndex(
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
        let previousStatus = selectedStatus
        latestParentSnapshot = snapshot
        _ = store.applyParentSnapshot(snapshot, parentThreadID: parentThreadID)
        let graph = CodexThreadGraphProjector.project(snapshot, hostID: "local")
        let root = CodexThreadGraphKey(hostID: "local", threadID: parentThreadID)
        let discoveries = store.applyGraphSnapshot(graph, root: root)
        parentDiscoveredIDs = Set(discoveries.map { ThreadID($0.threadID) })
        diagnostics.parentSnapshotCount += 1
        reconcileChildren()
        reconcileSelectedLifecycle(from: previousStatus)
        refreshMapperAndPublish()
    }

    func applyThreadIndex(
        _ index: CanonicalThreadIndexSnapshot,
        parentThreadID: ThreadID
    ) {
        guard isCurrent(generation, parentThreadID: parentThreadID) else { return }
        let previousStatus = selectedStatus
        let discoveries = store.applyThreadIndex(index, parentThreadID: parentThreadID)
        indexedChildIDs = Set(discoveries.map { ThreadID($0.threadID) })
        seenIndexedChildIDs.formUnion(indexedChildIDs)
        removedIndexedChildIDs = seenIndexedChildIDs.subtracting(indexedChildIDs)
        diagnostics.indexSnapshotCount += 1
        reconcileChildren()
        reconcileSelectedLifecycle(from: previousStatus)
        refreshMapperAndPublish()
    }
}

// MARK: - Publication

extension CodexSubagentPresentationCoordinator {
    func refreshMapperAndPublish() {
        let projectedChildren = projectedAgents()
        if let latestParentSnapshot, let parentThreadID {
            _ = mapper.applyCanonicalSnapshot(
                latestParentSnapshot,
                parentThreadID: parentThreadID,
                projectedChildren: projectedChildren
            )
        }
        publish(projectedChildren)
    }

    func publish(_ projectedAgents: [CodexSubagentV2]? = nil) {
        agents = projectedAgents ?? self.projectedAgents()
        panelSubagents = mapper.subagents.map { subagent in
            var subagent = subagent
            if subagent.id == selectedProjection?.threadID.rawValue,
               selectedProjection?.isSuppressed == true {
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
        selectedProjection = nil
        store.removeAll()
        mapper.reset()
    }

    func cancelParentObservationTasks() {
        parentObservationTask?.cancel()
        parentObservationTask = nil
        indexObservationTask?.cancel()
        indexObservationTask = nil
    }

    func isCurrent(_ generation: UInt64, parentThreadID: ThreadID) -> Bool {
        self.generation == generation && self.parentThreadID == parentThreadID
    }
}
