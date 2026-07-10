import Foundation

// MARK: - Reconnection Manager

public actor CodexReconnectionManager {
    private let transport: any CodexTransport
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var isReconnecting = false
    private var isReady = false
    private var backoffDelay: TimeInterval = 1.0
    private let maxBackoffDelay: TimeInterval = 30.0

    // Outbox packet buffer for outgoing requests while connection is down
    private var outbox: [[String: CodexJSONValue]] = []

    // Reconnection callbacks
    private var onReconnected: (@Sendable () -> Void)?
    private var beforeReplay: (@Sendable () async throws -> Void)?
    private var onDisconnect: (@Sendable (Error) async -> Void)?
    private var onMessage: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    public init(
        transport: any CodexTransport,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.transport = transport
        self.sleep = sleep
    }

    public func configure(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onDisconnect: @escaping @Sendable (Error) async -> Void = { _ in },
        beforeReplay: @escaping @Sendable () async throws -> Void = {},
        onReconnected: @escaping @Sendable () -> Void
    ) {
        self.onMessage = onMessage
        self.onError = onError
        self.onDisconnect = onDisconnect
        self.beforeReplay = beforeReplay
        self.onReconnected = onReconnected
    }

    public func start() async throws {
        try await tryConnect()
        isReady = true
    }

    func startAwaitingHandshake() async throws {
        isReady = false
        try await tryConnect()
    }

    func sendHandshake(_ payload: [String: CodexJSONValue]) async throws {
        guard await transport.isConnected else {
            throw CodexConnectionError.closed
        }
        try await transport.send(payload)
    }

    func completeInitialHandshake() async throws {
        try await flushOutbox()
        isReady = true
    }

    func discardBufferedRequests(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        outbox.removeAll { payload in
            guard let id = payload["id"] else { return false }
            switch id {
            case .int(let value):
                return ids.contains(Int64(value))
            case .double(let value):
                return ids.contains(Int64(value))
            case .string(let value):
                return Int64(value).map(ids.contains) ?? false
            default:
                return false
            }
        }
    }

    public func sendOrBuffer(_ payload: [String: CodexJSONValue]) async throws {
        let connected = await transport.isConnected
        if connected && isReady {
            try await transport.send(payload)
        } else {
            outbox.append(payload)
            print("[CodexCore] Connection down. Buffered request. Outbox size: \(outbox.count)")
        }
    }

    public func handleDisconnect() {
        isReady = false
        guard !isReconnecting else { return }
        isReconnecting = true
        backoffDelay = 1.0

        Task {
            await triggerReconnectionLoop()
        }
    }

    private func triggerReconnectionLoop() async {
        while isReconnecting {
            print("[CodexCore] Reconnection attempt in \(backoffDelay) seconds...")
            await sleep(backoffDelay)

            do {
                try await tryConnect()
                try await beforeReplay?()
                try await flushOutbox()

                isReady = true
                isReconnecting = false
                backoffDelay = 1.0
                print("[CodexCore] Reconnected successfully!")

                // Notify clients to trigger turn reconciliation
                onReconnected?()
            } catch {
                isReady = false
                await transport.stop()
                backoffDelay = min(backoffDelay * 2.0, maxBackoffDelay)
                print("[CodexCore] Reconnection failed: \(error)")
            }
        }
    }

    private func tryConnect() async throws {
        guard let onMessageLocal = onMessage else { return }

        try await transport.start(
            onMessage: { msg in
                onMessageLocal(msg)
            },
            onError: { [weak self] err in
                Task { [weak self] in
                    await self?.handleTransportError(err)
                }
            }
        )
    }

    private func handleTransportError(_ error: Error) async {
        isReady = false
        onError?(error)
        await onDisconnect?(error)
        handleDisconnect()
    }

    func bufferedRequestIDs() -> Set<Int64> {
        Set(outbox.compactMap { payload in
            guard let id = payload["id"] else { return nil }
            switch id {
            case .int(let value): return Int64(value)
            case .double(let value): return Int64(value)
            case .string(let value): return Int64(value)
            default: return nil
            }
        })
    }

    private func flushOutbox() async throws {
        guard !outbox.isEmpty else { return }
        print("[CodexCore] Flushing \(outbox.count) buffered outbox messages...")
        while let payload = outbox.first {
            try await transport.send(payload)
            outbox.removeFirst()
        }
    }
}
