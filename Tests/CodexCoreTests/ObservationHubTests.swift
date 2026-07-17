import XCTest
@testable import CodexCore

final class ObservationHubTests: XCTestCase {
    func testAtomicSeedAndSignalsCoalesceToLatestAffectedRevision() async {
        let hub = ObservationHub()
        let thread: ThreadID = "thread"
        var state = "seed"
        let observation = hub.observe(
            scope: .thread(thread, fields: .itemContent),
            revision: StateRevision(7),
            seed: { state }
        )

        XCTAssertEqual(observation.seed, "seed")
        XCTAssertEqual(observation.revision, StateRevision(7))
        XCTAssertEqual(hub.observerCount, 1)

        state = "latest"
        hub.publish(itemChange(revision: 8, thread: thread))
        hub.publish(itemChange(revision: 9, thread: thread))
        hub.publish(itemChange(revision: 10, thread: thread))

        var iterator = observation.signals.makeAsyncIterator()
        let signal = await iterator.next()
        XCTAssertEqual(signal?.latestRevision, StateRevision(10))
        XCTAssertEqual(state, "latest")
    }

    func testPublishSignalsOnlyMatchingEntityAndFieldScopes() async {
        let hub = ObservationHub()
        let matching = hub.observe(
            scope: .thread("matching", fields: .itemContent),
            revision: .zero,
            seed: { () }
        )
        let otherThread = hub.observe(
            scope: .thread("other", fields: .itemContent),
            revision: .zero,
            seed: { () }
        )
        let otherField = hub.observe(
            scope: .thread("matching", fields: .threadStatus),
            revision: .zero,
            seed: { () }
        )

        hub.publish(itemChange(revision: 1, thread: "matching"))
        hub.cancelObservation(otherThread.id)
        hub.cancelObservation(otherField.id)

        var matchingIterator = matching.signals.makeAsyncIterator()
        var otherThreadIterator = otherThread.signals.makeAsyncIterator()
        var otherFieldIterator = otherField.signals.makeAsyncIterator()
        let matchingSignal = await matchingIterator.next()
        let otherThreadSignal = await otherThreadIterator.next()
        let otherFieldSignal = await otherFieldIterator.next()
        XCTAssertEqual(matchingSignal?.latestRevision, StateRevision(1))
        XCTAssertNil(otherThreadSignal)
        XCTAssertNil(otherFieldSignal)
    }

    func testExplicitCancellationAndFinishAllTerminateStreams() async {
        let hub = ObservationHub()
        let cancelled = hub.observe(revision: .zero, seed: { "cancelled" })
        let finished = hub.observe(revision: .zero, seed: { "finished" })

        hub.cancelObservation(cancelled.id)
        XCTAssertEqual(hub.observerCount, 1)
        var cancelledIterator = cancelled.signals.makeAsyncIterator()
        let cancelledSignal = await cancelledIterator.next()
        XCTAssertNil(cancelledSignal)

        hub.finishAll()
        XCTAssertEqual(hub.observerCount, 0)
        var finishedIterator = finished.signals.makeAsyncIterator()
        let finishedSignal = await finishedIterator.next()
        XCTAssertNil(finishedSignal)
    }

    func testCancellingConsumerDisconnectsItsRegistration() async {
        let hub = ObservationHub()
        let observation = hub.observe(revision: .zero, seed: { () })
        let consumer = Task {
            for await _ in observation.signals {}
        }
        XCTAssertEqual(hub.observerCount, 1)

        consumer.cancel()
        await consumer.value

        XCTAssertEqual(hub.observerCount, 0)
    }

    private func itemChange(revision: UInt64, thread: ThreadID) -> StateChangeSet {
        StateChangeSet(
            revision: StateRevision(revision),
            fields: .itemContent,
            itemKeys: [ItemKey(threadID: thread, turnID: "turn", itemID: "item")]
        )
    }
}
