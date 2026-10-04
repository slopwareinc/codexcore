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
    private var hub = CodexGlobalOperationObserverHub<CodexSchemaThreadQueueChangedNotification>()

    var observerCount: Int { hub.observerCount }

    mutating func observe(
        connectionEpoch: UInt64,
        threadID: String? = nil,
        onTermination: (@Sendable (CodexThreadQueueObservationID) -> Void)? = nil
    ) -> CodexThreadQueueObservation {
        let observation = hub.observe(
            connectionEpoch: connectionEpoch,
            accepts: { threadID == nil || threadID == $0.threadID },
            onTermination: { onTermination?(CodexThreadQueueObservationID(rawValue: $0)) }
        )
        return .init(
            id: .init(rawValue: observation.id), connectionEpoch: connectionEpoch,
            threadID: threadID, changes: observation.events
        )
    }

    @discardableResult
    mutating func publish(connectionEpoch: UInt64, notification: CodexSchemaThreadQueueChangedNotification) -> Int {
        hub.publish(connectionEpoch: connectionEpoch, event: notification)
    }

    @discardableResult
    mutating func cancel(_ id: CodexThreadQueueObservationID) -> Bool {
        hub.cancel(id.rawValue)
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        hub.disconnect(
            connectionEpoch: connectionEpoch,
            error: CodexThreadQueueObserverError.disconnected(connectionEpoch: connectionEpoch)
        )
    }
}
