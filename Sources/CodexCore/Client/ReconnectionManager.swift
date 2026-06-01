import Foundation

// MARK: - Reconnection Manager

public actor CodexReconnectionManager {
    private let transport: any CodexTransport
    private var isReconnecting = false
    private var backoffDelay: TimeInterval = 1.0
    private let maxBackoffDelay: TimeInterval = 30.0

    // Outbox packet buffer for outgoing requests while connection is down
    private var outbox: [[String: CodexJSONValue]] = []

    // Reconnection callbacks
    private var onReconnected: (@Sendable () -> Void)?
    private var onMessage: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    public init(transport: any CodexTransport) {
        self.transport = transport
    }

    public func configure(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onReconnected: @escaping @Sendable () -> Void
    ) {
        self.onMessage = onMessage
        self.onError = onError
        self.onReconnected = onReconnected
    }

    public func start() async throws {
        try await tryConnect()
    }

    public func sendOrBuffer(_ payload: [String: CodexJSONValue]) async throws {
        let connected = await transport.isConnected
        if connected {
            try await transport.send(payload)
        } else {
            outbox.append(payload)
            print("[CodexCore] Connection down. Buffered request. Outbox size: \(outbox.count)")
        }
    }

    public func handleDisconnect() {
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
            try? await Task.sleep(for: .seconds(backoffDelay))

            do {
                try await tryConnect()
                isReconnecting = false
                backoffDelay = 1.0
                print("[CodexCore] Reconnected successfully!")

                // Flush outbox
                try await flushOutbox()

                // Notify clients to trigger turn reconciliation
                onReconnected?()
            } catch {
                backoffDelay = min(backoffDelay * 2.0, maxBackoffDelay)
                print("[CodexCore] Reconnection failed: \(error)")
            }
        }
    }

    private func tryConnect() async throws {
        guard let onMessageLocal = onMessage, let onErrorLocal = onError else { return }

        try await transport.start(
            onMessage: { msg in
                onMessageLocal(msg)
            },
            onError: { [weak self] err in
                onErrorLocal(err)
                if let self {
                    Task { [weak self] in
                        await self?.handleDisconnect()
                    }
                }
            }
        )
    }

    private func flushOutbox() async throws {
        guard !outbox.isEmpty else { return }
        print("[CodexCore] Flushing \(outbox.count) buffered outbox messages...")
        let pending = outbox
        outbox.removeAll()

        for payload in pending {
            try await transport.send(payload)
        }
    }
}
