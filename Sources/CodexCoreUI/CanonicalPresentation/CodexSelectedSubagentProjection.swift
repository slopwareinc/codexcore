import CodexCore
import Foundation

private extension CodexSubagentLiveStatusV2 {
    var projectionLifecyclePhase: Int {
        switch self {
        case .pending: 0
        case .working: 1
        case .completed: 2
        case .closed: 3
        case .failed: 4
        }
    }
}

struct CodexPendingChildProjection: Sendable {
    var snapshot: CanonicalStateSnapshot
    var summary: CodexSubagentChildSnapshotSummary
    var inheritedParentTurnIDs: Set<TurnID>
}

@MainActor
final class CodexSelectedSubagentProjection {
    let threadID: ThreadID
    let selectionID: UInt64
    var lease: CodexThreadLease?
    var observationTask: Task<Void, Never>?
    var projectionTask: Task<Void, Never>?
    var projectionID: UInt64?
    var latestSnapshotRevision: StateRevision?
    var pendingProjection: CodexPendingChildProjection?
    var presentation: CodexCanonicalTranscriptPresentation?
    var displayCost = CodexTranscriptDisplayCostLedger()
    var isSuppressed = false

    init(threadID: ThreadID, selectionID: UInt64) {
        self.threadID = threadID
        self.selectionID = selectionID
    }

    var transcript: CodexTranscriptV2 {
        presentation?.transcript ?? .init()
    }

    var estimatedByteCount: Int {
        displayCost.estimatedByteCount
    }

    func matches(
        threadID: ThreadID,
        selectionID: UInt64,
        lease: CodexThreadLease? = nil
    ) -> Bool {
        self.threadID == threadID
            && self.selectionID == selectionID
            && lease.map { self.lease === $0 } ?? true
    }

    func stop() -> (lease: CodexThreadLease?, cancelledProjection: Bool) {
        observationTask?.cancel()
        projectionTask?.cancel()
        let result = (lease, projectionTask != nil)
        lease = nil
        observationTask = nil
        projectionTask = nil
        projectionID = nil
        pendingProjection = nil
        return result
    }
}

/// Incremental byte accounting retained with the sole selected projection.
///
/// The detached projection weighs only `upsertedTurns`; unchanged history keeps
/// its prior scalar weight. This prevents streaming one growing turn from
/// repeatedly walking every earlier turn.
struct CodexTranscriptDisplayCostLedger: Sendable {
    private(set) var turnBytesByID: [TurnID: Int] = [:]
    private(set) var turnByteCount = 0
    private(set) var orderByteCount = 0
    private(set) var requestByteCount = 0

    var estimatedByteCount: Int {
        Self.sum(turnByteCount, orderByteCount, requestByteCount)
    }

    mutating func apply(_ update: CodexTranscriptDisplayCostUpdate) {
        if update.isFullRebuild {
            turnBytesByID.removeAll(keepingCapacity: true)
            turnByteCount = 0
        }
        for turnID in update.removedTurnIDs {
            subtract(turnBytesByID.removeValue(forKey: turnID))
        }
        for (turnID, byteCount) in update.upsertedTurnBytes {
            subtract(turnBytesByID.updateValue(byteCount, forKey: turnID))
            add(byteCount)
        }
        if let orderByteCount = update.orderByteCount {
            self.orderByteCount = orderByteCount
        }
        requestByteCount = update.requestByteCount
    }

    mutating func removeAll() {
        turnBytesByID.removeAll(keepingCapacity: false)
        turnByteCount = 0
        orderByteCount = 0
        requestByteCount = 0
    }

    private mutating func add(_ value: Int) {
        let (sum, overflow) = turnByteCount.addingReportingOverflow(max(0, value))
        turnByteCount = overflow ? .max : sum
    }

    private mutating func subtract(_ value: Int?) {
        guard let value, turnByteCount != .max else { return }
        turnByteCount = max(0, turnByteCount - value)
    }

    private static func sum(_ values: Int...) -> Int {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? .max : sum
        }
        return total
    }
}

struct CodexTranscriptDisplayCostUpdate: Sendable {
    var upsertedTurnBytes: [TurnID: Int]
    var removedTurnIDs: Set<TurnID>
    var orderByteCount: Int?
    var requestByteCount: Int
    var isFullRebuild: Bool
    var exceedsDisplayLimit: Bool
}

enum CodexTranscriptDisplayCostWeigher {
    static func update(
        output: CodexSelectedChildProjectionOutput,
        stoppingAfter limit: Int
    ) -> CodexTranscriptDisplayCostUpdate {
        let result = output.projection
        let renderUpdate = result.update
        guard renderUpdate.pendingRequests.isEmpty else {
            return exceeding(renderUpdate)
        }
        let limit = max(0, limit)
        var upsertedTurnBytes: [TurnID: Int] = [:]
        var changedTurnByteCount = 0
        for turn in renderUpdate.upsertedTurns {
            let turnID = TurnID(turn.id)
            guard let cost = output.upsertedTurnDisplayCosts[turnID],
                  !cost.exceedsLimit
            else {
                return exceeding(renderUpdate)
            }
            upsertedTurnBytes[turnID] = cost.estimatedByteCount
            let (sum, overflow) = changedTurnByteCount.addingReportingOverflow(
                cost.estimatedByteCount
            )
            guard !overflow, sum <= limit else {
                return exceeding(renderUpdate)
            }
            changedTurnByteCount = sum
        }
        if renderUpdate.isFullRebuild,
           upsertedTurnBytes.count != result.presentation.turnsByID.count {
            return exceeding(renderUpdate)
        }

        let orderByteCount: Int?
        if renderUpdate.isFullRebuild || renderUpdate.turnOrder != nil {
            let count = renderUpdate.turnOrder?.count
                ?? result.presentation.turnOrder.count
            let (bytes, overflow) = count.multipliedReportingOverflow(by: 192)
            guard !overflow, bytes <= max(0, limit) else {
                return exceeding(renderUpdate)
            }
            orderByteCount = bytes
        } else {
            orderByteCount = nil
        }
        return .init(
            upsertedTurnBytes: upsertedTurnBytes,
            removedTurnIDs: renderUpdate.removedTurnIDs,
            orderByteCount: orderByteCount,
            requestByteCount: 0,
            isFullRebuild: renderUpdate.isFullRebuild,
            exceedsDisplayLimit: false
        )
    }

    private static func exceeding(
        _ update: CodexCanonicalTranscriptRenderUpdate
    ) -> CodexTranscriptDisplayCostUpdate {
        .init(
            upsertedTurnBytes: [:],
            removedTurnIDs: update.removedTurnIDs,
            orderByteCount: nil,
            requestByteCount: 0,
            isFullRebuild: update.isFullRebuild,
            exceedsDisplayLimit: true
        )
    }
}

// MARK: - Selected child lease and projection

@MainActor
extension CodexSubagentPresentationCoordinator {
    var desiredChildIDs: Set<ThreadID> {
        parentDiscoveredIDs.subtracting(removedIndexedChildIDs).union(indexedChildIDs)
    }

    func reconcileChildren() {
        let desired = desiredChildIDs
        for id in store.threadIDs where !desired.contains(id) {
            metadataRefreshTasks.removeValue(forKey: id)?.cancel()
            metadataRefreshAttemptedIDs.remove(id)
            if selectedProjection?.threadID == id {
                closeSelectedProjection(discardContent: true)
            }
            store.remove(threadID: id)
        }
        for id in desired
            where metadataRefreshTasks[id] == nil
                && !metadataRefreshAttemptedIDs.contains(id)
        {
            guard let agent = store.agent(threadID: id.rawValue),
                  agent.agentPath == nil || agent.nickname == nil || agent.role == nil
            else { continue }
            metadataRefreshAttemptedIDs.insert(id)
            startMetadataRefresh(threadID: id)
        }
    }

    /// Fetches only the child's thread metadata. This deliberately uses
    /// `includeTurns: false`: unselected children must receive their native
    /// nickname/path without acquiring a transcript lease or loading history.
    func startMetadataRefresh(threadID: ThreadID) {
        guard let parentThreadID else { return }
        let generation = self.generation
        let codex = self.codex
        metadataRefreshTasks[threadID] = Task { [weak self] in
            defer { self?.metadataRefreshTasks.removeValue(forKey: threadID) }
            do {
                _ = try await codex.perform(CodexRequest.threadRead(.init(
                    includeTurns: false,
                    threadID: threadID.rawValue
                )))
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation, parentThreadID: parentThreadID)
            else { return }
            self.applyThreadIndex(
                await codex.session.threadIndexSnapshot(),
                parentThreadID: parentThreadID
            )
        }
    }

    func startSelectedChild(parentThreadID: ThreadID) {
        guard let selected = selectedProjection,
              selected.observationTask == nil,
              desiredChildIDs.contains(selected.threadID)
        else { return }
        let threadID = selected.threadID
        let selectionID = selected.selectionID
        let codex = self.codex
        selected.observationTask = Task { [weak self] in
            let lease = await codex.retainThread(
                threadID,
                reason: .subagentObserver(parentThreadID)
            )
            guard !Task.isCancelled,
                  self?.installSelectedLease(
                      lease,
                      threadID: threadID,
                      selectionID: selectionID
                  ) == true
            else {
                await lease.close()
                return
            }

            do {
                let observation = try await lease.observe(fields: .all)
                do {
                    self?.applyChildSnapshot(observation.seed, threadID, selectionID)
                    for await _ in observation.signals {
                        guard !Task.isCancelled,
                              self?.selection(
                                  threadID,
                                  selectionID,
                                  lease: lease
                              ) != nil
                        else { break }
                        self?.applyChildSnapshot(
                            try await lease.snapshot(fields: .all),
                            threadID,
                            selectionID
                        )
                    }
                } catch {
                    await lease.cancel(observation)
                    throw error
                }
                await lease.cancel(observation)
            } catch is CancellationError {
                return
            } catch {
                self?.failSelectedObservation(
                    String(describing: error),
                    threadID: threadID,
                    selectionID: selectionID
                )
            }
        }
    }

    func installSelectedLease(
        _ lease: CodexThreadLease,
        threadID: ThreadID,
        selectionID: UInt64
    ) -> Bool {
        guard let selected = selection(threadID, selectionID) else { return false }
        selected.lease = lease
        diagnostics.childLeaseAcquisitionCount += 1
        return true
    }

    func failSelectedObservation(
        _ message: String,
        threadID: ThreadID,
        selectionID: UInt64
    ) {
        guard selection(threadID, selectionID) != nil else { return }
        store.updateStatus(threadID: threadID, status: .failed(message: message))
        closeSelectedProjection(discardContent: false)
        refreshMapperAndPublish()
    }

    func applyChildSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        _ threadID: ThreadID,
        _ selectionID: UInt64
    ) {
        guard let selected = selection(threadID, selectionID),
              let summary = CodexSubagentChildSnapshotSummary(
                  snapshot: snapshot,
                  threadID: threadID
              )
        else { return }
        if let latest = selected.latestSnapshotRevision,
           snapshot.revision <= latest {
            return
        }
        let previousPhase = store.agent(threadID: threadID.rawValue)?
            .status.projectionLifecyclePhase
        guard let metadataChanged =
            store.applyChildSnapshotMetadataReportingChanges(summary)
        else { return }
        if previousPhase != store.agent(threadID: threadID.rawValue)?
            .status.projectionLifecyclePhase {
            selected.isSuppressed = false
        }
        selected.latestSnapshotRevision = snapshot.revision
        if metadataChanged { refreshMapperAndPublish() }
        guard !selected.isSuppressed else { return }
        if selected.projectionTask != nil || selected.pendingProjection != nil {
            diagnostics.childSnapshotCoalescingCount += 1
        }
        let inheritedParentTurnIDs = inheritedTurnIDs(for: parentThreadID)
        selected.pendingProjection = .init(
            snapshot: snapshot,
            summary: summary,
            inheritedParentTurnIDs: inheritedParentTurnIDs
        )
        launchChildProjectionIfNeeded(threadID, selectionID)
    }

    func launchChildProjectionIfNeeded(
        _ threadID: ThreadID,
        _ selectionID: UInt64
    ) {
        guard let selected = selection(threadID, selectionID),
              selected.projectionTask == nil,
              let pending = selected.pendingProjection
        else { return }

        selected.pendingProjection = nil
        nextProjectionID &+= 1
        let projectionID = nextProjectionID
        let previous = selected.presentation
        let operation = projectionOperation
        let byteCapacity = projectionByteCapacity
        selected.projectionTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let output = try operation(
                    pending.snapshot,
                    threadID,
                    previous,
                    pending.inheritedParentTurnIDs,
                    byteCapacity
                )
                let result = output.projection
                let displayCostUpdate = CodexTranscriptDisplayCostWeigher.update(
                    output: output,
                    stoppingAfter: byteCapacity
                )
                let isTerminal = CodexSubagentStoreV2.isTerminalAndHydrated(
                    pending.snapshot,
                    summary: pending.summary
                )
                try Task.checkCancellation()
                await self?.finishChildProjection(
                    result,
                    displayCostUpdate: displayCostUpdate,
                    isTerminal: isTerminal,
                    pending: pending,
                    threadID: threadID,
                    selectionID: selectionID,
                    projectionID: projectionID
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.finishChildProjectionFailure(
                    String(describing: error),
                    threadID: threadID,
                    selectionID: selectionID,
                    projectionID: projectionID
                )
            }
        }
        selected.projectionID = projectionID
        diagnostics.childProjectionScheduleCount += 1
    }

    func finishChildProjection(
        _ result: CodexCanonicalTranscriptProjectionResult,
        displayCostUpdate: CodexTranscriptDisplayCostUpdate,
        isTerminal: Bool,
        pending: CodexPendingChildProjection,
        threadID: ThreadID,
        selectionID: UInt64,
        projectionID: UInt64
    ) {
        guard let selected = selection(threadID, selectionID),
              selected.projectionID == projectionID
        else {
            diagnostics.childProjectionDiscardCount += 1
            return
        }

        selected.projectionTask = nil
        selected.projectionID = nil
        guard selected.pendingProjection == nil,
              selected.latestSnapshotRevision == pending.snapshot.revision,
              result.presentation.threadID == threadID,
              result.presentation.sourceRevision == pending.snapshot.revision
        else {
            diagnostics.childProjectionDiscardCount += 1
            launchChildProjectionIfNeeded(threadID, selectionID)
            return
        }

        diagnostics.childProjectionCount += 1
        if !displayCostUpdate.exceedsDisplayLimit {
            selected.displayCost.apply(displayCostUpdate)
        }
        if displayCostUpdate.exceedsDisplayLimit
            || selected.estimatedByteCount > projectionByteCapacity {
            selected.presentation = nil
            selected.displayCost.removeAll()
            selected.isSuppressed = true
            diagnostics.projectionEvictionCount += 1
        } else {
            selected.presentation = result.presentation
        }
        if isTerminal { closeSelectedProjection(discardContent: false) }
        refreshMapperAndPublish()
    }

    func finishChildProjectionFailure(
        _ message: String,
        threadID: ThreadID,
        selectionID: UInt64,
        projectionID: UInt64
    ) {
        guard let selected = selection(threadID, selectionID),
              selected.projectionID == projectionID
        else { return }
        selected.projectionTask = nil
        selected.projectionID = nil
        store.updateStatus(
            threadID: threadID,
            status: .failed(message: message)
        )
        closeSelectedProjection(discardContent: false)
        refreshMapperAndPublish()
    }

    func closeSelectedProjection(discardContent: Bool) {
        let lease = stopSelectedProjection(discardContent: discardContent)
        if let lease { Task { await lease.close() } }
    }

    func reconcileSelectedLifecycle(
        from previousStatus: CodexSubagentLiveStatusV2?
    ) {
        guard let selected = selectedProjection,
              let status = store.agent(threadID: selected.threadID.rawValue)?.status
        else { return }
        let lifecycleChanged = status.projectionLifecyclePhase
            != previousStatus?.projectionLifecyclePhase
        if lifecycleChanged { selected.isSuppressed = false }
        switch status {
        case .closed:
            closeSelectedProjection(discardContent: false)
        case .pending, .working:
            if lifecycleChanged, let parentThreadID {
                startSelectedChild(parentThreadID: parentThreadID)
            }
        default:
            break
        }
    }

    func stopSelectedProjection(discardContent: Bool) -> CodexThreadLease? {
        guard let selected = selectedProjection else { return nil }
        let stopped = selected.stop()
        if stopped.cancelledProjection {
            diagnostics.childProjectionDiscardCount += 1
        }
        if stopped.lease != nil {
            diagnostics.childLeaseReleaseCount += 1
        }
        if discardContent { selectedProjection = nil }
        return stopped.lease
    }

    func selection(
        _ threadID: ThreadID,
        _ selectionID: UInt64,
        lease: CodexThreadLease? = nil
    ) -> CodexSelectedSubagentProjection? {
        guard desiredChildIDs.contains(threadID),
              let selected = selectedProjection,
              selected.matches(
                  threadID: threadID,
                  selectionID: selectionID,
                  lease: lease
              )
        else { return nil }
        return selected
    }

    var selectedStatus: CodexSubagentLiveStatusV2? {
        guard let selectedProjection else { return nil }
        return store.agent(threadID: selectedProjection.threadID.rawValue)?.status
    }

    func projectedAgents() -> [CodexSubagentV2] {
        var projected = store.agents
        guard let selectedProjection,
              let presentation = selectedProjection.presentation,
              let index = projected.firstIndex(where: {
                  $0.threadID == selectedProjection.threadID.rawValue
              })
        else { return projected }
        projected[index].transcript = presentation.transcript
        return projected
    }
}
