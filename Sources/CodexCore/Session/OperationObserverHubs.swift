import Foundation

// MARK: - Filesystem watch changes

struct CodexFSChangeObservationID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum CodexFSChangeObserverError: Error, Sendable, Equatable {
    case bufferOverflow(watchID: String, maximumChangeCount: Int)
    case disconnected(connectionEpoch: UInt64)
}

struct CodexFSChangeObserverHub {
    private struct Key: Hashable, Sendable {
        let connectionEpoch: UInt64
        let watchID: String
    }

    private struct Entry {
        let key: Key
        let maximumChangeCount: Int
        let continuation: AsyncThrowingStream<CodexSchemaFSChangedNotification, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [CodexFSChangeObservationID: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        watchID: String,
        maximumChangeCount: Int = 512,
        onTermination: (@Sendable (CodexFSChangeObservationID) -> Void)? = nil
    ) -> (
        id: CodexFSChangeObservationID,
        changes: AsyncThrowingStream<CodexSchemaFSChangedNotification, Error>
    ) {
        precondition(maximumChangeCount > 0)
        precondition(nextID < UInt64.max, "Filesystem observation space exhausted")
        let id = CodexFSChangeObservationID(rawValue: nextID)
        nextID += 1
        let pair = AsyncThrowingStream<
            CodexSchemaFSChangedNotification,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(maximumChangeCount))
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            key: .init(connectionEpoch: connectionEpoch, watchID: watchID),
            maximumChangeCount: maximumChangeCount,
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        notification: CodexSchemaFSChangedNotification
    ) -> Int {
        var delivered = 0
        var terminated: [CodexFSChangeObservationID] = []
        for (id, entry) in entries
        where entry.key.connectionEpoch == connectionEpoch
            && entry.key.watchID == notification.watchID {
            switch entry.continuation.yield(notification) {
            case .enqueued:
                delivered += 1
            case .dropped:
                entries.removeValue(forKey: id)
                entry.continuation.finish(throwing: CodexFSChangeObserverError.bufferOverflow(
                    watchID: notification.watchID,
                    maximumChangeCount: entry.maximumChangeCount
                ))
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
    mutating func finish(connectionEpoch: UInt64, watchID: String) -> Int {
        let ids: [CodexFSChangeObservationID] = entries.compactMap {
            (id: CodexFSChangeObservationID, entry: Entry) -> CodexFSChangeObservationID? in
            entry.key == .init(connectionEpoch: connectionEpoch, watchID: watchID) ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish()
        }
        return ids.count
    }

    @discardableResult
    mutating func cancel(_ id: CodexFSChangeObservationID) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let ids: [CodexFSChangeObservationID] = entries.compactMap { element in
            let (id, entry) = element
            return entry.key.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish(
                throwing: CodexFSChangeObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

// MARK: - Process output and exit events

public enum CodexProcessEvent: Sendable, Equatable {
    case output(CodexSchemaProcessOutputDeltaNotification)
    case exited(CodexSchemaProcessExitedNotification)
}

enum CodexProcessObserverError: Error, Sendable, Equatable {
    case duplicateActiveProcess(connectionEpoch: UInt64, processHandle: String)
    case bufferOverflow(processHandle: String, maximumEventCount: Int)
    case disconnected(connectionEpoch: UInt64)
}

struct CodexProcessObserverHub {
    private struct Key: Hashable, Sendable {
        let connectionEpoch: UInt64
        let processHandle: String
    }

    private struct Entry {
        let key: Key
        let maximumEventCount: Int
        let continuation: AsyncThrowingStream<CodexProcessEvent, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        processHandle: String,
        maximumEventCount: Int = 512,
        onTermination: (@Sendable (UInt64) -> Void)? = nil
    ) throws -> (
        id: UInt64,
        events: AsyncThrowingStream<CodexProcessEvent, Error>
    ) {
        precondition(maximumEventCount > 0)
        precondition(nextID < UInt64.max, "Process observation space exhausted")
        let key = Key(connectionEpoch: connectionEpoch, processHandle: processHandle)
        guard !entries.values.contains(where: { $0.key == key }) else {
            throw CodexProcessObserverError.duplicateActiveProcess(
                connectionEpoch: connectionEpoch,
                processHandle: processHandle
            )
        }
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<CodexProcessEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumEventCount)
        )
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            key: key,
            maximumEventCount: maximumEventCount,
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        event: CodexProcessEvent
    ) -> Int {
        let processHandle: String
        switch event {
        case .output(let output): processHandle = output.processHandle
        case .exited(let exited): processHandle = exited.processHandle
        }
        let key = Key(connectionEpoch: connectionEpoch, processHandle: processHandle)
        // `observe` rejects duplicate keys, so at most one active observer can
        // match this event. Avoid copying and then rescanning the whole table.
        guard let (id, entry) = entries.first(where: { $0.value.key == key }) else {
            return 0
        }
        switch entry.continuation.yield(event) {
        case .enqueued:
            if case .exited = event {
                entries.removeValue(forKey: id)?.continuation.finish()
            }
            return 1
        case .dropped:
            entries.removeValue(forKey: id)
            entry.continuation.finish(throwing: CodexProcessObserverError.bufferOverflow(
                processHandle: processHandle,
                maximumEventCount: entry.maximumEventCount
            ))
            return 0
        case .terminated:
            entries.removeValue(forKey: id)
            return 0
        @unknown default:
            entries.removeValue(forKey: id)
            return 0
        }
    }

    @discardableResult
    mutating func cancel(_ id: UInt64) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let ids = entries.compactMap { id, entry in
            entry.key.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish(
                throwing: CodexProcessObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

// MARK: - Fuzzy-file-search sessions

public enum CodexFuzzyFileSearchEvent: Sendable, Equatable {
    case updated(CodexSchemaFuzzyFileSearchSessionUpdatedNotification)
    case completed(CodexSchemaFuzzyFileSearchSessionCompletedNotification)
}

enum CodexFuzzyFileSearchObserverError: Error, Sendable, Equatable {
    case bufferOverflow(sessionID: String, maximumEventCount: Int)
    case disconnected(connectionEpoch: UInt64)
}

struct CodexFuzzyFileSearchObserverHub {
    private struct Key: Hashable, Sendable {
        let connectionEpoch: UInt64
        let sessionID: String
    }

    private struct Entry {
        let key: Key
        let maximumEventCount: Int
        let continuation: AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        sessionID: String,
        maximumEventCount: Int = 128,
        onTermination: (@Sendable (UInt64) -> Void)? = nil
    ) -> (
        id: UInt64,
        events: AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>
    ) {
        precondition(maximumEventCount > 0)
        precondition(nextID < UInt64.max, "Fuzzy search observation space exhausted")
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(maximumEventCount)
        )
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            key: .init(connectionEpoch: connectionEpoch, sessionID: sessionID),
            maximumEventCount: maximumEventCount,
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        event: CodexFuzzyFileSearchEvent
    ) -> Int {
        let sessionID: String
        switch event {
        case .updated(let update): sessionID = update.sessionID
        case .completed(let completion): sessionID = completion.sessionID
        }
        let key = Key(connectionEpoch: connectionEpoch, sessionID: sessionID)
        var delivered = 0
        var terminated: [UInt64] = []
        for (id, entry) in entries where entry.key == key {
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
        if case .completed = event {
            for (id, entry) in entries where entry.key == key {
                entries.removeValue(forKey: id)?.continuation.finish()
            }
        }
        return delivered
    }

    @discardableResult
    mutating func finish(connectionEpoch: UInt64, sessionID: String) -> Int {
        let key = Key(connectionEpoch: connectionEpoch, sessionID: sessionID)
        let ids = entries.compactMap { id, entry in entry.key == key ? id : nil }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish()
        }
        return ids.count
    }

    @discardableResult
    mutating func cancel(_ id: UInt64) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let ids = entries.compactMap { id, entry in
            entry.key.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish(
                throwing: CodexFuzzyFileSearchObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

// MARK: - MCP OAuth completion and external-agent import

struct CodexMCPServerOAuthLoginKey: Hashable, Sendable {
    let connectionEpoch: UInt64
    let name: String
    let threadID: String?
}

enum CodexMCPServerOAuthLoginObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

struct CodexMCPServerOAuthLoginObserverHub {
    private struct Entry {
        let key: CodexMCPServerOAuthLoginKey
        let continuation: AsyncThrowingStream<
            CodexSchemaMCPServerOAuthLoginCompletedNotification,
            Error
        >.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]

    mutating func observe(
        connectionEpoch: UInt64,
        name: String,
        threadID: String?,
        onTermination: (@Sendable (UInt64) -> Void)? = nil
    ) -> (
        id: UInt64,
        completions: AsyncThrowingStream<
            CodexSchemaMCPServerOAuthLoginCompletedNotification,
            Error
        >
    ) {
        precondition(nextID < UInt64.max, "MCP OAuth observation space exhausted")
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<
            CodexSchemaMCPServerOAuthLoginCompletedNotification,
            Error
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            key: .init(connectionEpoch: connectionEpoch, name: name, threadID: threadID),
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        notification: CodexSchemaMCPServerOAuthLoginCompletedNotification
    ) -> Int {
        let ids: [UInt64] = entries.compactMap { element in
            let (id, entry) = element
            guard entry.key.connectionEpoch == connectionEpoch,
                  entry.key.name == notification.name else {
                return nil
            }
            guard let expectedThreadID = entry.key.threadID else { return id }
            return expectedThreadID == notification.threadID ? id : nil
        }
        for id in ids {
            guard let entry = entries.removeValue(forKey: id) else { continue }
            _ = entry.continuation.yield(notification)
            entry.continuation.finish()
        }
        return ids.count
    }

    @discardableResult
    mutating func cancel(_ id: UInt64) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let ids = entries.compactMap { id, entry in
            entry.key.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish(
                throwing: CodexMCPServerOAuthLoginObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

public enum CodexExternalAgentConfigImportEvent: Sendable, Equatable {
    case progress(CodexSchemaExternalAgentConfigImportProgressNotification)
    case completed(CodexSchemaExternalAgentConfigImportCompletedNotification)
}

enum CodexExternalAgentConfigImportObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

struct CodexExternalAgentConfigImportObserverHub {
    private struct Entry {
        let connectionEpoch: UInt64
        let importID: String
        let continuation: AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]

    mutating func observe(
        connectionEpoch: UInt64,
        importID: String,
        onTermination: (@Sendable (UInt64) -> Void)? = nil
    ) -> (
        id: UInt64,
        events: AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error>
    ) {
        precondition(nextID < UInt64.max, "External import observation space exhausted")
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(
            connectionEpoch: connectionEpoch,
            importID: importID,
            continuation: pair.continuation
        )
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(
        connectionEpoch: UInt64,
        event: CodexExternalAgentConfigImportEvent
    ) -> Int {
        let importID: String
        switch event {
        case .progress(let progress): importID = progress.importID
        case .completed(let completed): importID = completed.importID
        }
        let ids = entries.compactMap { id, entry in
            entry.connectionEpoch == connectionEpoch && entry.importID == importID ? id : nil
        }
        for id in ids {
            guard let entry = entries.removeValue(forKey: id) else { continue }
            _ = entry.continuation.yield(event)
            if case .completed = event {
                entry.continuation.finish()
            } else {
                entries[id] = entry
            }
        }
        return ids.count
    }

    @discardableResult
    mutating func cancel(_ id: UInt64) -> Bool {
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
                throwing: CodexExternalAgentConfigImportObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

// MARK: - Global invalidations

enum CodexGlobalOperationObserverError: Error, Sendable, Equatable {
    case disconnected(connectionEpoch: UInt64)
}

struct CodexGlobalOperationObserverHub<Event: Sendable> {
    private struct Entry {
        let connectionEpoch: UInt64
        let continuation: AsyncThrowingStream<Event, Error>.Continuation
    }

    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]

    var observerCount: Int { entries.count }

    mutating func observe(
        connectionEpoch: UInt64,
        bufferingPolicy: AsyncThrowingStream<Event, Error>.Continuation.BufferingPolicy = .bufferingNewest(1),
        onTermination: (@Sendable (UInt64) -> Void)? = nil
    ) -> (id: UInt64, events: AsyncThrowingStream<Event, Error>) {
        precondition(nextID < UInt64.max, "Global operation observation space exhausted")
        let id = nextID
        nextID += 1
        let pair = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: bufferingPolicy)
        pair.continuation.onTermination = { @Sendable _ in onTermination?(id) }
        entries[id] = Entry(connectionEpoch: connectionEpoch, continuation: pair.continuation)
        return (id, pair.stream)
    }

    @discardableResult
    mutating func publish(connectionEpoch: UInt64, event: Event) -> Int {
        var delivered = 0
        var terminated: [UInt64] = []
        for (id, entry) in entries where entry.connectionEpoch == connectionEpoch {
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
    mutating func finish(connectionEpoch: UInt64) -> Int {
        let ids = entries.compactMap { id, entry in
            entry.connectionEpoch == connectionEpoch ? id : nil
        }
        for id in ids {
            entries.removeValue(forKey: id)?.continuation.finish()
        }
        return ids.count
    }

    @discardableResult
    mutating func cancel(_ id: UInt64) -> Bool {
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
                throwing: CodexGlobalOperationObserverError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return ids.count
    }
}

typealias CodexAppListObserverHub = CodexGlobalOperationObserverHub<
    CodexSchemaAppListUpdatedNotification
>
typealias CodexRemoteControlStatusObserverHub = CodexGlobalOperationObserverHub<
    CodexSchemaRemoteControlStatusChangedNotification
>
typealias CodexWindowsSandboxSetupObserverHub = CodexGlobalOperationObserverHub<
    CodexSchemaWindowsSandboxSetupCompletedNotification
>
