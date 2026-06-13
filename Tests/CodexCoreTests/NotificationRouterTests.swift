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
}
