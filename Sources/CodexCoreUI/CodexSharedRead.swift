import Foundation

/// Coalesces concurrent demand. Consumers claim ownership synchronously before
/// suspending; only the last consumer's departure cancels the worker.
final class CodexSharedRead<Value: Sendable>: @unchecked Sendable {
    final class Consumer: @unchecked Sendable {
        private let read: CodexSharedRead
        private let id: UUID
        private let lock = NSLock()
        private var waited = false

        fileprivate init(read: CodexSharedRead, id: UUID) {
            self.read = read
            self.id = id
        }

        deinit { read.cancel(id) }

        func value() async throws -> Value {
            guard lock.withLock({
                if waited { return false }
                waited = true
                return true
            }) else { throw CancellationError() }
            defer {
                read.cancel(id)
                withExtendedLifetime(self) {}
            }
            let value = try await read.wait(id)
            try Task.checkCancellation()
            return value
        }
    }

    private struct ConsumerState {
        var continuation: CheckedContinuation<Value, Error>?
    }

    private let lock = NSLock()
    private let task: Task<Value, Error>
    private var consumers: [UUID: ConsumerState] = [:]
    private var result: Result<Value, Error>?
    private var abandoned = false

    init(operation: @escaping @Sendable () async throws -> Value) {
        task = Task { try await operation() }
        let task = task
        Task { [weak self] in
            let result = await task.result
            self?.complete(result)
        }
    }

    deinit { task.cancel() }

    var acceptsConsumers: Bool {
        lock.withLock { !abandoned && result == nil }
    }

    var consumerCount: Int { lock.withLock { consumers.count } }

    /// Atomically joins a live or completed read. An abandoned read can never
    /// regain consumers. The lease counts even before its async value is read.
    func claimConsumer() -> Consumer? {
        lock.withLock {
            guard !abandoned else { return nil }
            let id = UUID()
            consumers[id] = ConsumerState()
            return Consumer(read: self, id: id)
        }
    }

    func value() async throws -> Value {
        guard let consumer = claimConsumer() else { throw CancellationError() }
        return try await consumer.value()
    }

    private func wait(_ id: UUID) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Value, Error>? = lock.withLock {
                    if abandoned { return .failure(CancellationError()) }
                    if let result { return result }
                    guard consumers[id] != nil else { return .failure(CancellationError()) }
                    consumers[id]?.continuation = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let (continuation, cancelWorker): (CheckedContinuation<Value, Error>?, Bool) = lock.withLock {
            guard let consumer = consumers.removeValue(forKey: id) else { return (nil, false) }
            let cancelWorker = consumers.isEmpty && result == nil
            if cancelWorker { abandoned = true }
            return (consumer.continuation, cancelWorker)
        }
        continuation?.resume(throwing: CancellationError())
        if cancelWorker { task.cancel() }
    }

    private func complete(_ result: Result<Value, Error>) {
        let waiting = lock.withLock {
            self.result = result
            let waiting = consumers.values.compactMap(\.continuation)
            consumers.removeAll()
            return waiting
        }
        waiting.forEach { $0.resume(with: result) }
    }
}
