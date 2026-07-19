import Foundation

/// How an incoming turn item collection relates to the items already materialized.
/// The caller must select this from the app-server method's documented authority.
public enum CanonicalItemCollectionMergePolicy: Sendable, Equatable {
    /// Upsert incoming items and retain the established order of known items.
    case mergePreservingExistingOrder
    /// Upsert an older page before items already known locally.
    case mergeIncomingFirst
    /// Merge durable history without allowing a potentially lagging projection
    /// to replace richer facts already observed on the live wire.
    case historyPage
    /// The incoming full collection is authoritative, including absence.
    case authoritativeReplacement
}

/// Typed, protocol-shaped operations accepted by the deterministic reducer.
/// Decoding and method disposition happen before this seam.
public enum CanonicalStateMutation: Sendable, Equatable {
    case accountPatched(CanonicalAccountPatch)
    case mcpServerStartupStatusUpdated(
        key: CanonicalMCPServerStartupKey,
        status: CanonicalMCPServerStartupStatus
    )
    case threadUpsert(CanonicalThread)
    case threadSnapshotReplaced(CanonicalThread)
    /// Destructive authority reserved for a successful `thread/rollback` response.
    case threadRollbackReplaced(
        thread: CanonicalThread,
        turns: [CanonicalTurn],
        items: [CanonicalItem]
    )
    case threadRemoved(ThreadID)
    case threadLifecycleUpdated(
        id: ThreadID,
        isArchived: CanonicalFieldUpdate<Bool>,
        isLoaded: CanonicalFieldUpdate<Bool>
    )
    case threadNameReplaced(id: ThreadID, name: String?)
    case threadEnvironmentConnection(id: ThreadID, environmentID: String, connected: Bool)
    case threadGoalReplaced(id: ThreadID, goal: CanonicalThreadGoal?)
    case threadSettingsReplaced(id: ThreadID, settings: [String: CodexJSONValue])
    /// Sparse response authority. Keys absent from the patch retain their current value;
    /// an explicit `.null` remains a protocol value rather than deleting the key.
    case threadSettingsPatched(id: ThreadID, patch: [String: CodexJSONValue])
    case threadHistoryReplaced(id: ThreadID, history: CanonicalHistoryState)
    case threadHistoryUpdated(id: ThreadID, history: CanonicalHistoryState)
    /// Drops transcript-heavy state while preserving the thread catalogue
    /// record. A later lease reloads detail through the ordinary resume/history
    /// reconciliation path.
    case threadDetailEvicted(ThreadID)
    case turnSnapshot(
        CanonicalTurn,
        items: [CanonicalItem],
        itemPolicy: CanonicalItemCollectionMergePolicy
    )
    case turnStarted(CanonicalTurn, items: [CanonicalItem])
    case turnCompleted(
        CanonicalTurn,
        items: [CanonicalItem],
        itemPolicy: CanonicalItemCollectionMergePolicy
    )
    case itemStarted(CanonicalItem)
    case itemDelta(key: ItemKey, delta: ItemDelta)
    case itemCompleted(CanonicalItem)
    case planReplaced(turn: TurnKey, steps: [CanonicalPlanStep], explanation: String?)
    case diffReplaced(turn: TurnKey, diff: String)
    case turnErrorReported(turn: TurnKey, error: CanonicalTurnError, willRetry: Bool)
    case tokenUsageReplaced(turn: TurnKey, usage: CanonicalTokenUsage)
    case moderationMetadataReplaced(turn: TurnKey, metadata: CodexJSONValue?)
    case turnExtensionReplaced(turn: TurnKey, key: String, value: CodexJSONValue?)
    case itemLiveFieldReplaced(item: ItemKey, key: String, value: CodexJSONValue?)
    case turnItemsMarkedUncertain(TurnKey)
    case submissionIntentRegistered(SubmissionIntent)
    case submissionIntentFailed(id: SubmissionIntentID, message: String)
    case submissionIntentMarkedIndeterminate(id: SubmissionIntentID, message: String?)
}

/// Small invalidation facts. Consumers query the latest scoped state instead of
/// receiving cumulative transcript copies through this change channel.
public enum CanonicalStateChange: Sendable, Equatable, Hashable {
    case accountUpdated
    case mcpServerStartupStatusUpdated(CanonicalMCPServerStartupKey)
    case threadInserted(ThreadID)
    case threadUpdated(ThreadID)
    case threadTurnsReplaced(ThreadID)
    case threadRemoved(ThreadID)
    case threadLifecycleUpdated(ThreadID)
    case threadNameReplaced(ThreadID)
    case threadEnvironmentUpdated(ThreadID)
    case threadGoalReplaced(ThreadID)
    case threadSettingsReplaced(ThreadID)
    case threadHistoryUpdated(ThreadID)
    case threadDetailEvicted(ThreadID)
    case turnInserted(TurnKey)
    case turnUpdated(TurnKey)
    case turnRemoved(TurnKey)
    case turnStarted(TurnKey)
    case turnCompleted(TurnKey)
    case itemInserted(ItemKey)
    case itemUpdated(ItemKey)
    case itemStarted(ItemKey)
    case itemDeltaAppended(ItemKey)
    case itemCompleted(ItemKey)
    case itemRemoved(ItemKey)
    case planReplaced(TurnKey)
    case diffReplaced(TurnKey)
    case turnErrorUpdated(turn: TurnKey, willRetry: Bool)
    case tokenUsageReplaced(TurnKey)
    case moderationMetadataReplaced(TurnKey)
    case turnExtensionReplaced(TurnKey)
    case itemLiveFieldReplaced(ItemKey)
    case turnItemsMarkedUncertain(TurnKey)
    case submissionIntentInserted(id: SubmissionIntentID, threadID: ThreadID)
    case submissionIntentUpdated(id: SubmissionIntentID, threadID: ThreadID)
    case submissionIntentRemoved(id: SubmissionIntentID, threadID: ThreadID)
    case orphanDeltaBuffered(ItemKey)
    case orphanDeltaDropped(ItemKey)
}

/// Every accepted reducer transaction commits all of its changes at one local revision.
public struct CanonicalStateChangeBatch: Sendable, Equatable {
    public let baseRevision: StateRevision
    public let revision: StateRevision
    public let changes: [CanonicalStateChange]

    public init(
        baseRevision: StateRevision,
        revision: StateRevision,
        changes: [CanonicalStateChange]
    ) {
        self.baseRevision = baseRevision
        self.revision = revision
        self.changes = changes
    }

    public var affectedThreadIDs: Set<ThreadID> {
        Set(changes.compactMap(\.threadID))
    }

    public var affectedTurnKeys: Set<TurnKey> {
        Set(changes.compactMap(\.turnKey))
    }

    public var affectedItemKeys: Set<ItemKey> {
        Set(changes.compactMap(\.itemKey))
    }
}

public struct CanonicalStateReducerConfiguration: Sendable, Equatable {
    /// Maximum number of deltas retained before their corresponding item starts.
    public var maximumOrphanDeltaCount: Int
    /// Maximum UTF-8 payload retained across all pre-start deltas.
    public var maximumOrphanUTF8Bytes: Int
    /// A single missing item cannot monopolize the global orphan budget.
    public var maximumOrphanDeltasPerItem: Int
    /// Maximum latest MCP startup statuses retained across global and
    /// thread-scoped server identities. Least-recently notified entries leave first.
    public var maximumMCPServerStartupStatusCount: Int

    public init(
        maximumOrphanDeltaCount: Int = 2_048,
        maximumOrphanUTF8Bytes: Int = 2 * 1_024 * 1_024,
        maximumOrphanDeltasPerItem: Int = 256,
        maximumMCPServerStartupStatusCount: Int = 256
    ) {
        precondition(maximumOrphanDeltaCount >= 0)
        precondition(maximumOrphanUTF8Bytes >= 0)
        precondition(maximumOrphanDeltasPerItem >= 0)
        precondition(maximumMCPServerStartupStatusCount >= 0)
        self.maximumOrphanDeltaCount = maximumOrphanDeltaCount
        self.maximumOrphanUTF8Bytes = maximumOrphanUTF8Bytes
        self.maximumOrphanDeltasPerItem = maximumOrphanDeltasPerItem
        self.maximumMCPServerStartupStatusCount = maximumMCPServerStartupStatusCount
    }
}

/// Synchronous state reducer owned by the sole session actor. It deliberately has
/// no executor, stream, clock, transport, or UI dependency.
internal struct CanonicalStateReducer: Sendable {
    private struct OrphanDelta: Sendable, Equatable {
        let delta: ItemDelta
        let utf8ByteCount: Int
    }

    private var orphanDeltas: [ItemKey: [OrphanDelta]] = [:]
    private var orphanKeyOrder: [ItemKey] = []
    private var orphanDeltaCount = 0
    private var orphanUTF8ByteCount = 0
    private let configuration: CanonicalStateReducerConfiguration

    init(configuration: CanonicalStateReducerConfiguration = .init()) {
        self.configuration = configuration
    }

    var bufferedOrphanDeltaCount: Int { orphanDeltaCount }
    var bufferedOrphanUTF8ByteCount: Int { orphanUTF8ByteCount }

    /// Atomically reduces all mutations produced by one protocol adaptation.
    ///
    /// Mutations are exhaustively validated before the graph is touched, then reduced
    /// synchronously in place at one fixed successor revision. Actor isolation prevents
    /// readers from observing the graph before the complete batch and its invalidation
    /// commit. This avoids copying the graph's large dictionaries for every hot delta.
    /// Exact duplicate invalidations are collapsed, while repeated protocol payloads
    /// (for example equal consecutive item deltas) remain fully represented in the graph.
    mutating func apply(
        _ mutations: [CanonicalStateMutation],
        to graph: inout CanonicalStateGraph
    ) -> CanonicalStateChangeBatch? {
        guard !mutations.isEmpty, mutations.allSatisfy(isWellFormed) else { return nil }

        let baseRevision = graph.revision
        let revision = baseRevision.successor
        var changes: [CanonicalStateChange] = []
        var uniqueChanges: Set<CanonicalStateChange> = []

        for mutation in mutations {
            // The existing single-mutation reducer owns all authority rules. Pinning
            // the input revision makes every in-place reduction use `revision`.
            graph.revision = baseRevision
            if let batch = apply(mutation, to: &graph) {
                precondition(batch.baseRevision == baseRevision)
                precondition(batch.revision == revision)
                for change in batch.changes where uniqueChanges.insert(change).inserted {
                    changes.append(change)
                }
            }
        }

        // A nil single reduction may still perform reducer-internal cleanup (such as
        // discarding obsolete orphan deltas). Preserve that cleanup without inventing
        // a visible state revision when the transaction has no canonical changes.
        guard !changes.isEmpty else {
            graph.revision = baseRevision
            return nil
        }

        graph.revision = revision
        return CanonicalStateChangeBatch(
            baseRevision: baseRevision,
            revision: revision,
            changes: changes
        )
    }

    /// Returns nil for a semantically redundant or rejected mutation.
    mutating func apply(
        _ mutation: CanonicalStateMutation,
        to graph: inout CanonicalStateGraph
    ) -> CanonicalStateChangeBatch? {
        let baseRevision = graph.revision
        let revision = baseRevision.successor
        var changes: [CanonicalStateChange] = []

        switch mutation {
        case .accountPatched(let patch):
            var account = graph.account
            let original = account
            apply(patch.authMode, to: &account.authMode)
            apply(patch.planType, to: &account.planType)
            switch patch.rateLimits {
            case .unchanged:
                break
            case .clear:
                account.rateLimits.removeAll(keepingCapacity: true)
            case .set(let incoming):
                if patch.rateLimitsAreSparse {
                    for (key, value) in incoming where value != .null {
                        account.rateLimits[key] = value
                    }
                } else {
                    account.rateLimits = incoming
                }
            }
            account.extensions.merge(patch.extensions) { _, new in new }
            guard account != original else { break }
            account.lastChangedRevision = revision
            graph.account = account
            changes.append(.accountUpdated)

        case .mcpServerStartupStatusUpdated(let key, let incoming):
            guard configuration.maximumMCPServerStartupStatusCount > 0 else { break }

            // Notification order is the deterministic recency source. Touching an
            // equal value affects only future eviction, not the observable revision.
            graph.mcpServerStartupStatusLRU.removeAll { $0 == key }
            graph.mcpServerStartupStatusLRU.append(key)

            let previous = graph.mcpServerStartupStatuses[key]
            let valueChanged = previous?.status != incoming.status
                || previous?.error != incoming.error
                || previous?.failureReason != incoming.failureReason
            if valueChanged {
                var stored = incoming
                stored.lastChangedRevision = revision
                graph.mcpServerStartupStatuses[key] = stored
            }

            var evicted = false
            while graph.mcpServerStartupStatusLRU.count
                    > configuration.maximumMCPServerStartupStatusCount {
                let evictedKey = graph.mcpServerStartupStatusLRU.removeFirst()
                evicted = graph.mcpServerStartupStatuses.removeValue(forKey: evictedKey) != nil
                    || evicted
            }
            if valueChanged || evicted {
                changes.append(.mcpServerStartupStatusUpdated(key))
            }

        case .threadUpsert(let incoming):
            upsertThread(incoming, revision: revision, graph: &graph, changes: &changes)

        case .threadSnapshotReplaced(let incoming):
            replaceThreadSnapshot(incoming, revision: revision, graph: &graph, changes: &changes)

        case .threadRollbackReplaced(let thread, let turns, let items):
            replaceThreadRollback(
                thread: thread,
                turns: turns,
                items: items,
                revision: revision,
                graph: &graph,
                changes: &changes
            )

        case .threadRemoved(let id):
            removeThread(id, graph: &graph, changes: &changes)

        case .threadLifecycleUpdated(let id, let archived, let loaded):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id] else { break }
            let original = thread
            apply(archived, to: &thread.isArchived)
            switch loaded {
            case .unchanged: break
            case .set(let value): thread.isLoaded = value
            case .clear: thread.isLoaded = false
            }
            guard thread != original else { break }
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadLifecycleUpdated(id))

        case .threadNameReplaced(let id, let name):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id], thread.metadata.name != name else { break }
            thread.metadata.name = name
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadNameReplaced(id))

        case .threadEnvironmentConnection(let id, let environmentID, let connected):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id] else { break }
            let changed = connected
                ? thread.connectedEnvironmentIDs.insert(environmentID).inserted
                : thread.connectedEnvironmentIDs.remove(environmentID) != nil
            guard changed else { break }
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadEnvironmentUpdated(id))

        case .threadGoalReplaced(let id, let goal):
            guard goal == nil || goal?.threadID == id else { break }
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id], thread.goal != goal else { break }
            thread.goal = goal
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadGoalReplaced(id))

        case .threadSettingsReplaced(let id, let settings):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id], thread.settings != settings else { break }
            thread.settings = settings
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadSettingsReplaced(id))

        case .threadSettingsPatched(let id, let patch):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id] else { break }
            var settings = thread.settings ?? [:]
            for (key, value) in patch {
                settings[key] = value
            }
            guard thread.settings != settings else { break }
            thread.settings = settings
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadSettingsReplaced(id))

        case .threadHistoryReplaced(let id, let history):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id] else { break }
            let original = thread
            thread.history = history
            if history.turnsCoverage == .full {
                thread.retainedLatestTurn = nil
            }
            guard thread != original else { break }
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadHistoryUpdated(id))

        case .threadHistoryUpdated(let id, let incoming):
            ensureThread(id, revision: revision, graph: &graph, changes: &changes)
            guard var thread = graph.threads[id] else { break }
            let original = thread.history
            let wasStale = thread.history.isStaleAfterReconnect
            mergeHistory(from: incoming, into: &thread.history)
            thread.history.isStaleAfterReconnect = wasStale || incoming.isStaleAfterReconnect
            guard thread.history != original else { break }
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadHistoryUpdated(id))

        case .threadDetailEvicted(let id):
            evictThreadDetail(id, revision: revision, graph: &graph, changes: &changes)

        case .turnSnapshot(let incoming, let items, let policy):
            mergeTurn(
                incoming,
                items: items,
                itemPolicy: policy,
                isCompletion: false,
                revision: revision,
                graph: &graph,
                changes: &changes
            )

        case .turnStarted(let incoming, let items):
            let before = changes.count
            mergeTurn(
                incoming,
                items: items,
                itemPolicy: .mergePreservingExistingOrder,
                isCompletion: false,
                revision: revision,
                graph: &graph,
                changes: &changes
            )
            if changes.count > before {
                changes.append(.turnStarted(incoming.key))
            }

        case .turnCompleted(let incoming, let items, let policy):
            guard incoming.status.isTerminal else { return nil }
            let before = changes.count
            mergeTurn(
                incoming,
                items: items,
                itemPolicy: policy,
                isCompletion: true,
                revision: revision,
                graph: &graph,
                changes: &changes
            )
            if changes.count > before {
                changes.append(.turnCompleted(incoming.key))
            }

        case .itemStarted(let incoming):
            startItem(
                incoming,
                revision: revision,
                graph: &graph,
                changes: &changes
            )

        case .itemDelta(let key, let delta):
            appendDelta(
                delta,
                to: key,
                revision: revision,
                graph: &graph,
                changes: &changes
            )

        case .itemCompleted(let incoming):
            completeItem(
                incoming,
                authoritativePayload: true,
                revision: revision,
                graph: &graph,
                changes: &changes
            )

        case .planReplaced(let key, let plan, let explanation):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key] else { break }
            guard turn.plan != plan || turn.planExplanation != explanation else { break }
            turn.plan = plan
            turn.planExplanation = explanation
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.planReplaced(key))

        case .diffReplaced(let key, let diff):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key], turn.diff != diff else { break }
            turn.diff = diff
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.diffReplaced(key))

        case .turnErrorReported(let key, let error, let willRetry):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key] else { break }
            let retryValue = CodexJSONValue.bool(willRetry)
            guard turn.error != error || turn.extensions["lastErrorWillRetry"] != retryValue else { break }
            turn.error = error
            turn.extensions["lastErrorWillRetry"] = retryValue
            // Error notifications are diagnostic. Only turn/completed may make a turn terminal.
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.turnErrorUpdated(turn: key, willRetry: willRetry))

        case .tokenUsageReplaced(let key, let usage):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key], turn.tokenUsage != usage else { break }
            turn.tokenUsage = usage
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.tokenUsageReplaced(key))

        case .moderationMetadataReplaced(let key, let metadata):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key], turn.moderationMetadata != metadata else { break }
            turn.moderationMetadata = metadata
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.moderationMetadataReplaced(key))

        case .turnExtensionReplaced(let turnKey, let extensionKey, let value):
            ensureTurn(turnKey, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[turnKey] else { break }
            let previous = turn.extensions[extensionKey]
            guard previous != value else { break }
            if let value {
                turn.extensions[extensionKey] = value
            } else {
                turn.extensions.removeValue(forKey: extensionKey)
            }
            turn.lastChangedRevision = revision
            graph.turns[turnKey] = turn
            changes.append(.turnExtensionReplaced(turnKey))

        case .itemLiveFieldReplaced(let itemKey, let fieldKey, let value):
            guard var item = graph.items[itemKey], item.authority != .completed else { break }
            let previous = item.liveFields[fieldKey]
            guard previous != value else { break }
            if let value {
                item.liveFields[fieldKey] = value
            } else {
                item.liveFields.removeValue(forKey: fieldKey)
            }
            item.lastChangedRevision = revision
            graph.items[itemKey] = item
            changes.append(.itemLiveFieldReplaced(itemKey))

        case .turnItemsMarkedUncertain(let key):
            ensureTurn(key, revision: revision, graph: &graph, changes: &changes)
            guard var turn = graph.turns[key], turn.itemsConsistency != .uncertain else { break }
            turn.itemsConsistency = .uncertain
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
            changes.append(.turnItemsMarkedUncertain(key))

        case .submissionIntentRegistered(var intent):
            guard graph.submissionIntents[intent.id] == nil else { break }
            intent.lastChangedRevision = revision
            graph.submissionIntents[intent.id] = intent
            changes.append(.submissionIntentInserted(id: intent.id, threadID: intent.threadID))

        case .submissionIntentFailed(let id, let message):
            guard var intent = graph.submissionIntents[id], intent.state != .failed(message: message) else { break }
            intent.state = .failed(message: message)
            intent.lastChangedRevision = revision
            graph.submissionIntents[id] = intent
            changes.append(.submissionIntentUpdated(id: id, threadID: intent.threadID))

        case .submissionIntentMarkedIndeterminate(let id, let message):
            guard var intent = graph.submissionIntents[id], intent.state != .indeterminate(message: message) else { break }
            intent.state = .indeterminate(message: message)
            intent.lastChangedRevision = revision
            graph.submissionIntents[id] = intent
            changes.append(.submissionIntentUpdated(id: id, threadID: intent.threadID))
        }

        guard !changes.isEmpty else { return nil }
        propagateAggregateTurnRevisions(
            for: changes,
            revision: revision,
            graph: &graph
        )
        graph.revision = revision
        return CanonicalStateChangeBatch(
            baseRevision: baseRevision,
            revision: revision,
            changes: changes
        )
    }
}

// MARK: - Thread and turn merging

private extension CanonicalStateReducer {
    /// A turn's revision is the aggregate revision of everything projected inside
    /// that turn. Keeping this invariant in the reducer lets downstream projections
    /// discover item- and intent-only changes from a current snapshot without
    /// replaying retained change-set keys.
    func propagateAggregateTurnRevisions(
        for changes: [CanonicalStateChange],
        revision: StateRevision,
        graph: inout CanonicalStateGraph
    ) {
        var affectedTurnKeys = Set(changes.compactMap(\.turnKey))
        for change in changes {
            let intentID: SubmissionIntentID?
            switch change {
            case .submissionIntentInserted(let id, _),
                 .submissionIntentUpdated(let id, _):
                intentID = id
            default:
                intentID = nil
            }
            guard let intentID,
                  let intent = graph.submissionIntents[intentID],
                  let turnID = intent.expectedTurnID else { continue }
            affectedTurnKeys.insert(.init(threadID: intent.threadID, turnID: turnID))
        }

        for key in affectedTurnKeys {
            guard var turn = graph.turns[key], turn.lastChangedRevision < revision else { continue }
            turn.lastChangedRevision = revision
            graph.turns[key] = turn
        }
    }

    func isWellFormed(_ mutation: CanonicalStateMutation) -> Bool {
        switch mutation {
        case .threadUpsert(let thread), .threadSnapshotReplaced(let thread):
            return thread.goal == nil || thread.goal?.threadID == thread.id

        case .threadRollbackReplaced(let thread, let turns, let items):
            let turnIDs = turns.map { $0.key.turnID }
            let retainedTurnIDs = Set(turnIDs)
            return (thread.goal == nil || thread.goal?.threadID == thread.id)
                && retainedTurnIDs.count == turns.count
                && turns.allSatisfy { $0.key.threadID == thread.id }
                && items.allSatisfy {
                    $0.key.threadID == thread.id && retainedTurnIDs.contains($0.key.turnID)
                }

        case .threadGoalReplaced(let id, let goal):
            return goal == nil || goal?.threadID == id

        case .turnSnapshot(let turn, let items, _), .turnStarted(let turn, let items):
            return items.allSatisfy { $0.key.turnKey == turn.key }

        case .turnCompleted(let turn, let items, _):
            return turn.status.isTerminal && items.allSatisfy { $0.key.turnKey == turn.key }

        default:
            return true
        }
    }

    func apply<Value>(
        _ update: CanonicalFieldUpdate<Value>,
        to value: inout Value?
    ) where Value: Sendable & Equatable {
        switch update {
        case .unchanged: break
        case .set(let updated): value = updated
        case .clear: value = nil
        }
    }

    mutating func removeThread(
        _ id: ThreadID,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        let itemKeys = graph.items.keys.filter { $0.threadID == id }.sorted()
        for key in itemKeys {
            graph.items.removeValue(forKey: key)
            discardOrphans(for: key)
            changes.append(.itemRemoved(key))
        }

        let remainingOrphans = orphanKeyOrder.filter { $0.threadID == id }
        for key in remainingOrphans {
            discardOrphans(for: key)
            changes.append(.orphanDeltaDropped(key))
        }

        let turnKeys = graph.turns.keys.filter { $0.threadID == id }.sorted()
        for key in turnKeys {
            graph.turns.removeValue(forKey: key)
            changes.append(.turnRemoved(key))
        }

        let intentIDs = graph.submissionIntents.values
            .filter { $0.threadID == id }
            .map(\.id)
            .sorted()
        for intentID in intentIDs {
            graph.submissionIntents.removeValue(forKey: intentID)
            changes.append(.submissionIntentRemoved(id: intentID, threadID: id))
        }

        if graph.threads.removeValue(forKey: id) != nil {
            graph.threadOrder.removeAll { $0 == id }
            changes.append(.threadRemoved(id))
        }
    }

    mutating func evictThreadDetail(
        _ id: ThreadID,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard var thread = graph.threads[id] else { return }
        let originalThread = thread
        let changesBeforeEviction = changes.count

        let latestTurnID = thread.turnOrder.last
        let latestTurn = latestTurnID.flatMap {
            graph.turns[TurnKey(threadID: id, turnID: $0)]
        }
        if let latestTurn {
            thread.retainedLatestTurn = .init(
                id: latestTurn.key.turnID,
                status: latestTurn.status
            )
        }

        let itemKeys = graph.items.keys.filter { $0.threadID == id }.sorted()
        for key in itemKeys {
            graph.items.removeValue(forKey: key)
            discardOrphans(for: key)
            changes.append(.itemRemoved(key))
        }

        let remainingOrphans = orphanKeyOrder.filter { $0.threadID == id }
        for key in remainingOrphans {
            discardOrphans(for: key)
            changes.append(.orphanDeltaDropped(key))
        }

        let turnKeys = graph.turns.keys.filter { $0.threadID == id }.sorted()
        for key in turnKeys {
            graph.turns.removeValue(forKey: key)
            changes.append(.turnRemoved(key))
        }

        thread.turnOrder.removeAll(keepingCapacity: false)
        thread.isLoaded = false
        thread.history.turnsCoverage = .notLoaded
        thread.history.resumeCut = nil
        thread.history.turnsPage = .init()
        thread.history.itemPagesByTurn.removeAll(keepingCapacity: false)
        if thread != originalThread {
            thread.lastChangedRevision = revision
            graph.threads[id] = thread
            changes.append(.threadDetailEvicted(id))
        } else if changes.count > changesBeforeEviction {
            // A malformed/partial graph can contain descendants without a
            // matching turn order. Their removals are already explicit.
            graph.threads[id] = thread
        }
    }

    mutating func upsertThread(
        _ incoming: CanonicalThread,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard var current = graph.threads[incoming.id] else {
            var inserted = incoming
            inserted.turnOrder = incoming.turnOrder.removingDuplicates()
            inserted.lastChangedRevision = revision
            graph.threads[incoming.id] = inserted
            if !graph.threadOrder.contains(incoming.id) {
                graph.threadOrder.append(incoming.id)
            }
            changes.append(.threadInserted(incoming.id))
            return
        }

        let original = current
        mergeMetadata(from: incoming.metadata, into: &current.metadata)
        // Thread status is an exact server fact, including `notLoaded` after close.
        current.status = incoming.status
        current.turnOrder = mergeOrder(existing: current.turnOrder, incoming: incoming.turnOrder)
        if incoming.history != CanonicalHistoryState() {
            let wasStale = current.history.isStaleAfterReconnect
            mergeHistory(from: incoming.history, into: &current.history)
            current.history.isStaleAfterReconnect = wasStale || incoming.history.isStaleAfterReconnect
        }
        if let value = incoming.isArchived { current.isArchived = value }
        if incoming.isLoaded { current.isLoaded = true }
        current.connectedEnvironmentIDs.formUnion(incoming.connectedEnvironmentIDs)
        if let value = incoming.goal { current.goal = value }
        if let value = incoming.settings { current.settings = value }
        current.consistency = mergeConsistency(current.consistency, incoming.consistency)

        guard current != original else { return }
        current.lastChangedRevision = revision
        graph.threads[incoming.id] = current
        changes.append(.threadUpdated(incoming.id))
    }

    mutating func replaceThreadSnapshot(
        _ incoming: CanonicalThread,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard var current = graph.threads[incoming.id] else {
            var inserted = incoming
            inserted.turnOrder = incoming.turnOrder.removingDuplicates()
            inserted.lastChangedRevision = revision
            graph.threads[incoming.id] = inserted
            if !graph.threadOrder.contains(incoming.id) { graph.threadOrder.append(incoming.id) }
            changes.append(.threadInserted(incoming.id))
            return
        }

        let original = current
        // A generated full Thread object is authoritative for server-owned metadata,
        // including nullable fields. Local lifecycle and richer loaded history survive.
        current.metadata = incoming.metadata
        current.status = incoming.status
        current.turnOrder = mergeOrder(existing: current.turnOrder, incoming: incoming.turnOrder)
        let wasStale = current.history.isStaleAfterReconnect
        mergeHistory(from: incoming.history, into: &current.history)
        // Only an explicit history replace after resume may clear reconnect staleness.
        current.history.isStaleAfterReconnect = wasStale || incoming.history.isStaleAfterReconnect
        if let value = incoming.isArchived { current.isArchived = value }
        if incoming.isLoaded { current.isLoaded = true }
        current.connectedEnvironmentIDs.formUnion(incoming.connectedEnvironmentIDs)
        if let value = incoming.goal { current.goal = value }
        if let value = incoming.settings { current.settings = value }
        current.consistency = mergeConsistency(current.consistency, incoming.consistency)

        guard current != original else { return }
        current.lastChangedRevision = revision
        graph.threads[incoming.id] = current
        changes.append(.threadUpdated(incoming.id))
    }

    mutating func replaceThreadRollback(
        thread incomingThread: CanonicalThread,
        turns incomingTurns: [CanonicalTurn],
        items incomingItems: [CanonicalItem],
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        let incomingTurnIDs = incomingTurns.map { $0.key.turnID }
        let retainedTurnIDs = Set(incomingTurnIDs)
        guard retainedTurnIDs.count == incomingTurns.count,
              incomingTurns.allSatisfy({ $0.key.threadID == incomingThread.id }),
              incomingItems.allSatisfy({
                  $0.key.threadID == incomingThread.id && retainedTurnIDs.contains($0.key.turnID)
              })
        else {
            // A malformed destructive payload must not partially mutate canonical state.
            return
        }

        replaceThreadSnapshot(
            incomingThread,
            revision: revision,
            graph: &graph,
            changes: &changes
        )

        let retainedTurnKeys = Set(incomingTurns.map(\.key))
        let removedItemKeys = graph.items.keys
            .filter { $0.threadID == incomingThread.id && !retainedTurnKeys.contains($0.turnKey) }
            .sorted()
        for key in removedItemKeys {
            graph.items.removeValue(forKey: key)
            discardOrphans(for: key)
            changes.append(.itemRemoved(key))
        }

        let removedTurnKeys = graph.turns.keys
            .filter { $0.threadID == incomingThread.id && !retainedTurnKeys.contains($0) }
            .sorted()
        for key in removedTurnKeys {
            graph.turns.removeValue(forKey: key)
            changes.append(.turnRemoved(key))
        }

        let removedOrphanKeys = orphanKeyOrder.filter {
            $0.threadID == incomingThread.id && !retainedTurnIDs.contains($0.turnID)
        }
        for key in removedOrphanKeys {
            discardOrphans(for: key)
            changes.append(.orphanDeltaDropped(key))
        }

        let itemsByTurn = Dictionary(grouping: incomingItems, by: { $0.key.turnKey })
        for turn in incomingTurns {
            let turnItems = itemsByTurn[turn.key] ?? []
            mergeTurn(
                turn,
                items: turnItems,
                itemPolicy: turn.itemsCoverage == .full
                    ? .authoritativeReplacement
                    : .mergePreservingExistingOrder,
                isCompletion: false,
                revision: revision,
                graph: &graph,
                changes: &changes
            )
        }

        guard var materializedThread = graph.threads[incomingThread.id] else { return }
        let suppliedTurnIDs = Set(incomingTurnIDs)
        let authoritativeOrder = (
            incomingThread.turnOrder.filter(suppliedTurnIDs.contains) + incomingTurnIDs
        ).removingDuplicates()
        if materializedThread.turnOrder != authoritativeOrder {
            materializedThread.turnOrder = authoritativeOrder
            materializedThread.lastChangedRevision = revision
            graph.threads[incomingThread.id] = materializedThread
        }
        changes.append(.threadTurnsReplaced(incomingThread.id))
    }

    mutating func mergeTurn(
        _ incoming: CanonicalTurn,
        items: [CanonicalItem],
        itemPolicy: CanonicalItemCollectionMergePolicy,
        isCompletion: Bool,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        let isHistoryPage = itemPolicy == .historyPage
        let insertsHistoricalTurn = isHistoryPage && graph.turns[incoming.key] == nil
        ensureTurn(incoming.key, revision: revision, graph: &graph, changes: &changes)
        guard var current = graph.turns[incoming.key] else { return }
        let original = current

        if insertsHistoricalTurn,
           var thread = graph.threads[incoming.key.threadID]
        {
            thread.turnOrder.removeAll { $0 == incoming.key.turnID }
            thread.turnOrder.insert(incoming.key.turnID, at: 0)
            thread.lastChangedRevision = revision
            graph.threads[incoming.key.threadID] = thread
        }

        if isCompletion {
            current.status = incoming.status
            current.error = incoming.error
        } else if !current.status.isTerminal {
            current.status = incoming.status
            if let error = incoming.error {
                current.error = error
            }
        }

        if let value = incoming.startedAt, !isHistoryPage || current.startedAt == nil {
            current.startedAt = value
        }
        if let value = incoming.completedAt, !isHistoryPage || current.completedAt == nil {
            current.completedAt = value
        }
        if let value = incoming.duration, !isHistoryPage || current.duration == nil {
            current.duration = value
        }
        current.itemsCoverage = current.itemsCoverage.merged(with: incoming.itemsCoverage)
        current.itemsConsistency = mergeConsistency(current.itemsConsistency, incoming.itemsConsistency)
        if let value = incoming.plan, !isHistoryPage || current.plan == nil {
            current.plan = value
            current.planExplanation = incoming.planExplanation
        }
        if let value = incoming.diff, !isHistoryPage || current.diff == nil { current.diff = value }
        if let value = incoming.tokenUsage, !isHistoryPage || current.tokenUsage == nil {
            current.tokenUsage = value
        }
        if let value = incoming.moderationMetadata,
           !isHistoryPage || current.moderationMetadata == nil
        {
            current.moderationMetadata = value
        }
        current.extensions.merge(incoming.extensions) { current, new in
            isHistoryPage ? current : new
        }

        switch itemPolicy {
        case .mergePreservingExistingOrder:
            current.itemOrder = mergeOrder(
                existing: current.itemOrder,
                incoming: incoming.itemOrder + items.map { $0.key.itemID }
            )
        case .mergeIncomingFirst, .historyPage:
            current.itemOrder = mergeOrder(
                existing: (incoming.itemOrder + items.map { $0.key.itemID }).removingDuplicates(),
                incoming: current.itemOrder
            )
        case .authoritativeReplacement:
            // Absence is authoritative only at full coverage.
            if incoming.itemsCoverage == .full {
                let suppliedIDs = Set(items.map { $0.key.itemID })
                let orderedSuppliedIDs = incoming.itemOrder.filter(suppliedIDs.contains)
                current.itemOrder = (orderedSuppliedIDs + items.map { $0.key.itemID }).removingDuplicates()
                current.itemsCoverage = .full
                current.itemsConsistency = incoming.itemsConsistency == .authoritative ? .authoritative : current.itemsConsistency
            }
        }

        if current != original {
            current.lastChangedRevision = revision
            graph.turns[incoming.key] = current
            changes.append(.turnUpdated(incoming.key))
        }

        for item in items where item.key.turnKey == incoming.key {
            mergeItem(
                item,
                preservingCompleted: isHistoryPage,
                revision: revision,
                graph: &graph,
                changes: &changes
            )
        }

        if itemPolicy == .authoritativeReplacement, incoming.itemsCoverage == .full {
            replaceItemsAuthoritatively(
                in: incoming.key,
                retaining: Set(items.map(\.key)),
                revision: revision,
                graph: &graph,
                changes: &changes
            )
        }
    }

    func mergeMetadata(
        from incoming: CanonicalThreadMetadata,
        into current: inout CanonicalThreadMetadata
    ) {
        if let value = incoming.agentNickname { current.agentNickname = value }
        if let value = incoming.agentRole { current.agentRole = value }
        if let value = incoming.cliVersion { current.cliVersion = value }
        if let value = incoming.createdAt { current.createdAt = value }
        if let value = incoming.cwd { current.cwd = value }
        if let value = incoming.ephemeral { current.ephemeral = value }
        if let value = incoming.extra { current.extra = value }
        if let value = incoming.forkedFromID { current.forkedFromID = value }
        if let value = incoming.gitInfo { current.gitInfo = value }
        if let value = incoming.modelProvider { current.modelProvider = value }
        if let value = incoming.name { current.name = value }
        if let value = incoming.parentThreadID { current.parentThreadID = value }
        if let value = incoming.path { current.path = value }
        if let value = incoming.preview { current.preview = value }
        if let value = incoming.recencyAt { current.recencyAt = value }
        if let value = incoming.sessionID { current.sessionID = value }
        if let value = incoming.source { current.source = value }
        if let value = incoming.threadSource { current.threadSource = value }
        if let value = incoming.updatedAt { current.updatedAt = value }
        current.extensions.merge(incoming.extensions) { _, new in new }
    }

    func mergeHistory(
        from incoming: CanonicalHistoryState,
        into current: inout CanonicalHistoryState
    ) {
        if let value = incoming.mode { current.mode = value }
        current.turnsCoverage = current.turnsCoverage.merged(with: incoming.turnsCoverage)
        if let value = incoming.resumeCut { current.resumeCut = value }
        let emptyPage = CanonicalPageCursorState()
        if incoming.turnsPage != emptyPage || current.turnsPage == emptyPage {
            current.turnsPage = incoming.turnsPage
        }
        current.itemPagesByTurn.merge(incoming.itemPagesByTurn) { _, new in new }
        current.protocolMetadata.merge(incoming.protocolMetadata) { _, new in new }
        current.isStaleAfterReconnect = incoming.isStaleAfterReconnect
    }

    func mergeConsistency(_ current: StateConsistency, _ incoming: StateConsistency) -> StateConsistency {
        if incoming == .uncertain { return .uncertain }
        if incoming == .authoritative { return .authoritative }
        if current == .authoritative || current == .uncertain { return current }
        return .partial
    }
}

// MARK: - Item authority and streaming

private extension CanonicalStateReducer {
    mutating func mergeItem(
        _ incoming: CanonicalItem,
        preservingCompleted: Bool = false,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        switch incoming.authority {
        case .completed:
            if preservingCompleted,
               graph.items[incoming.key]?.authority == .completed
            {
                // Core persists before listener delivery, but its SQLite
                // projection may lag. Once the live wire completed an item,
                // an overlapping history row can only be equal or older.
                return
            }
            completeItem(
                incoming,
                authoritativePayload: incoming.consistency == .authoritative,
                revision: revision,
                graph: &graph,
                changes: &changes
            )
        case .started:
            startItem(incoming, revision: revision, graph: &graph, changes: &changes)
        case .placeholder:
            ensureItemOrder(incoming.key, revision: revision, graph: &graph, changes: &changes)
            guard var current = graph.items[incoming.key] else {
                var inserted = incoming
                inserted.lastChangedRevision = revision
                graph.items[incoming.key] = inserted
                changes.append(.itemInserted(incoming.key))
                return
            }
            guard current.authority == .placeholder else { return }
            let original = current
            current.kind = incoming.kind
            current.payload = incoming.payload
            current.liveFields.merge(incoming.liveFields) { _, new in new }
            current.clientUserMessageID = incoming.clientUserMessageID ?? current.clientUserMessageID
            current.consistency = mergeConsistency(current.consistency, incoming.consistency)
            guard current != original else { return }
            current.lastChangedRevision = revision
            graph.items[incoming.key] = current
            changes.append(.itemUpdated(incoming.key))
        }
    }

    mutating func startItem(
        _ incoming: CanonicalItem,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        ensureItemOrder(incoming.key, revision: revision, graph: &graph, changes: &changes)

        if var current = graph.items[incoming.key] {
            if current.authority == .completed {
                // A late start may fill a missing start timestamp, but never replace final payload.
                if current.startedAt == nil, let startedAt = incoming.startedAt {
                    current.startedAt = startedAt
                    current.lastChangedRevision = revision
                    graph.items[incoming.key] = current
                    changes.append(.itemUpdated(incoming.key))
                }
                discardOrphans(for: incoming.key)
                return
            }

            let original = current
            current.kind = incoming.kind
            current.payload = incoming.payload
            current.liveFields.merge(incoming.liveFields) { _, new in new }
            current.authority = .started
            current.startedAt = incoming.startedAt ?? current.startedAt
            current.clientUserMessageID = incoming.clientUserMessageID ?? current.clientUserMessageID
            current.consistency = mergeConsistency(current.consistency, incoming.consistency)
            if let buffered = takeOrphans(for: incoming.key) {
                for orphan in buffered {
                    current.liveOverlay.append(orphan.delta)
                }
            }
            guard current != original else { return }
            current.lastChangedRevision = revision
            graph.items[incoming.key] = current
            changes.append(.itemStarted(incoming.key))
            reconcileSubmissionIntent(for: current, revision: revision, graph: &graph, changes: &changes)
            return
        }

        var inserted = incoming
        inserted.authority = .started
        if let buffered = takeOrphans(for: incoming.key) {
            for orphan in buffered {
                inserted.liveOverlay.append(orphan.delta)
            }
        }
        inserted.lastChangedRevision = revision
        graph.items[incoming.key] = inserted
        changes.append(.itemInserted(incoming.key))
        changes.append(.itemStarted(incoming.key))
        reconcileSubmissionIntent(for: inserted, revision: revision, graph: &graph, changes: &changes)
    }

    mutating func appendDelta(
        _ delta: ItemDelta,
        to key: ItemKey,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard var item = graph.items[key], item.authority >= .started else {
            let dropKeys = bufferOrphan(delta, for: key)
            if orphanDeltas[key] != nil {
                changes.append(.orphanDeltaBuffered(key))
            }
            changes.append(contentsOf: dropKeys.map(CanonicalStateChange.orphanDeltaDropped))
            return
        }
        guard item.authority != .completed else { return }

        // Equal consecutive chunks are valid protocol data and are appended verbatim.
        item.liveOverlay.append(delta)
        item.lastChangedRevision = revision
        graph.items[key] = item
        changes.append(.itemDeltaAppended(key))
    }

    mutating func completeItem(
        _ incoming: CanonicalItem,
        authoritativePayload: Bool,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        ensureItemOrder(incoming.key, revision: revision, graph: &graph, changes: &changes)
        let previous = graph.items[incoming.key]
        var completed = incoming
        completed.authority = .completed
        completed.startedAt = incoming.startedAt ?? previous?.startedAt
        completed.completedAt = incoming.completedAt ?? previous?.completedAt
        completed.clientUserMessageID = incoming.clientUserMessageID ?? previous?.clientUserMessageID
        if authoritativePayload {
            completed.liveOverlay = .init()
            completed.liveFields = [:]
            completed.consistency = .authoritative
        } else if let previous {
            // Summary/history objects are lifecycle-authoritative but may omit content.
            // Preserve richer streamed/full fields until a full item resync arrives.
            var mergedPayload = previous.payload
            mergedPayload.merge(incoming.payload) { _, new in new }
            completed.payload = mergedPayload
            completed.liveOverlay = previous.liveOverlay
            completed.liveFields = previous.liveFields.merging(incoming.liveFields) { _, new in new }
            completed.consistency = mergeConsistency(previous.consistency, incoming.consistency)
        } else {
            completed.consistency = incoming.consistency
        }
        discardOrphans(for: incoming.key)

        completed.lastChangedRevision = previous?.lastChangedRevision ?? .zero
        guard previous != completed else { return }
        completed.lastChangedRevision = revision
        graph.items[incoming.key] = completed
        if previous == nil {
            changes.append(.itemInserted(incoming.key))
        }
        changes.append(.itemCompleted(incoming.key))
        reconcileSubmissionIntent(for: completed, revision: revision, graph: &graph, changes: &changes)
    }

    mutating func replaceItemsAuthoritatively(
        in turnKey: TurnKey,
        retaining retainedKeys: Set<ItemKey>,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        let removedKeys = graph.items.keys
            .filter { $0.turnKey == turnKey && !retainedKeys.contains($0) }
            .sorted()
        for key in removedKeys {
            graph.items.removeValue(forKey: key)
            discardOrphans(for: key)
            changes.append(.itemRemoved(key))
        }

        guard var turn = graph.turns[turnKey] else { return }
        let retainedOrder = turn.itemOrder.filter {
            retainedKeys.contains(ItemKey(threadID: turnKey.threadID, turnID: turnKey.turnID, itemID: $0))
        }
        if turn.itemOrder != retainedOrder {
            turn.itemOrder = retainedOrder
            turn.lastChangedRevision = revision
            graph.turns[turnKey] = turn
            changes.append(.turnUpdated(turnKey))
        }

        let unrelatedOrphanKeys = orphanKeyOrder.filter {
            $0.turnKey == turnKey && !retainedKeys.contains($0)
        }
        for key in unrelatedOrphanKeys {
            discardOrphans(for: key)
        }
    }

    mutating func reconcileSubmissionIntent(
        for item: CanonicalItem,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard let id = item.clientUserMessageID,
              var intent = graph.submissionIntents[id],
              intent.threadID == item.key.threadID,
              intent.state != .reconciled(item: item.key)
        else { return }
        intent.state = .reconciled(item: item.key)
        intent.lastChangedRevision = revision
        graph.submissionIntents[id] = intent
        changes.append(.submissionIntentUpdated(id: id, threadID: intent.threadID))
    }
}

// MARK: - Graph insertion and bounded orphan storage

private extension CanonicalStateReducer {
    func ensureThread(
        _ id: ThreadID,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        guard graph.threads[id] == nil else { return }
        graph.threads[id] = CanonicalThread(id: id, lastChangedRevision: revision)
        if !graph.threadOrder.contains(id) { graph.threadOrder.append(id) }
        changes.append(.threadInserted(id))
    }

    func ensureTurn(
        _ key: TurnKey,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        ensureThread(key.threadID, revision: revision, graph: &graph, changes: &changes)
        guard graph.turns[key] == nil else { return }
        graph.turns[key] = CanonicalTurn(key: key, lastChangedRevision: revision)
        if var thread = graph.threads[key.threadID], !thread.turnOrder.contains(key.turnID) {
            thread.turnOrder.append(key.turnID)
            thread.lastChangedRevision = revision
            graph.threads[key.threadID] = thread
        }
        changes.append(.turnInserted(key))
    }

    func ensureItemOrder(
        _ key: ItemKey,
        revision: StateRevision,
        graph: inout CanonicalStateGraph,
        changes: inout [CanonicalStateChange]
    ) {
        ensureTurn(key.turnKey, revision: revision, graph: &graph, changes: &changes)
        guard var turn = graph.turns[key.turnKey], !turn.itemOrder.contains(key.itemID) else { return }
        turn.itemOrder.append(key.itemID)
        turn.lastChangedRevision = revision
        graph.turns[key.turnKey] = turn
        changes.append(.turnUpdated(key.turnKey))
    }

    mutating func bufferOrphan(_ delta: ItemDelta, for key: ItemKey) -> [ItemKey] {
        if orphanDeltas[key] == nil {
            orphanDeltas[key] = []
            orphanKeyOrder.append(key)
        }
        let entry = OrphanDelta(delta: delta, utf8ByteCount: delta.utf8ByteCount)
        orphanDeltas[key, default: []].append(entry)
        orphanDeltaCount += 1
        orphanUTF8ByteCount += entry.utf8ByteCount

        var droppedKeys: [ItemKey] = []
        while (orphanDeltas[key]?.count ?? 0) > configuration.maximumOrphanDeltasPerItem {
            if dropOldestOrphan(for: key) { droppedKeys.append(key) }
        }
        while orphanDeltaCount > configuration.maximumOrphanDeltaCount
            || orphanUTF8ByteCount > configuration.maximumOrphanUTF8Bytes {
            guard let oldestKey = orphanKeyOrder.first else { break }
            if dropOldestOrphan(for: oldestKey) { droppedKeys.append(oldestKey) }
        }
        return droppedKeys
    }

    mutating func dropOldestOrphan(for key: ItemKey) -> Bool {
        guard var entries = orphanDeltas[key], !entries.isEmpty else {
            orphanDeltas.removeValue(forKey: key)
            orphanKeyOrder.removeAll { $0 == key }
            return false
        }
        let dropped = entries.removeFirst()
        orphanDeltaCount -= 1
        orphanUTF8ByteCount -= dropped.utf8ByteCount
        if entries.isEmpty {
            orphanDeltas.removeValue(forKey: key)
            orphanKeyOrder.removeAll { $0 == key }
        } else {
            orphanDeltas[key] = entries
        }
        return true
    }

    private mutating func takeOrphans(for key: ItemKey) -> [OrphanDelta]? {
        guard let entries = orphanDeltas.removeValue(forKey: key) else { return nil }
        orphanKeyOrder.removeAll { $0 == key }
        orphanDeltaCount -= entries.count
        orphanUTF8ByteCount -= entries.reduce(into: 0) { $0 += $1.utf8ByteCount }
        return entries
    }

    mutating func discardOrphans(for key: ItemKey) {
        _ = takeOrphans(for: key)
    }

    func mergeOrder<ID: Hashable>(existing: [ID], incoming: [ID]) -> [ID] {
        var result = existing
        var seen = Set(existing)
        for id in incoming where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}

private extension CanonicalStateChange {
    var threadID: ThreadID? {
        switch self {
        case .threadInserted(let id), .threadUpdated(let id), .threadTurnsReplaced(let id),
             .threadRemoved(let id),
             .threadLifecycleUpdated(let id), .threadNameReplaced(let id),
             .threadEnvironmentUpdated(let id),
             .threadGoalReplaced(let id), .threadSettingsReplaced(let id),
             .threadHistoryUpdated(let id), .threadDetailEvicted(let id): id
        case .turnInserted(let key), .turnUpdated(let key), .turnRemoved(let key), .turnStarted(let key),
             .turnCompleted(let key), .planReplaced(let key), .diffReplaced(let key),
             .tokenUsageReplaced(let key), .moderationMetadataReplaced(let key),
             .turnExtensionReplaced(let key), .turnItemsMarkedUncertain(let key): key.threadID
        case .turnErrorUpdated(let key, _): key.threadID
        case .itemInserted(let key), .itemUpdated(let key), .itemStarted(let key),
             .itemDeltaAppended(let key), .itemCompleted(let key), .itemRemoved(let key),
             .itemLiveFieldReplaced(let key), .orphanDeltaBuffered(let key),
             .orphanDeltaDropped(let key): key.threadID
        case .submissionIntentInserted(_, let threadID), .submissionIntentUpdated(_, let threadID),
             .submissionIntentRemoved(_, let threadID): threadID
        case .accountUpdated, .mcpServerStartupStatusUpdated: nil
        }
    }

    var turnKey: TurnKey? {
        switch self {
        case .turnInserted(let key), .turnUpdated(let key), .turnRemoved(let key), .turnStarted(let key),
             .turnCompleted(let key), .planReplaced(let key), .diffReplaced(let key),
             .tokenUsageReplaced(let key), .moderationMetadataReplaced(let key),
             .turnExtensionReplaced(let key), .turnItemsMarkedUncertain(let key): key
        case .turnErrorUpdated(let key, _): key
        case .itemInserted(let key), .itemUpdated(let key), .itemStarted(let key),
             .itemDeltaAppended(let key), .itemCompleted(let key), .itemRemoved(let key),
             .itemLiveFieldReplaced(let key), .orphanDeltaBuffered(let key),
             .orphanDeltaDropped(let key): key.turnKey
        case .accountUpdated, .mcpServerStartupStatusUpdated,
             .threadInserted, .threadUpdated, .threadTurnsReplaced, .threadRemoved,
             .threadLifecycleUpdated, .threadNameReplaced, .threadEnvironmentUpdated, .threadGoalReplaced,
             .threadSettingsReplaced, .threadHistoryUpdated, .threadDetailEvicted,
             .submissionIntentInserted,
             .submissionIntentUpdated, .submissionIntentRemoved: nil
        }
    }

    var itemKey: ItemKey? {
        switch self {
        case .itemInserted(let key), .itemUpdated(let key), .itemStarted(let key),
             .itemDeltaAppended(let key), .itemCompleted(let key), .itemRemoved(let key),
             .itemLiveFieldReplaced(let key), .orphanDeltaBuffered(let key),
             .orphanDeltaDropped(let key): key
        default: nil
        }
    }
}

private extension ItemDelta {
    var utf8ByteCount: Int {
        switch self {
        case .agentMessage(let value), .plan(let value), .commandOutput(let value),
             .fileChangeOutput(let value), .mcpProgress(let value):
            value.utf8.count
        case .reasoningSummary(_, let value), .reasoningContent(_, let value):
            value.utf8.count
        case .terminalInteraction(let processID, let stdin):
            processID.utf8.count + stdin.utf8.count
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
