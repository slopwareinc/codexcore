import XCTest
@testable import CodexCore

final class ReconnectionManagerTests: XCTestCase {
    func testReconnectionCompletesHandshakeBeforeFlushingBufferedRequests() async throws {
        let transport = FlakyReconnectTransport(failuresBeforeSuccess: 2)
        let sleeps = RecordedSleeps()
        let manager = CodexReconnectionManager(
            transport: transport,
            sleep: { delay in
                await sleeps.append(delay)
            }
        )

        await manager.configure(
            onMessage: { _ in },
            onError: { _ in },
            beforeReplay: {
                try await transport.send(["method": .string("initialize")])
                try await transport.send(["method": .string("initialized")])
            },
            onReconnected: {}
        )
        try await manager.sendOrBuffer(["id": .int(1), "method": .string("thread/list")])
        await manager.handleDisconnect()

        try await waitUntil {
            await transport.sentPayloadCount == 3
        }

        let recordedSleeps = await sleeps.values
        let startAttemptCount = await transport.startAttemptCount
        let sentPayloads = await transport.sentPayloads

        XCTAssertEqual(recordedSleeps, [1.0, 2.0, 4.0])
        XCTAssertEqual(startAttemptCount, 3)
        XCTAssertEqual(sentPayloads.compactMap { $0["method"] }, [
            .string("initialize"),
            .string("initialized"),
            .string("thread/list")
        ])
    }

    func testFailedHandshakeStaysInRetryLoopAndDoesNotFlushOutbox() async throws {
        let transport = FlakyReconnectTransport(failuresBeforeSuccess: 0)
        let sleeps = RecordedSleeps()
        let attempts = AttemptCounter()
        let manager = CodexReconnectionManager(
            transport: transport,
            sleep: { delay in
                await sleeps.append(delay)
            }
        )

        await manager.configure(
            onMessage: { _ in },
            onError: { _ in },
            beforeReplay: {
                let attempt = await attempts.increment()
                try await transport.send(["method": .string("initialize")])
                if attempt == 1 {
                    throw ReconnectFixtureError()
                }
                try await transport.send(["method": .string("initialized")])
            },
            onReconnected: {}
        )
        try await manager.sendOrBuffer(["id": .int(1), "method": .string("thread/list")])
        await manager.handleDisconnect()

        try await waitUntil {
            await transport.sentPayloadCount == 4
        }

        let methods = await transport.sentPayloads.compactMap { $0["method"] }
        XCTAssertEqual(methods, [
            .string("initialize"),
            .string("initialize"),
            .string("initialized"),
            .string("thread/list")
        ])
        let startAttemptCount = await transport.startAttemptCount
        let recordedSleeps = await sleeps.values
        XCTAssertEqual(startAttemptCount, 2)
        XCTAssertEqual(recordedSleeps, [1.0, 2.0])
    }

    func testBufferedRequestContinuationSurvivesFailedHandshakeRecovery() async throws {
        let transport = HandshakeRecoveryTransport()
        let reconnectGate = ReconnectGate()
        let connection = CodexConnection(
            transport: transport,
            reconnectSleep: { _ in await reconnectGate.wait() }
        )

        _ = try await connection.start(onNotification: { _ in }, onServerRequest: { _ in .null })
        await transport.disconnect()
        try await waitUntil { await reconnectGate.isWaiting }

        let request = Task {
            try await connection.request(method: "thread/list")
        }
        try await Task.sleep(for: .milliseconds(10))
        await reconnectGate.open()

        let result = try await request.value
        XCTAssertEqual(result, .dictionary(["recovered": .bool(true)]))

        let methods = await transport.sentMethods
        XCTAssertEqual(methods, [
            "initialize", "initialized",
            "initialize",
            "initialize", "initialized",
            "thread/list"
        ])
        let startAttemptCount = await transport.startAttemptCount
        let threadListSendCount = await transport.threadListSendCount
        XCTAssertEqual(startAttemptCount, 3)
        XCTAssertEqual(threadListSendCount, 1)
    }

    func testCodexConfigDefaultsCodexHomeUnlessExplicitlyProvided() {
        XCTAssertEqual(CodexConfig().environment["CODEX_HOME"], defaultCodexHome())
        XCTAssertEqual(CodexConfig(environment: ["CODEX_HOME": ""]).environment["CODEX_HOME"], defaultCodexHome())
        XCTAssertEqual(CodexConfig(environment: ["CODEX_HOME": "/tmp/codex-home"]).environment["CODEX_HOME"], "/tmp/codex-home")
    }

    func testCodexErrorFormattingUsesLocalizedDescriptions() {
        let localized = LocalizedFixtureError()
        XCTAssertEqual((localized as any CodexError).localizedDescription, "Friendly fixture failure")
        XCTAssertEqual(CodexErrorFormat.localizedDescription(localized), "Friendly fixture failure")

        let plainCodex = PlainCodexFixtureError()
        XCTAssertEqual((plainCodex as any CodexError).localizedDescription, "PlainCodexFixtureError()")
        XCTAssertEqual(CodexErrorFormat.localizedDescription(plainCodex), "PlainCodexFixtureError()")

        let longError = LongFixtureError()
        let longDescription = CodexErrorFormat.localizedDescription(longError)

        XCTAssertEqual(longDescription.count, 201)
        XCTAssertFalse(longDescription.hasSuffix("..."))
        XCTAssertTrue(longDescription.hasSuffix("…"))
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor RecordedSleeps {
    private var recorded: [TimeInterval] = []

    var values: [TimeInterval] { recorded }

    func append(_ delay: TimeInterval) {
        recorded.append(delay)
    }
}

private actor AttemptCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor ReconnectGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FlakyReconnectTransport: CodexTransport {
    private var failuresRemaining: Int
    private(set) var isConnected = false
    private var starts = 0
    private var sent: [[String: CodexJSONValue]] = []

    init(failuresBeforeSuccess: Int) {
        failuresRemaining = failuresBeforeSuccess
    }

    var startAttemptCount: Int { starts }
    var sentPayloadCount: Int { sent.count }
    var sentPayloads: [[String: CodexJSONValue]] { sent }

    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        starts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            isConnected = false
            throw ReconnectFixtureError()
        }
        isConnected = true
    }

    func send(_ payload: [String: CodexJSONValue]) async throws {
        sent.append(payload)
    }

    func stop() async {
        isConnected = false
    }
}

private actor HandshakeRecoveryTransport: CodexTransport {
    private(set) var isConnected = false
    private var starts = 0
    private var initializeSends = 0
    private var threadListSends = 0
    private var methods: [String] = []
    private var onMessage: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    var startAttemptCount: Int { starts }
    var threadListSendCount: Int { threadListSends }
    var sentMethods: [String] { methods }

    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        starts += 1
        self.onMessage = onMessage
        self.onError = onError
        isConnected = true
    }

    func send(_ payload: [String: CodexJSONValue]) async throws {
        guard isConnected else { throw ReconnectFixtureError() }
        guard case .string(let method)? = payload["method"] else { return }
        methods.append(method)

        guard let id = payload["id"] else { return }
        switch method {
        case "initialize":
            initializeSends += 1
            if initializeSends == 2 {
                respond(id: id, body: #""error":{"code":-32000,"message":"handshake rejected"}"#)
            } else {
                respond(
                    id: id,
                    body: #""result":{"serverInfo":{"name":"codex","version":"1.0.0"},"userAgent":"codex/1.0.0"}"#
                )
            }
        case "thread/list":
            threadListSends += 1
            respond(id: id, body: #""result":{"recovered":true}"#)
        default:
            respond(id: id, body: #""result":{}"#)
        }
    }

    func stop() async {
        isConnected = false
    }

    func disconnect() {
        isConnected = false
        onError?(ReconnectFixtureError())
    }

    private func respond(id: CodexJSONValue, body: String) {
        let response = #"{"jsonrpc":"2.0","id":\#(id.description),\#(body)}"#
        onMessage?(response)
    }
}

private struct ReconnectFixtureError: Error {}

private struct LocalizedFixtureError: CodexError, LocalizedError {
    var errorDescription: String? { "Friendly fixture failure" }
}

private struct PlainCodexFixtureError: CodexError {}

private struct LongFixtureError: Error, LocalizedError {
    var errorDescription: String? { String(repeating: "x", count: 240) }
}
