import Foundation

public enum CodexRealtimeEvent: Sendable, Equatable {
    case started(CodexSchemaThreadRealtimeStartedNotification)
    case itemAdded(CodexSchemaThreadRealtimeItemAddedNotification)
    case transcriptDelta(CodexSchemaThreadRealtimeTranscriptDeltaNotification)
    case transcriptDone(CodexSchemaThreadRealtimeTranscriptDoneNotification)
    case outputAudio(CodexSchemaThreadRealtimeOutputAudioDeltaNotification)
    case sdp(CodexSchemaThreadRealtimeSdpNotification)
    case error(CodexSchemaThreadRealtimeErrorNotification)
    case closed(CodexSchemaThreadRealtimeClosedNotification)

    public var threadID: String {
        switch self {
        case .started(let value): value.threadID
        case .itemAdded(let value): value.threadID
        case .transcriptDelta(let value): value.threadID
        case .transcriptDone(let value): value.threadID
        case .outputAudio(let value): value.threadID
        case .sdp(let value): value.threadID
        case .error(let value): value.threadID
        case .closed(let value): value.threadID
        }
    }
}

struct CodexRealtimeObservationID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum CodexRealtimeObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

struct CodexRealtimeObserverHub {
    private struct Entry {
        let connectionEpoch: UInt64
        let threadID: String
        let continuation: AsyncThrowingStream<CodexRealtimeEvent, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [CodexRealtimeObservationID: Entry] = [:]

    mutating func observe(
        connectionEpoch: UInt64,
        threadID: String,
        onTermination: (@Sendable (CodexRealtimeObservationID) -> Void)? = nil
    ) -> (
        id: CodexRealtimeObservationID,
        events: AsyncThrowingStream<CodexRealtimeEvent, Error>
    ) {
        precondition(nextID < UInt64.max, "Realtime observation space exhausted")
        let id = CodexRealtimeObservationID(rawValue: nextID)
        nextID += 1
        let pair = AsyncThrowingStream<CodexRealtimeEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2_048)
        )
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            connectionEpoch: connectionEpoch,
            threadID: threadID,
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        event: CodexRealtimeEvent
    ) -> Int {
        var delivered = 0
        var terminated: [CodexRealtimeObservationID] = []
        for (id, entry) in entries
        where entry.connectionEpoch == connectionEpoch && entry.threadID == event.threadID {
            switch entry.continuation.yield(event) {
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
    mutating func cancel(_ id: CodexRealtimeObservationID) -> Bool {
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
                throwing: CodexRealtimeObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}
