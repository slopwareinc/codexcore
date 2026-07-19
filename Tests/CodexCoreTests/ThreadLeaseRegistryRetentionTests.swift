import XCTest
@testable import CodexCore

final class ThreadLeaseRegistryRetentionTests: XCTestCase {
    func testSuccessfulFinalUnsubscribeEmitsOneDetailEviction() throws {
        var registry = ThreadLeaseRegistry()
        XCTAssertEqual(registry.connectionReady(1), [])
        let acquired = registry.acquireAdoptingLiveSubscription(
            threadID: "thread",
            reason: .selectedUI,
            connectionEpoch: 1
        )

        let release = registry.release(acquired.token)
        XCTAssertTrue(release.didRelease)
        let unsubscribe = try XCTUnwrap(release.effects.first)
        guard case .unsubscribe(let command) = unsubscribe else {
            return XCTFail("Expected the final lease to unsubscribe")
        }

        XCTAssertEqual(
            registry.unsubscribeSucceeded(command),
            [.evictDetail("thread")]
        )
        XCTAssertEqual(registry.unsubscribeSucceeded(command), [])
        XCTAssertNil(registry.snapshot(for: "thread"))
    }

    func testReacquireDuringUnsubscribeReconcilesWithoutEvictingDetail() throws {
        var registry = ThreadLeaseRegistry()
        _ = registry.connectionReady(7)
        let first = registry.acquireAdoptingLiveSubscription(
            threadID: "thread",
            reason: .selectedUI,
            connectionEpoch: 7
        )
        let release = registry.release(first.token)
        guard case .unsubscribe(let unsubscribe) = try XCTUnwrap(release.effects.first) else {
            return XCTFail("Expected unsubscribe")
        }

        let replacement = registry.acquire(
            threadID: "thread",
            reason: .pendingServerRequest("7:request")
        )
        XCTAssertEqual(replacement.effects, [])

        let completion = registry.unsubscribeSucceeded(unsubscribe)
        guard case .reconcile(let reconciliation) = try XCTUnwrap(completion.first) else {
            return XCTFail("Expected replacement reconciliation")
        }
        XCTAssertEqual(reconciliation.threadID, "thread")
        XCTAssertEqual(reconciliation.connectionEpoch, 7)
        XCTAssertFalse(completion.contains(.evictDetail("thread")))
        XCTAssertEqual(registry.snapshot(for: "thread")?.leases.count, 1)
    }
}
