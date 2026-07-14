import XCTest
@testable import CodexCore

final class NotificationRouterTests: XCTestCase {

    private func turnNotification(method: String, turnId: String, extra: [String: CodexJSONValue] = [:]) -> JSONRPCNotification {
        var params: [String: CodexJSONValue] = ["turnId": .string(turnId), "threadId": .string("thread-1")]
        if method == "turn/completed" || method == "turn/started" {
            params = ["turn": .dictionary(["id": .string(turnId)]), "threadId": .string("thread-1")]
        }
        params.merge(extra) { _, new in new }
        return JSONRPCNotification(jsonrpc: "2.0", method: method, params: params)
    }

    private func pendingBufferCount(_ router: CodexNotificationRouter, turnId: String) async -> Int {
        await router.pendingTurnNotificationCount(turnId: turnId)
    }

    func testCompletionForUnregisteredTurnDropsBuffer() async {
        let router = CodexNotificationRouter()

        // Notifications for a turn nobody registered buffer initially...
        await router.route(turnNotification(method: "item/agentMessage/delta", turnId: "turn-x", extra: ["delta": .string("hi"), "itemId": .string("i1")]))
        let buffered = await pendingBufferCount(router, turnId: "turn-x")
        XCTAssertEqual(buffered, 1)

        // ...but completion of an unregistered turn evicts the whole buffer.
        await router.route(turnNotification(method: "turn/completed", turnId: "turn-x"))
        let afterCompletion = await pendingBufferCount(router, turnId: "turn-x")
        XCTAssertEqual(afterCompletion, 0, "completed unregistered turns must not leak replay buffers")
    }

    func testRegisteredTurnReplaysBufferIncludingCompletion() async {
        let router = CodexNotificationRouter()
        await router.registerTurn("turn-y")

        await router.route(turnNotification(method: "item/agentMessage/delta", turnId: "turn-y", extra: ["delta": .string("a"), "itemId": .string("i1")]))
        await router.route(turnNotification(method: "turn/completed", turnId: "turn-y"))

        // A late subscriber still receives the buffered events and a finished stream.
        var received: [String] = []
        for await notification in router.turnNotifications(turnId: "turn-y") {
            received.append(notification.method)
        }
        XCTAssertEqual(received, ["item/agentMessage/delta", "turn/completed"])
    }

    func testPendingBufferIsCapped() async {
        let router = CodexNotificationRouter()
        await router.registerTurn("turn-z")

        for index in 0..<600 {
            await router.route(turnNotification(
                method: "item/agentMessage/delta",
                turnId: "turn-z",
                extra: ["delta": .string("chunk-\(index)"), "itemId": .string("i1")]
            ))
        }

        let buffered = await pendingBufferCount(router, turnId: "turn-z")
        XCTAssertEqual(buffered, 512, "replay buffers must be capped")
    }

    func testPendingTurnIDsAreGloballyBoundedOldestFirst() async {
        let router = CodexNotificationRouter(
            maxPendingNotificationsPerTurn: 8,
            maxPendingTurnIDs: 2,
            maxPendingTurnEvents: 8
        )

        for id in ["oldest", "middle", "newest"] {
            await router.route(turnNotification(
                method: "item/agentMessage/delta",
                turnId: id,
                extra: ["delta": .string(id), "itemId": .string("i1")]
            ))
        }

        let oldestCount = await router.pendingTurnNotificationCount(turnId: "oldest")
        let middleCount = await router.pendingTurnNotificationCount(turnId: "middle")
        let newestCount = await router.pendingTurnNotificationCount(turnId: "newest")
        let idCount = await router.pendingTurnIDCount()
        XCTAssertEqual(oldestCount, 0)
        XCTAssertEqual(middleCount, 1)
        XCTAssertEqual(newestCount, 1)
        XCTAssertEqual(idCount, 2)
    }

    func testPendingTurnEventsAreGloballyBoundedOldestFirst() async {
        let router = CodexNotificationRouter(
            maxPendingNotificationsPerTurn: 8,
            maxPendingTurnIDs: 8,
            maxPendingTurnEvents: 2
        )

        await router.route(turnNotification(method: "item/agentMessage/delta", turnId: "a", extra: ["delta": .string("a1"), "itemId": .string("i1")]))
        await router.route(turnNotification(method: "item/agentMessage/delta", turnId: "b", extra: ["delta": .string("b1"), "itemId": .string("i1")]))
        await router.route(turnNotification(method: "item/agentMessage/delta", turnId: "a", extra: ["delta": .string("a2"), "itemId": .string("i1")]))

        let aCount = await router.pendingTurnNotificationCount(turnId: "a")
        let bCount = await router.pendingTurnNotificationCount(turnId: "b")
        let eventCount = await router.pendingTurnEventCount()
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)
        XCTAssertEqual(eventCount, 2)
    }

    func testLiveSubscriberStreamsAndFinishesOnCompletion() async {
        let router = CodexNotificationRouter()
        await router.registerTurn("turn-live")

        let collector = Task { () -> [String] in
            var methods: [String] = []
            for await notification in router.turnNotifications(turnId: "turn-live") {
                methods.append(notification.method)
            }
            return methods
        }

        // Give the subscriber a beat to attach.
        try? await Task.sleep(for: .milliseconds(50))

        await router.route(turnNotification(method: "item/started", turnId: "turn-live", extra: ["item": .dictionary(["id": .string("i1"), "type": .string("agentMessage")])]))
        await router.route(turnNotification(method: "turn/completed", turnId: "turn-live"))

        let received = await collector.value
        XCTAssertEqual(received, ["item/started", "turn/completed"])
    }

    func testLoginFailureWithoutLoginIDCompletesRegisteredLogin() async {
        let router = CodexNotificationRouter()
        await router.registerLogin("login-1")
        await router.route(JSONRPCNotification(
            jsonrpc: "2.0",
            method: CodexAppServerNotificationMethod.accountLoginCompleted.rawValue,
            params: ["success": .bool(false), "error": .string("denied")]
        ))

        var received: [AccountLoginCompletedNotification] = []
        for await notification in router.loginNotifications(loginId: "login-1") {
            if case .accountLoginCompleted(let payload) = notification.payload {
                received.append(payload)
            }
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.success, false)
        XCTAssertEqual(received.first?.error, "denied")
        XCTAssertNil(received.first?.loginId)
    }
}
