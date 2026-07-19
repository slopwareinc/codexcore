import Foundation

/// An atomic current-state seed paired with a coalescing invalidation stream.
///
/// Signals are deliberately not a data plane: after receiving one, consumers
/// fetch the latest scoped snapshot from the state owner. The hub retains no
/// changes, protocol frames, or catch-up history.
public struct StateSnapshotObservation<Seed: Sendable>: Sendable {
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

/// Synchronous observation fan-out owned by the same isolation domain as state.
///
/// `observe`, `publish`, and explicit cancellation must be called by that owner
/// (currently the session actor). The small registry is locked only because an
/// `AsyncStream` consumer may terminate from another executor.
final class ObservationHub: @unchecked Sendable {
    private struct Observer {
        let scope: StateObservationScope
        let continuation: AsyncStream<StateRevisionSignal>.Continuation
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var observers: [StateObservationID: Observer] = [:]

    deinit {
        finishAll()
    }

    /// Captures a seed and registers its stream without an async suspension.
    /// The state owner must not mutate state from `makeSeed`; actor isolation then
    /// makes the returned seed, revision, and subscription one atomic observation.
    func observe<Seed: Sendable>(
        scope: StateObservationScope = .all,
        revision: StateRevision,
        seed makeSeed: () -> Seed
    ) -> StateSnapshotObservation<Seed> {
        let seed = makeSeed()
        let pair = AsyncStream<StateRevisionSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = lock.withLock { () -> StateObservationID in
            precondition(nextID < UInt64.max, "State observation identifier exhausted")
            let id = StateObservationID(rawValue: nextID)
            nextID += 1
            observers[id] = Observer(scope: scope, continuation: pair.continuation)
            return id
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return StateSnapshotObservation(
            id: id,
            scope: scope,
            seed: seed,
            revision: revision,
            signals: pair.stream
        )
    }

    /// Publishes only a coalescible latest-revision signal to matching scopes.
    func publish(_ invalidation: StateInvalidation) {
        let recipients = lock.withLock {
            observers.compactMap { id, observer in
                invalidation.affects(observer.scope) ? (id, observer.continuation) : nil
            }
        }

        var terminated: [StateObservationID] = []
        for (id, continuation) in recipients {
            if case .terminated = continuation.yield(
                StateRevisionSignal(latestRevision: invalidation.revision)
            ) {
                terminated.append(id)
            }
        }
        guard !terminated.isEmpty else { return }
        lock.withLock {
            for id in terminated {
                observers.removeValue(forKey: id)
            }
        }
    }

    func cancelObservation(_ id: StateObservationID) {
        let continuation = lock.withLock {
            observers.removeValue(forKey: id)?.continuation
        }
        continuation?.finish()
    }

    /// Finishes every stream, used when the owning state engine is torn down.
    func finishAll() {
        let continuations = lock.withLock {
            let result = observers.values.map(\.continuation)
            observers.removeAll(keepingCapacity: false)
            return result
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    var observerCount: Int {
        lock.withLock { observers.count }
    }

    private func remove(_ id: StateObservationID) {
        _ = lock.withLock {
            observers.removeValue(forKey: id)
        }
    }
}
