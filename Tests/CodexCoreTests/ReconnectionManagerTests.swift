import XCTest
@testable import CodexCore

final class ReconnectionManagerTests: XCTestCase {
    func testReconnectionBackoffFlushesBufferedRequests() async throws {
        let transport = FlakyReconnectTransport(failuresBeforeSuccess: 2)
        let sleeps = RecordedSleeps()
        let manager = CodexReconnectionManager(
            transport: transport,
            sleep: { delay in
                await sleeps.append(delay)
            }
        )

        await manager.configure(onMessage: { _ in }, onError: { _ in }, onReconnected: {})
        try await manager.sendOrBuffer(["id": .int(1), "method": .string("thread/list")])
        await manager.handleDisconnect()

        try await waitUntil {
            await transport.sentPayloadCount == 1
        }

        let recordedSleeps = await sleeps.values
        let startAttemptCount = await transport.startAttemptCount
        let sentPayloads = await transport.sentPayloads

        XCTAssertEqual(recordedSleeps, [1.0, 2.0, 4.0])
        XCTAssertEqual(startAttemptCount, 3)
        XCTAssertEqual(sentPayloads.first?["method"], .string("thread/list"))
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

private struct ReconnectFixtureError: Error {}

private struct LocalizedFixtureError: CodexError, LocalizedError {
    var errorDescription: String? { "Friendly fixture failure" }
}

private struct PlainCodexFixtureError: CodexError {}

private struct LongFixtureError: Error, LocalizedError {
    var errorDescription: String? { String(repeating: "x", count: 240) }
}
