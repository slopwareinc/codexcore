import XCTest
@testable import CodexCore

final class ThreadRuntimeRegistryTests: XCTestCase {
    func testSuccessfulResumeMakesSubscriptionUsableBeforeHydrationCompletes() throws {
        var registry = ThreadRuntimeRegistry()
        XCTAssertTrue(registry.connectionReady(7).isEmpty)
        let acquisition = registry.retain("thread")
        let resume = try resumeCommand(acquisition.effects)

        XCTAssertTrue(registry.resumeSucceeded(
            resume,
            anchors: .init(
                turnsBackwardsCursor: "turn-head",
                itemsBackwardsCursor: "item-head"
            )
        ).isEmpty)

        let snapshot = try XCTUnwrap(registry.snapshot(for: "thread"))
        XCTAssertTrue(snapshot.subscriptionDesired)
        XCTAssertTrue(snapshot.subscriptionUsable)
        XCTAssertEqual(snapshot.actual, .subscribed(connectionEpoch: 7))
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertEqual(snapshot.hydration.phase, .paging(resume))
    }

    func testReleaseDuringResumeWaitsThenUnsubscribes() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(1)
        let acquisition = registry.retain("thread")
        let resume = try resumeCommand(acquisition.effects)

        let release = registry.release(acquisition.retainer)
        XCTAssertTrue(release.didRelease)
        XCTAssertTrue(release.effects.isEmpty)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .resuming(resume))

        let unsubscribe = try unsubscribeCommand(registry.resumeSucceeded(
            resume,
            anchors: .init(turnsBackwardsCursor: nil, itemsBackwardsCursor: nil)
        ))
        XCTAssertGreaterThan(unsubscribe.generation, resume.generation)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .unsubscribing(unsubscribe))
    }

    func testReacquireDuringUnsubscribeWaitsThenResumes() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(2)
        let first = registry.retain("thread")
        let initialResume = try resumeCommand(first.effects)
        XCTAssertTrue(registry.resumeSucceeded(
            initialResume,
            anchors: .init(turnsBackwardsCursor: nil, itemsBackwardsCursor: nil)
        ).isEmpty)
        let unsubscribe = try unsubscribeCommand(registry.release(first.retainer).effects)

        let replacement = registry.retain("thread")
        XCTAssertTrue(replacement.effects.isEmpty)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .unsubscribing(unsubscribe))

        let resumed = try resumeCommand(registry.unsubscribeSucceeded(unsubscribe))
        XCTAssertGreaterThan(resumed.generation, unsubscribe.generation)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .resuming(resumed))
    }

    func testErrorsBecomeUnknownAndConvergeTowardCurrentDesire() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(3)
        let first = registry.retain("thread")
        let resume = try resumeCommand(first.effects)

        XCTAssertTrue(registry.resumeFailed(resume, message: "failed").isEmpty)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .idle)
        let retriedResume = try resumeCommand(registry.reconcile("thread"))
        XCTAssertGreaterThan(retriedResume.generation, resume.generation)
        XCTAssertEqual(
            registry.snapshot(for: "thread")?.actual,
            .unknown(connectionEpoch: 3)
        )

        XCTAssertTrue(registry.release(first.retainer).effects.isEmpty)
        let cleanup = try unsubscribeCommand(registry.resumeFailed(
            retriedResume,
            message: "uncertain"
        ))
        XCTAssertEqual(
            registry.snapshot(for: "thread")?.actual,
            .unknown(connectionEpoch: 3)
        )

        XCTAssertTrue(registry.unsubscribeFailed(cleanup).isEmpty)
        let retryCleanup = try unsubscribeCommand(registry.reconcile("thread"))
        XCTAssertGreaterThan(retryCleanup.generation, cleanup.generation)
    }

    func testNewerSubscriptionCommandRejectsOldHydrationPages() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(4)
        let acquisition = registry.retain("thread")
        let resume = try resumeCommand(acquisition.effects)
        _ = registry.resumeSucceeded(
            resume,
            anchors: .init(turnsBackwardsCursor: "turn-head", itemsBackwardsCursor: nil)
        )

        let unsubscribe = try unsubscribeCommand(registry.release(acquisition.retainer).effects)
        XCTAssertGreaterThan(unsubscribe.generation, resume.generation)
        XCTAssertFalse(registry.updateTurnsPage(
            resume,
            backwardsCursor: "turn-head",
            nextCursor: "turn-older"
        ))
    }

    func testEpochAndGenerationRejectStaleCompletions() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(10)
        let acquisition = registry.retain("thread")
        let oldResume = try resumeCommand(acquisition.effects)

        registry.connectionLost(10)
        let effects = registry.connectionReady(11)
        let currentResume = try resumeCommand(effects)
        XCTAssertGreaterThan(currentResume.generation, oldResume.generation)

        XCTAssertTrue(registry.resumeSucceeded(
            oldResume,
            anchors: .init(turnsBackwardsCursor: nil, itemsBackwardsCursor: nil)
        ).isEmpty)
        XCTAssertEqual(registry.snapshot(for: "thread")?.phase, .resuming(currentResume))
        XCTAssertEqual(
            registry.snapshot(for: "thread")?.actual,
            .unsubscribed(connectionEpoch: 11)
        )

        XCTAssertTrue(registry.resumeSucceeded(
            currentResume,
            anchors: .init(turnsBackwardsCursor: "turn-head", itemsBackwardsCursor: nil)
        ).isEmpty)
        XCTAssertFalse(registry.updateTurnsPage(
            oldResume,
            backwardsCursor: "old",
            nextCursor: nil
        ))
    }

    func testHydrationTracksOpaquePagesAtResumeGeneration() throws {
        var registry = ThreadRuntimeRegistry()
        _ = registry.connectionReady(12)
        let resume = try resumeCommand(registry.retain("thread").effects)
        _ = registry.resumeSucceeded(
            resume,
            anchors: .init(turnsBackwardsCursor: "turn-head", itemsBackwardsCursor: "item-head")
        )

        XCTAssertTrue(registry.updateTurnsPage(
            resume,
            backwardsCursor: "turn-head",
            nextCursor: "turn-older"
        ))
        XCTAssertTrue(registry.updateItemsPage(
            resume,
            turnID: "turn-1",
            backwardsCursor: "item-head",
            nextCursor: nil
        ))
        XCTAssertTrue(registry.hydrationSucceeded(resume))

        let hydration = try XCTUnwrap(registry.snapshot(for: "thread")).hydration
        XCTAssertEqual(hydration.anchors?.turnsBackwardsCursor, "turn-head")
        XCTAssertEqual(hydration.anchors?.itemsBackwardsCursor, "item-head")
        XCTAssertEqual(hydration.turnsPage.nextCursor, "turn-older")
        XCTAssertEqual(hydration.itemPagesByTurn["turn-1"]?.isExhausted, true)
        XCTAssertEqual(hydration.phase, .ready(resume))
    }

    private func resumeCommand(
        _ effects: [ThreadRuntimeEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ThreadRuntimeCommand {
        guard effects.count == 1, case .resume(let command) = effects[0] else {
            XCTFail("Expected one resume effect, got \(effects)", file: file, line: line)
            throw ThreadRuntimeTestFailure.unexpectedEffect
        }
        return command
    }

    private func unsubscribeCommand(
        _ effects: [ThreadRuntimeEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ThreadRuntimeCommand {
        guard effects.count == 1, case .unsubscribe(let command) = effects[0] else {
            XCTFail("Expected one unsubscribe effect, got \(effects)", file: file, line: line)
            throw ThreadRuntimeTestFailure.unexpectedEffect
        }
        return command
    }
}

private enum ThreadRuntimeTestFailure: Error {
    case unexpectedEffect
}
