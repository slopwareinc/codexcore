import CodexCore
import XCTest
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
final class CodexApplicationTerminationCoordinatorTests: XCTestCase {
    func testModelDisconnectIsIdempotentAfterItsFirstDrain() async {
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )

        await model.disconnect()
        let activityCount = model.activityLog.activities.count
        await model.disconnect()

        XCTAssertEqual(model.activityLog.activities.count, activityCount)
    }

    func testDuplicateTerminationRequestsShareOneDisconnectAndReply() async {
        let coordinator = CodexApplicationTerminationCoordinator()
        let probe = Probe()

        coordinator.requestTermination(
            disconnect: { await probe.disconnect() },
            reply: { probe.replyCount += 1 }
        )
        coordinator.requestTermination(
            disconnect: { await probe.disconnect() },
            reply: { probe.replyCount += 1 }
        )

        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertEqual(coordinator.state, .draining)
        XCTAssertEqual(probe.disconnectCount, 1)
        XCTAssertEqual(probe.replyCount, 0)

        probe.releaseDisconnect()
        for _ in 0 ..< 10 { await Task.yield() }

        XCTAssertEqual(coordinator.state, .completed)
        XCTAssertEqual(probe.disconnectCount, 1)
        XCTAssertEqual(probe.replyCount, 2)

        // A late AppKit query is already safe and does not repeat the drain.
        coordinator.requestTermination(
            disconnect: { await probe.disconnect() },
            reply: { probe.replyCount += 1 }
        )
        XCTAssertEqual(probe.disconnectCount, 1)
        XCTAssertEqual(probe.replyCount, 3)
    }

    @MainActor
    private final class Probe {
        var disconnectCount = 0
        var replyCount = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func disconnect() async {
            disconnectCount += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func releaseDisconnect() {
            continuation?.resume()
            continuation = nil
        }
    }
}
