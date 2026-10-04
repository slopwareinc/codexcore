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
    private var hub = CodexGlobalOperationObserverHub<CodexSchemaSkillsChangedNotification>()

    var observerCount: Int { hub.observerCount }

    mutating func observe(
        connectionEpoch: UInt64,
        onTermination: (@Sendable (CodexSkillsChangeObservationID) -> Void)? = nil
    ) -> CodexSkillsChangeObservation {
        let observation = hub.observe(connectionEpoch: connectionEpoch, onTermination: { rawID in
            onTermination?(CodexSkillsChangeObservationID(rawValue: rawID))
        })
        return .init(
            id: .init(rawValue: observation.id),
            connectionEpoch: connectionEpoch,
            changes: observation.events
        )
    }

    @discardableResult
    mutating func publish(connectionEpoch: UInt64, notification: CodexSchemaSkillsChangedNotification) -> Int {
        hub.publish(connectionEpoch: connectionEpoch, event: notification)
    }

    @discardableResult
    mutating func cancel(_ id: CodexSkillsChangeObservationID) -> Bool {
        hub.cancel(id.rawValue)
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        hub.disconnect(
            connectionEpoch: connectionEpoch,
            error: CodexSkillsChangeObserverError.disconnected(connectionEpoch: connectionEpoch)
        )
    }
}
