import XCTest
import CodexCore
@testable import CodexCoreUI

final class CodexThreadHistoryCacheTests: XCTestCase {
    @MainActor
    func testDeferredForkDoesNotActivateThreadUntilCommitted() async throws {
        let transport = UIHistoryCacheTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        await transport.resetSentPayloads()

        let source = Self.restoreResult(threadID: "thread-source", text: "Source")
        store.hydrate(source.hydration)
        let session = CodexThreadSession()
        _ = session.activateCachedThread(id: "thread-source", using: codex)

        let forkResult = try await session.forkCurrentThread(
            using: codex,
            configuration: CodexThreadLaunchConfiguration(
                approvalMode: .autoReview,
                cwd: "/tmp",
                modelIdentifier: nil,
                sandbox: .workspaceWrite
            ),
            activate: false
        )
        let fork = try XCTUnwrap(forkResult)

        XCTAssertEqual(fork.sourceID, "thread-source")
        XCTAssertEqual(fork.thread.id, "thread-forked")
        XCTAssertEqual(session.currentThreadID, "thread-source")
        XCTAssertEqual(store.activeThread?.id, "thread-source")

        session.activateResumedThread(fork.thread, using: codex)

        XCTAssertEqual(session.currentThreadID, "thread-forked")
        XCTAssertEqual(store.activeThread?.id, "thread-forked")
        await codex.close()
    }

    @MainActor
    func testDeferredResumeDoesNotActivateThreadUntilCommitted() async throws {
        let transport = UIHistoryCacheTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        await transport.resetSentPayloads()

        let session = CodexThreadSession()
        let result = try await session.resumeThreadWithHistory(
            id: "thread-deferred",
            using: codex,
            configuration: CodexThreadLaunchConfiguration(
                approvalMode: .autoReview,
                cwd: "/tmp",
                modelIdentifier: nil,
                sandbox: .workspaceWrite
            ),
            activate: false
        )

        XCTAssertEqual(result.thread.id, "thread-deferred")
        XCTAssertNil(session.currentThreadID)
        XCTAssertNil(store.activeThread?.id)

        let parentRaw = try result.rawResponse()
        _ = await CodexThreadHistorySession.load(
            parentRaw: parentRaw,
            using: codex,
            activateParent: false
        )

        XCTAssertNil(store.activeThread?.id)
        XCTAssertNotNil(store.threadSnapshot(id: "thread-deferred"))

        session.activateResumedThread(result.thread, using: codex)

        XCTAssertEqual(session.currentThreadID, "thread-deferred")
        XCTAssertEqual(store.activeThread?.id, "thread-deferred")
        await codex.close()
    }

    @MainActor
    func testCachedThreadActivationDoesNotCallAppServer() async throws {
        let transport = UIHistoryCacheTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        await transport.resetSentPayloads()

        let result = Self.restoreResult(threadID: "thread-cached", text: "Already loaded")
        store.hydrate(result.hydration)

        let session = CodexThreadSession()
        let thread = session.activateCachedThread(id: "thread-cached", using: codex)

        XCTAssertEqual(thread.id, "thread-cached")
        XCTAssertEqual(session.currentThreadID, "thread-cached")
        XCTAssertEqual(store.activeThread?.id, "thread-cached")

        let sentMethods = await transport.sentMethods()
        XCTAssertFalse(sentMethods.contains("thread/resume"))
        XCTAssertFalse(sentMethods.contains("thread/read"))
        await codex.close()
    }

    func testThreadHistoryCacheEvictsLeastRecentlyUsedEntry() {
        var cache = CodexThreadHistoryCache(capacity: 2)
        cache.store(Self.restoreResult(threadID: "thread-a", text: "A"))
        cache.store(Self.restoreResult(threadID: "thread-b", text: "B"))

        XCTAssertEqual(cache.result(for: "thread-a")?.snapshot.messages.first?.text, "A")

        cache.store(Self.restoreResult(threadID: "thread-c", text: "C"))

        XCTAssertNotNil(cache.result(for: "thread-a"))
        XCTAssertNil(cache.result(for: "thread-b"))
        XCTAssertNotNil(cache.result(for: "thread-c"))
        XCTAssertEqual(cache.count, 2)
    }

    func testThreadHistoryCacheDefaultCapacityKeepsTwentyRecentEntries() {
        var cache = CodexThreadHistoryCache()
        for index in 0..<20 {
            cache.store(Self.restoreResult(threadID: "thread-\(index)", text: "\(index)"))
        }

        XCTAssertEqual(cache.count, 20)
        XCTAssertNotNil(cache.result(for: "thread-0"))
        XCTAssertNotNil(cache.result(for: "thread-19"))

        cache.store(Self.restoreResult(threadID: "thread-20", text: "20"))

        XCTAssertEqual(cache.count, 20)
        XCTAssertNil(cache.result(for: "thread-1"))
        XCTAssertNotNil(cache.result(for: "thread-0"))
        XCTAssertNotNil(cache.result(for: "thread-20"))
    }

    func testThreadHistoryCacheKeepsProtectedEntriesOutsideRecentCapacity() {
        var cache = CodexThreadHistoryCache(capacity: 2)
        cache.store(Self.restoreResult(threadID: "thread-a", text: "A"))
        cache.store(Self.restoreResult(threadID: "thread-b", text: "B"))

        cache.protect(threadID: "thread-a")
        cache.store(Self.restoreResult(threadID: "thread-c", text: "C"))
        cache.store(Self.restoreResult(threadID: "thread-d", text: "D"))

        XCTAssertNotNil(cache.result(for: "thread-a"))
        XCTAssertNil(cache.result(for: "thread-b"))
        XCTAssertNotNil(cache.result(for: "thread-c"))
        XCTAssertNotNil(cache.result(for: "thread-d"))
        XCTAssertEqual(cache.count, 3)
    }

    func testThreadHistoryCacheKeepsProtectedEntryWithZeroPassiveCapacity() {
        var cache = CodexThreadHistoryCache(capacity: 0)

        cache.store(Self.restoreResult(threadID: "thread-passive", text: "Passive"))
        XCTAssertNil(cache.result(for: "thread-passive"))

        cache.store(Self.restoreResult(threadID: "thread-active", text: "Active"), protected: true)
        cache.store(Self.restoreResult(threadID: "thread-other", text: "Other"))

        XCTAssertNotNil(cache.result(for: "thread-active"))
        XCTAssertNil(cache.result(for: "thread-other"))
        XCTAssertEqual(cache.count, 1)
    }

    func testThreadHistoryCacheRefreshPreservesExistingProtection() {
        var cache = CodexThreadHistoryCache(capacity: 0)
        cache.store(Self.restoreResult(threadID: "thread-active", text: "Old"), protected: true)

        cache.store(Self.restoreResult(threadID: "thread-active", text: "Fresh"))

        XCTAssertTrue(cache.isProtected(threadID: "thread-active"))
        XCTAssertEqual(cache.result(for: "thread-active")?.snapshot.messages.first?.text, "Fresh")
        XCTAssertEqual(cache.count, 1)
    }

    func testThreadHistoryCacheRemoveDropsEntryAndRetainsRemainingOrder() {
        var cache = CodexThreadHistoryCache(capacity: 2)
        cache.store(Self.restoreResult(threadID: "thread-a", text: "A"))
        cache.store(Self.restoreResult(threadID: "thread-b", text: "B"))

        cache.remove(threadID: "thread-a")
        cache.store(Self.restoreResult(threadID: "thread-c", text: "C"))

        XCTAssertNil(cache.result(for: "thread-a"))
        XCTAssertNotNil(cache.result(for: "thread-b"))
        XCTAssertNotNil(cache.result(for: "thread-c"))
        XCTAssertEqual(cache.count, 2)
    }

    private static func restoreResult(threadID: String, text: String) -> CodexThreadHistoryRestoreResult {
        let now = Date(timeIntervalSince1970: 1_800)
        let thread = CodexThreadSnapshot(
            id: threadID,
            turns: [
                CodexTurnSnapshot(
                    id: "turn-\(threadID)",
                    status: .completed,
                    startedAt: now,
                    completedAt: now,
                    items: [
                        .assistantMessage(
                            id: "assistant-\(threadID)",
                            text: text,
                            timestamp: now,
                            isStreaming: false
                        )
                    ]
                )
            ],
            updatedAt: now
        )
        let hydration = CodexThreadHistoryHydrationResult(parent: CodexHydratedThread(snapshot: thread))
        return CodexThreadHistoryRestoreResult(
            snapshot: CodexThreadHistorySnapshot(hydration: hydration),
            hydration: hydration
        )
    }
}

private actor UIHistoryCacheTransport: CodexTransport {
    var isConnected = false
    var onMessage: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    private var sentPayloads: [[String: CodexJSONValue]] = []

    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        self.onMessage = onMessage
        self.onError = onError
        isConnected = true
    }

    func send(_ payload: [String: CodexJSONValue]) async throws {
        sentPayloads.append(payload)
        guard let idValue = payload["id"], payload["method"] != nil else { return }
        let method: String? = {
            guard case .string(let method)? = payload["method"] else { return nil }
            return method
        }()
        let result: String
        switch method {
        case "thread/fork":
            result = #"{"thread":{"id":"thread-forked"}}"#
        case "thread/resume":
            let threadID: String = {
                guard case .dictionary(let params)? = payload["params"],
                      case .string(let threadID)? = params["threadId"] else {
                    return "thread-resumed"
                }
                return threadID
            }()
            result = """
            {
                "thread": {
                    "id": "\(threadID)",
                    "cliVersion": "1.0.0",
                    "createdAt": 1781075531,
                    "cwd": "/tmp",
                    "ephemeral": false,
                    "modelProvider": "openai",
                    "preview": "Deferred resume",
                    "sessionId": "session-\(threadID)",
                    "source": "cli",
                    "status": {"type": "idle"},
                    "turns": [],
                    "updatedAt": 1781075532
                },
                "model": "gpt-5.5",
                "modelProvider": "openai",
                "cwd": "/tmp",
                "approvalPolicy": "on-request",
                "approvalsReviewer": "auto_review",
                "sandbox": {"type": "workspaceWrite"},
                "serviceTier": null
            }
            """
        default:
            result = #"{"serverInfo":{"name":"codex","version":"1.0.0"},"userAgent":"codex/1.0.0"}"#
        }
        let response = """
        {
            "jsonrpc": "2.0",
            "id": \(idValue.description),
            "result": \(result)
        }
        """
        Task { [weak self] in
            await self?.receiveMessage(response)
        }
    }

    func stop() async {
        isConnected = false
    }

    func resetSentPayloads() {
        sentPayloads.removeAll()
    }

    func sentMethods() -> [String] {
        sentPayloads.compactMap { payload in
            guard case .string(let method)? = payload["method"] else { return nil }
            return method
        }
    }

    private func receiveMessage(_ message: String) {
        onMessage?(message)
    }
}
