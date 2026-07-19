import Foundation

struct CodexSkillsChangeObservationID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct CodexSkillsChangeObservation: Sendable {
    let id: CodexSkillsChangeObservationID
    let connectionEpoch: UInt64
    let changes: AsyncThrowingStream<CodexSchemaSkillsChangedNotification, Error>
}

enum CodexSkillsChangeObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

/// Coalescing observation for the global `skills/changed` invalidation.
struct CodexSkillsChangeObserverHub {
    private struct Entry {
        let connectionEpoch: UInt64
        let continuation: AsyncThrowingStream<
            CodexSchemaSkillsChangedNotification,
            Error
        >.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [CodexSkillsChangeObservationID: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        onTermination: (@Sendable (CodexSkillsChangeObservationID) -> Void)? = nil
    ) -> CodexSkillsChangeObservation {
        precondition(nextID < UInt64.max, "Skills observation space exhausted")
        let id = CodexSkillsChangeObservationID(rawValue: nextID)
        nextID += 1
        let pair = AsyncThrowingStream<
            CodexSchemaSkillsChangedNotification,
            Error
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { @Sendable _ in
            onTermination?(id)
        }
        entries[id] = .init(
            connectionEpoch: connectionEpoch,
            continuation: pair.continuation
        )
        return .init(id: id, connectionEpoch: connectionEpoch, changes: pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        notification: CodexSchemaSkillsChangedNotification
    ) -> Int {
        var delivered = 0
        var terminated: [CodexSkillsChangeObservationID] = []
        for (id, entry) in entries where entry.connectionEpoch == connectionEpoch {
            switch entry.continuation.yield(notification) {
            case .enqueued, .dropped:
                delivered += 1
            case .terminated:
                terminated.append(id)
            @unknown default:
                terminated.append(id)
            }
        }
        for id in terminated {
            entries.removeValue(forKey: id)
        }
        return delivered
    }

    @discardableResult
    mutating func cancel(_ id: CodexSkillsChangeObservationID) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let ids = entries.compactMap { id, entry in
            entry.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish(
                throwing: CodexSkillsChangeObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}
