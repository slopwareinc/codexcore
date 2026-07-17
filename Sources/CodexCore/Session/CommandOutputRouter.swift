import Foundation

struct CodexCommandOutputKey: Sendable, Hashable {
    let connectionEpoch: UInt64
    let processID: String
}

struct CodexCommandOutputSubscriptionToken: Sendable, Hashable {
    let rawValue: UInt64
    let key: CodexCommandOutputKey
}

struct CodexCommandOutputSubscription: Sendable {
    let token: CodexCommandOutputSubscriptionToken
    let deltas: AsyncThrowingStream<CodexSchemaCommandExecOutputDeltaNotification, Error>
}

enum CodexCommandOutputRouterError: Error, Sendable, Equatable {
    case duplicateActiveProcess(CodexCommandOutputKey)
    case bufferOverflow(CodexCommandOutputKey, maximumDeltaCount: Int)
    case disconnected(connectionEpoch: UInt64)
}

enum CodexCommandOutputPublishResult: Sendable, Equatable {
    case delivered
    case unmatched(CodexCommandOutputKey)
    case overflowed(CodexCommandOutputKey)
}

/// Routes only `command/exec/outputDelta` by its exact wire identity.
/// Lifecycle completion remains owned by the command operation itself.
struct CodexCommandOutputRouter {
    private struct Entry {
        let token: CodexCommandOutputSubscriptionToken
        let maximumDeltaCount: Int
        let continuation: AsyncThrowingStream<
            CodexSchemaCommandExecOutputDeltaNotification,
            Error
        >.Continuation
    }

    private var nextToken: UInt64 = 1
    private var entries: [CodexCommandOutputKey: Entry] = [:]

    var activeCount: Int { entries.count }

    mutating func register(
        connectionEpoch: UInt64,
        processID: String,
        maximumDeltaCount: Int = 512,
        onTermination: (@Sendable (CodexCommandOutputSubscriptionToken) -> Void)? = nil
    ) throws -> CodexCommandOutputSubscription {
        precondition(maximumDeltaCount > 0)
        precondition(nextToken < UInt64.max, "Command output subscription space exhausted")

        let key = CodexCommandOutputKey(
            connectionEpoch: connectionEpoch,
            processID: processID
        )
        guard entries[key] == nil else {
            throw CodexCommandOutputRouterError.duplicateActiveProcess(key)
        }

        let token = CodexCommandOutputSubscriptionToken(rawValue: nextToken, key: key)
        nextToken += 1
        let pair = AsyncThrowingStream<
            CodexSchemaCommandExecOutputDeltaNotification,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(maximumDeltaCount))
        pair.continuation.onTermination = { @Sendable _ in
            onTermination?(token)
        }
        entries[key] = Entry(
            token: token,
            maximumDeltaCount: maximumDeltaCount,
            continuation: pair.continuation
        )
        return .init(token: token, deltas: pair.stream)
    }

    mutating func publish(
        connectionEpoch: UInt64,
        notification: CodexSchemaCommandExecOutputDeltaNotification
    ) -> CodexCommandOutputPublishResult {
        let key = CodexCommandOutputKey(
            connectionEpoch: connectionEpoch,
            processID: notification.processID
        )
        guard let entry = entries[key] else { return .unmatched(key) }

        switch entry.continuation.yield(notification) {
        case .enqueued:
            return .delivered
        case .dropped:
            entries.removeValue(forKey: key)
            entry.continuation.finish(throwing: CodexCommandOutputRouterError.bufferOverflow(
                key,
                maximumDeltaCount: entry.maximumDeltaCount
            ))
            return .overflowed(key)
        case .terminated:
            entries.removeValue(forKey: key)
            return .unmatched(key)
        @unknown default:
            entries.removeValue(forKey: key)
            entry.continuation.finish(throwing: CodexCommandOutputRouterError.bufferOverflow(
                key,
                maximumDeltaCount: entry.maximumDeltaCount
            ))
            return .overflowed(key)
        }
    }

    @discardableResult
    mutating func finish(connectionEpoch: UInt64, processID: String) -> Bool {
        let key = CodexCommandOutputKey(
            connectionEpoch: connectionEpoch,
            processID: processID
        )
        guard let entry = entries.removeValue(forKey: key) else { return false }
        entry.continuation.finish()
        return true
    }

    @discardableResult
    mutating func cancel(_ token: CodexCommandOutputSubscriptionToken) -> Bool {
        guard let entry = entries[token.key], entry.token == token else { return false }
        entries.removeValue(forKey: token.key)
        entry.continuation.finish(throwing: CancellationError())
        return true
    }

    @discardableResult
    mutating func disconnect(connectionEpoch: UInt64) -> Int {
        let keys = entries.keys.filter { $0.connectionEpoch == connectionEpoch }
        for key in keys {
            entries.removeValue(forKey: key)?.continuation.finish(
                throwing: CodexCommandOutputRouterError.disconnected(
                    connectionEpoch: connectionEpoch
                )
            )
        }
        return keys.count
    }
}
