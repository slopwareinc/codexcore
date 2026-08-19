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
    private struct Key: Hashable, Sendable {
        let connectionEpoch: UInt64
        let threadID: String
    }

    private struct Entry {
        let key: Key
        let continuation: AsyncThrowingStream<CodexRealtimeEvent, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [CodexRealtimeObservationID: Entry] = [:]
    private var observerIDsByKey: [Key: Set<CodexRealtimeObservationID>] = [:]

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
        let key = Key(connectionEpoch: connectionEpoch, threadID: threadID)
        entries[id] = Entry(
            key: key,
            continuation: pair.continuation
        )
        observerIDsByKey[key, default: []].insert(id)
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        event: CodexRealtimeEvent
    ) -> Int {
        let key = Key(connectionEpoch: connectionEpoch, threadID: event.threadID)
        guard let matchingIDs = observerIDsByKey[key] else { return 0 }

        var delivered = 0
        var terminated: [CodexRealtimeObservationID] = []
        for id in matchingIDs {
            guard let entry = entries[id] else { continue }
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
            _ = removeEntry(for: id)
        }
        return delivered
    }

    @discardableResult
    mutating func cancel(_ id: CodexRealtimeObservationID) -> Bool {
        guard let entry = removeEntry(for: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        var ids: [CodexRealtimeObservationID] = []
        for (key, matchingIDs) in observerIDsByKey where key.connectionEpoch == connectionEpoch {
            ids.append(contentsOf: matchingIDs)
        }
        for id in ids {
            removeEntry(for: id)?.continuation.finish(
                throwing: CodexRealtimeObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }

    private mutating func removeEntry(for id: CodexRealtimeObservationID) -> Entry? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        if var ids = observerIDsByKey[entry.key] {
            ids.remove(id)
            if ids.isEmpty {
                observerIDsByKey.removeValue(forKey: entry.key)
            } else {
                observerIDsByKey[entry.key] = ids
            }
        }
        return entry
    }
}
