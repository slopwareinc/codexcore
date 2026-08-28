import Foundation

struct CodexThreadQueueObservationID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct CodexThreadQueueObservation: Sendable {
    let id: CodexThreadQueueObservationID
    let connectionEpoch: UInt64
    let threadID: String?
    let changes: AsyncThrowingStream<CodexSchemaThreadQueueChangedNotification, Error>
}

enum CodexThreadQueueObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

/// Coalescing invalidation stream for durable thread queues. Notifications are
/// intentionally lightweight, so consumers reread the authoritative queue.
struct CodexThreadQueueObserverHub {
    private struct Entry {
        let connectionEpoch: UInt64
        let threadID: String?
        let continuation: AsyncThrowingStream<
            CodexSchemaThreadQueueChangedNotification,
            Error
        >.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [CodexThreadQueueObservationID: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        threadID: String? = nil,
        onTermination: (@Sendable (CodexThreadQueueObservationID) -> Void)? = nil
    ) -> CodexThreadQueueObservation {
        precondition(nextID < UInt64.max, "Thread queue observation space exhausted")
        let id = CodexThreadQueueObservationID(rawValue: nextID)
        nextID += 1
        let pair = AsyncThrowingStream<
            CodexSchemaThreadQueueChangedNotification,
            Error
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = .init(
            connectionEpoch: connectionEpoch,
            threadID: threadID,
            continuation: pair.continuation
        )
        return .init(
            id: id,
            connectionEpoch: connectionEpoch,
            threadID: threadID,
            changes: pair.stream
        )
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        notification: CodexSchemaThreadQueueChangedNotification
    ) -> Int {
        var delivered = 0
        var terminated: [CodexThreadQueueObservationID] = []
        for (id, entry) in entries
            where entry.connectionEpoch == connectionEpoch
                && (entry.threadID == nil || entry.threadID == notification.threadID) {
            switch entry.continuation.yield(notification) {
            case .enqueued, .dropped:
                delivered += 1
            case .terminated:
                terminated.append(id)
            @unknown default:
                terminated.append(id)
            }
        }
        for id in terminated { entries.removeValue(forKey: id) }
        return delivered
    }

    @discardableResult
    mutating func cancel(_ id: CodexThreadQueueObservationID) -> Bool {
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
                throwing: CodexThreadQueueObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}
