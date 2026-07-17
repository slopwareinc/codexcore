import Foundation

/// Coarse fields that changed in one canonical-state transaction.
///
/// The mask is invalidation metadata, not a second copy of canonical state. A
/// consumer uses it to decide which scoped snapshot or projection to refresh.
public struct StateFieldMask: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let connection = Self(rawValue: 1 << 0)
    public static let account = Self(rawValue: 1 << 1)
    public static let threadMetadata = Self(rawValue: 1 << 2)
    public static let threadStatus = Self(rawValue: 1 << 3)
    public static let threadRelationships = Self(rawValue: 1 << 4)
    public static let threadHistory = Self(rawValue: 1 << 5)
    public static let turnMetadata = Self(rawValue: 1 << 6)
    public static let turnStatus = Self(rawValue: 1 << 7)
    public static let itemStructure = Self(rawValue: 1 << 8)
    public static let itemLifecycle = Self(rawValue: 1 << 9)
    public static let itemContent = Self(rawValue: 1 << 10)
    public static let plan = Self(rawValue: 1 << 11)
    public static let diff = Self(rawValue: 1 << 12)
    public static let usage = Self(rawValue: 1 << 13)
    public static let requests = Self(rawValue: 1 << 14)
    public static let submissionIntents = Self(rawValue: 1 << 15)
    public static let operations = Self(rawValue: 1 << 16)
    public static let diagnostics = Self(rawValue: 1 << 17)
    public static let turnStructure = Self(rawValue: 1 << 18)
    public static let threadGoal = Self(rawValue: 1 << 19)
    public static let threadSettings = Self(rawValue: 1 << 20)
    public static let moderation = Self(rawValue: 1 << 21)
    public static let extensions = Self(rawValue: 1 << 22)
    public static let mcpServerStartup = Self(rawValue: 1 << 23)

    public static let thread: Self = [
        .threadMetadata,
        .threadStatus,
        .threadRelationships,
        .threadHistory,
        .threadGoal,
        .threadSettings,
    ]

    public static let turn: Self = [
        .turnMetadata,
        .turnStatus,
        .turnStructure,
        .itemStructure,
        .plan,
        .diff,
        .usage,
    ]

    public static let item: Self = [
        .itemStructure,
        .itemLifecycle,
        .itemContent,
    ]

    public static let all: Self = [
        .connection,
        .account,
        .thread,
        .turn,
        .item,
        .requests,
        .submissionIntents,
        .operations,
        .diagnostics,
        .moderation,
        .extensions,
        .mcpServerStartup,
    ]
}

/// Entity selection for a canonical-state observation.
///
/// Thread and turn observations include their descendants. For example, a
/// thread observation sees item-content changes for every turn in that thread.
public enum StateEntityScope: Sendable, Hashable {
    case all
    case global
    case threads(Set<ThreadID>)
    case turns(Set<TurnKey>)
    case items(Set<ItemKey>)

    public static func thread(_ id: ThreadID) -> Self {
        .threads([id])
    }

    public static func turn(_ key: TurnKey) -> Self {
        .turns([key])
    }

    public static func item(_ key: ItemKey) -> Self {
        .items([key])
    }
}

/// A field-and-entity filter used by projections and other state consumers.
public struct StateObservationScope: Sendable, Hashable {
    public let entities: StateEntityScope
    public let fields: StateFieldMask

    public init(entities: StateEntityScope = .all, fields: StateFieldMask = .all) {
        self.entities = entities
        self.fields = fields
    }

    public static let all = Self()

    public static func global(fields: StateFieldMask = .all) -> Self {
        Self(entities: .global, fields: fields)
    }

    public static func thread(_ id: ThreadID, fields: StateFieldMask = .all) -> Self {
        Self(entities: .thread(id), fields: fields)
    }

    public static func turn(_ key: TurnKey, fields: StateFieldMask = .all) -> Self {
        Self(entities: .turn(key), fields: fields)
    }

    public static func item(_ key: ItemKey, fields: StateFieldMask = .all) -> Self {
        Self(entities: .item(key), fields: fields)
    }
}

/// Compact invalidation metadata for one committed canonical-state transaction.
public struct StateChangeSet: Codable, Sendable, Hashable {
    public let revision: StateRevision
    public let fields: StateFieldMask
    public let threadIDs: Set<ThreadID>
    public let turnKeys: Set<TurnKey>
    public let itemKeys: Set<ItemKey>

    /// Conservative storage estimate used by the bounded journal.
    public let estimatedByteCount: Int

    public init(
        revision: StateRevision,
        fields: StateFieldMask,
        threadIDs: Set<ThreadID> = [],
        turnKeys: Set<TurnKey> = [],
        itemKeys: Set<ItemKey> = [],
        estimatedByteCount: Int? = nil
    ) {
        self.revision = revision
        self.fields = fields
        self.threadIDs = threadIDs
        self.turnKeys = turnKeys
        self.itemKeys = itemKeys
        self.estimatedByteCount = max(
            1,
            estimatedByteCount ?? Self.estimateStorage(
                threadIDs: threadIDs,
                turnKeys: turnKeys,
                itemKeys: itemKeys
            )
        )
    }

    /// Converts the reducer's exact change batch into scoped invalidation data.
    public init(_ batch: CanonicalStateChangeBatch) {
        self.init(
            revision: batch.revision,
            fields: batch.changes.reduce(into: StateFieldMask()) { fields, change in
                fields.formUnion(change.observationFields)
            },
            threadIDs: batch.affectedThreadIDs,
            turnKeys: batch.affectedTurnKeys,
            itemKeys: batch.affectedItemKeys
        )
    }

    /// Returns whether this transaction can affect the supplied observation.
    public func affects(_ scope: StateObservationScope) -> Bool {
        guard !fields.intersection(scope.fields).isEmpty else { return false }

        switch scope.entities {
        case .all:
            return true

        case .global:
            return threadIDs.isEmpty && turnKeys.isEmpty && itemKeys.isEmpty

        case let .threads(observed):
            guard !observed.isEmpty else { return false }
            return !threadIDs.isDisjoint(with: observed)
                || turnKeys.contains { observed.contains($0.threadID) }
                || itemKeys.contains { observed.contains($0.threadID) }

        case let .turns(observed):
            guard !observed.isEmpty else { return false }
            return !turnKeys.isDisjoint(with: observed)
                || itemKeys.contains { observed.contains($0.turnKey) }

        case let .items(observed):
            return !observed.isEmpty && !itemKeys.isDisjoint(with: observed)
        }
    }

    /// Narrows this change set to one observation. `nil` means it is unrelated.
    public func filtered(to scope: StateObservationScope) -> Self? {
        let matchingFields = fields.intersection(scope.fields)
        guard !matchingFields.isEmpty else { return nil }

        let matchingThreads: Set<ThreadID>
        let matchingTurns: Set<TurnKey>
        let matchingItems: Set<ItemKey>

        switch scope.entities {
        case .all:
            matchingThreads = threadIDs
            matchingTurns = turnKeys
            matchingItems = itemKeys

        case .global:
            guard threadIDs.isEmpty, turnKeys.isEmpty, itemKeys.isEmpty else { return nil }
            matchingThreads = []
            matchingTurns = []
            matchingItems = []

        case let .threads(observed):
            matchingThreads = threadIDs.intersection(observed)
            matchingTurns = Set(turnKeys.filter { observed.contains($0.threadID) })
            matchingItems = Set(itemKeys.filter { observed.contains($0.threadID) })

        case let .turns(observed):
            matchingThreads = []
            matchingTurns = turnKeys.intersection(observed)
            matchingItems = Set(itemKeys.filter { observed.contains($0.turnKey) })

        case let .items(observed):
            matchingThreads = []
            matchingTurns = []
            matchingItems = itemKeys.intersection(observed)
        }

        if matchingThreads.isEmpty, matchingTurns.isEmpty, matchingItems.isEmpty {
            switch scope.entities {
            case .all, .global:
                break
            case .threads, .turns, .items:
                return nil
            }
        }

        return Self(
            revision: revision,
            fields: matchingFields,
            threadIDs: matchingThreads,
            turnKeys: matchingTurns,
            itemKeys: matchingItems
        )
    }

    private static func estimateStorage(
        threadIDs: Set<ThreadID>,
        turnKeys: Set<TurnKey>,
        itemKeys: Set<ItemKey>
    ) -> Int {
        let fixedStorage = 128
        let collectionStorage = 24 * (threadIDs.count + turnKeys.count + itemKeys.count)
        let stringStorage = threadIDs.reduce(into: 0) { result, id in
            result += id.rawValue.utf8.count
        } + turnKeys.reduce(into: 0) { result, key in
            result += key.threadID.rawValue.utf8.count
            result += key.turnID.rawValue.utf8.count
        } + itemKeys.reduce(into: 0) { result, key in
            result += key.threadID.rawValue.utf8.count
            result += key.turnID.rawValue.utf8.count
            result += key.itemID.rawValue.utf8.count
        }
        return fixedStorage + collectionStorage + stringStorage
    }
}

private extension CanonicalStateChange {
    var observationFields: StateFieldMask {
        switch self {
        case .accountUpdated:
            .account

        case .mcpServerStartupStatusUpdated:
            .mcpServerStartup

        case .threadInserted, .threadUpdated, .threadRemoved:
            .thread

        case .threadLifecycleUpdated:
            .threadStatus

        case .threadEnvironmentUpdated:
            .threadMetadata

        case .threadNameReplaced:
            .threadMetadata

        case .threadGoalReplaced:
            .threadGoal

        case .threadSettingsReplaced:
            .threadSettings

        case .threadHistoryUpdated:
            .threadHistory

        case .threadDetailEvicted:
            [.threadStatus, .threadHistory, .turnStructure, .itemStructure]

        case .threadTurnsReplaced:
            .turnStructure

        case .turnInserted, .turnUpdated, .turnRemoved:
            .turn

        case .turnStarted, .turnCompleted:
            .turnStatus

        case .itemInserted, .itemUpdated:
            .item

        case .itemStarted:
            [.itemStructure, .itemLifecycle]

        case .itemDeltaAppended:
            .itemContent

        case .itemCompleted:
            [.itemLifecycle, .itemContent]

        case .itemRemoved:
            .itemStructure

        case .planReplaced:
            .plan

        case .diffReplaced:
            .diff

        case .turnErrorUpdated:
            [.turnMetadata, .diagnostics]

        case .tokenUsageReplaced:
            .usage

        case .moderationMetadataReplaced:
            .moderation

        case .turnExtensionReplaced:
            .extensions

        case .itemLiveFieldReplaced:
            .itemContent

        case .turnItemsMarkedUncertain:
            [.itemStructure, .diagnostics]

        case .submissionIntentInserted, .submissionIntentUpdated, .submissionIntentRemoved:
            .submissionIntents

        case .orphanDeltaBuffered, .orphanDeltaDropped:
            [.itemContent, .diagnostics]
        }
    }
}

/// Identifier for one registered observation. It is local to one journal.
public struct StateObservationID: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Coalescible wake-up. Consumers recover exact invalidations through `catchUp`.
public struct StateRevisionSignal: Sendable, Hashable {
    public let latestRevision: StateRevision

    public init(latestRevision: StateRevision) {
        self.latestRevision = latestRevision
    }
}

/// An atomic seed and revision paired with a lossy, one-element wake-up stream.
///
/// The signal stream is deliberately not the data plane. After a signal, call the
/// owning state engine's catch-up method with `id` and the last applied revision.
public struct StateObservation<Seed: Sendable>: Sendable {
    public let id: StateObservationID
    public let scope: StateObservationScope
    public let seed: Seed
    public let revision: StateRevision
    public let signals: AsyncStream<StateRevisionSignal>

    internal init(
        id: StateObservationID,
        scope: StateObservationScope,
        seed: Seed,
        revision: StateRevision,
        signals: AsyncStream<StateRevisionSignal>
    ) {
        self.id = id
        self.scope = scope
        self.seed = seed
        self.revision = revision
        self.signals = signals
    }
}

/// Result of catching a state observation up from its last applied revision.
public enum StateCatchUp: Sendable, Hashable {
    /// Scoped invalidations retained after the supplied revision. `through` also
    /// advances across unrelated transactions that were intentionally filtered.
    case changes([StateChangeSet], through: StateRevision)

    /// The consumer fell behind relevant retained history or supplied an invalid
    /// cursor. It must obtain a new atomic scoped seed at this revision or newer.
    case reset(to: StateRevision)
}

public struct StateChangeJournalLimits: Sendable, Hashable {
    public let maxChangeSets: Int
    public let maxEstimatedBytes: Int

    public init(maxChangeSets: Int = 2_048, maxEstimatedBytes: Int = 2 * 1_024 * 1_024) {
        precondition(maxChangeSets > 0, "State change journal count must be positive")
        precondition(maxEstimatedBytes > 0, "State change journal byte budget must be positive")
        self.maxChangeSets = maxChangeSets
        self.maxEstimatedBytes = maxEstimatedBytes
    }
}

enum StateChangeJournalError: Error, Sendable, Equatable {
    case noncontiguousRevision(expected: StateRevision, received: StateRevision)
    case revisionExhausted
}

/// Byte- and count-bounded revision history owned by one canonical-state actor.
///
/// This class intentionally does not conform to `Sendable`: all journal methods
/// must run in the same isolation domain as the canonical state transaction. The
/// internal subscriber registry is locked only because AsyncStream termination can
/// arrive from a consumer executor.
final class StateChangeJournal {
    let limits: StateChangeJournalLimits
    private(set) var currentRevision: StateRevision
    private(set) var retainedChangeSetCount = 0
    private(set) var retainedEstimatedBytes = 0

    private var ring: [StateChangeSet?]
    private var head = 0
    private let observers = StateObservationRegistry()

    init(seedRevision: StateRevision = .zero, limits: StateChangeJournalLimits = .init()) {
        self.currentRevision = seedRevision
        self.limits = limits
        self.ring = Array(repeating: nil, count: limits.maxChangeSets)
    }

    deinit {
        observers.finishAll()
    }

    /// Atomically captures a scoped seed, its exact revision, and a wake-up stream.
    /// The caller must invoke this synchronously from the canonical state owner.
    func observe<Seed: Sendable>(
        scope: StateObservationScope = .all,
        seed makeSeed: () -> Seed
    ) -> StateObservation<Seed> {
        let revision = currentRevision
        let seed = makeSeed()
        precondition(
            currentRevision == revision,
            "State observation seed closure must not mutate the journal"
        )
        let registration = observers.register(scope: scope, revision: revision)
        return StateObservation(
            id: registration.id,
            scope: scope,
            seed: seed,
            revision: revision,
            signals: registration.stream
        )
    }

    /// Records exactly one engine-assigned revision and wakes affected observers.
    func record(_ changes: StateChangeSet) throws {
        guard currentRevision.rawValue < UInt64.max else {
            throw StateChangeJournalError.revisionExhausted
        }

        let expected = currentRevision.successor
        guard changes.revision == expected else {
            throw StateChangeJournalError.noncontiguousRevision(
                expected: expected,
                received: changes.revision
            )
        }

        currentRevision = changes.revision

        if retainedChangeSetCount == ring.count {
            evictOldest()
        }

        let insertionIndex = (head + retainedChangeSetCount) % ring.count
        ring[insertionIndex] = changes
        retainedChangeSetCount += 1
        retainedEstimatedBytes += changes.estimatedByteCount

        while retainedChangeSetCount > 0,
              retainedEstimatedBytes > limits.maxEstimatedBytes
        {
            evictOldest()
        }

        observers.signal(changes)
    }

    /// Returns retained scoped invalidations or requires a fresh atomic seed.
    func catchUp(observationID: StateObservationID, after revision: StateRevision) -> StateCatchUp {
        guard let observer = observers.snapshot(for: observationID) else {
            return .reset(to: currentRevision)
        }

        guard revision >= observer.registeredAtRevision,
              revision <= currentRevision
        else {
            return .reset(to: currentRevision)
        }

        if let evictedRelevantThrough = observer.evictedRelevantThrough,
           revision < evictedRelevantThrough
        {
            return .reset(to: currentRevision)
        }

        var changes: [StateChangeSet] = []
        changes.reserveCapacity(retainedChangeSetCount)
        for offset in 0..<retainedChangeSetCount {
            let index = (head + offset) % ring.count
            guard let retained = ring[index], retained.revision > revision else { continue }
            if let filtered = retained.filtered(to: observer.scope) {
                changes.append(filtered)
            }
        }
        return .changes(changes, through: currentRevision)
    }

    func cancelObservation(_ id: StateObservationID) {
        observers.finish(id)
    }

    var observerCount: Int {
        observers.count
    }

    private func evictOldest() {
        guard retainedChangeSetCount > 0, let evicted = ring[head] else { return }
        ring[head] = nil
        head = (head + 1) % ring.count
        retainedChangeSetCount -= 1
        retainedEstimatedBytes -= evicted.estimatedByteCount
        observers.noteEviction(evicted)
    }
}

private final class StateObservationRegistry: @unchecked Sendable {
    struct Snapshot {
        let scope: StateObservationScope
        let registeredAtRevision: StateRevision
        let evictedRelevantThrough: StateRevision?
    }

    struct Registration {
        let id: StateObservationID
        let stream: AsyncStream<StateRevisionSignal>
    }

    private struct Observer {
        let scope: StateObservationScope
        let registeredAtRevision: StateRevision
        let continuation: AsyncStream<StateRevisionSignal>.Continuation
        var evictedRelevantThrough: StateRevision?
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var storage: [StateObservationID: Observer] = [:]

    var count: Int {
        lock.withLock { storage.count }
    }

    func register(scope: StateObservationScope, revision: StateRevision) -> Registration {
        let pair = AsyncStream<StateRevisionSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let id = lock.withLock { () -> StateObservationID in
            precondition(nextID < UInt64.max, "State observation identifier exhausted")
            let id = StateObservationID(rawValue: nextID)
            nextID += 1
            storage[id] = Observer(
                scope: scope,
                registeredAtRevision: revision,
                continuation: pair.continuation,
                evictedRelevantThrough: nil
            )
            return id
        }

        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return Registration(id: id, stream: pair.stream)
    }

    func snapshot(for id: StateObservationID) -> Snapshot? {
        lock.withLock {
            storage[id].map {
                Snapshot(
                    scope: $0.scope,
                    registeredAtRevision: $0.registeredAtRevision,
                    evictedRelevantThrough: $0.evictedRelevantThrough
                )
            }
        }
    }

    func noteEviction(_ changes: StateChangeSet) {
        lock.withLock {
            for id in storage.keys {
                guard var observer = storage[id], changes.affects(observer.scope) else { continue }
                if observer.evictedRelevantThrough == nil
                    || observer.evictedRelevantThrough! < changes.revision
                {
                    observer.evictedRelevantThrough = changes.revision
                    storage[id] = observer
                }
            }
        }
    }

    func signal(_ changes: StateChangeSet) {
        let recipients = lock.withLock {
            storage.compactMap { id, observer in
                changes.affects(observer.scope) ? (id, observer.continuation) : nil
            }
        }

        var terminated: [StateObservationID] = []
        for (id, continuation) in recipients {
            if case .terminated = continuation.yield(
                StateRevisionSignal(latestRevision: changes.revision)
            ) {
                terminated.append(id)
            }
        }

        guard !terminated.isEmpty else { return }
        lock.withLock {
            for id in terminated {
                storage.removeValue(forKey: id)
            }
        }
    }

    func finish(_ id: StateObservationID) {
        let continuation = lock.withLock {
            storage.removeValue(forKey: id)?.continuation
        }
        continuation?.finish()
    }

    func finishAll() {
        let continuations = lock.withLock {
            let continuations = storage.values.map(\.continuation)
            storage.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func remove(_ id: StateObservationID) {
        _ = lock.withLock {
            storage.removeValue(forKey: id)
        }
    }
}
