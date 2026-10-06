import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexSharedReadTests: XCTestCase {
    func testClaimedConsumerSurvivesPriorConsumerCancellationBeforeAsyncJoin() async throws {
        let worker = SharedReadTestWorker()
        let read = CodexSharedRead { try await worker.run() }
        let prior = Task { try await read.value() }
        try await waitForConsumers(1, in: read)
        try await waitForWorker(worker)

        // This is Repository's synchronous selection/claim boundary. Hold the
        // new consumer before its asynchronous continuation can be registered.
        let consumer = try XCTUnwrap(read.claimConsumer())
        let gate = SharedReadJoinGate()
        let joining = Task {
            await gate.wait()
            return try await consumer.value()
        }
        XCTAssertEqual(read.consumerCount, 2)
        prior.cancel()
        do {
            _ = try await prior.value
            XCTFail("Expected prior consumer cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(read.consumerCount, 1)
        XCTAssertTrue(read.acceptsConsumers)
        let cancelled = await worker.cancelled
        XCTAssertFalse(cancelled)
        await worker.complete(42)
        await gate.open()
        let value = try await joining.value
        XCTAssertEqual(value, 42)
        let starts = await worker.startCount
        XCTAssertEqual(starts, 1)
    }

    func testReleasingUnusedLastClaimCancelsWorker() async throws {
        let worker = SharedReadTestWorker()
        let read = CodexSharedRead { try await worker.run() }
        var consumer = read.claimConsumer()
        XCTAssertNotNil(consumer)
        try await waitForWorker(worker)
        XCTAssertEqual(read.consumerCount, 1)
        XCTAssertNotNil(consumer)
        consumer = nil
        XCTAssertFalse(read.acceptsConsumers)
        for _ in 0..<200 {
            if await worker.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await worker.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertNil(read.claimConsumer())
    }

    func testCancellingOneConsumerLeavesTheOtherAndOneWorkerRunning() async throws {
        let worker = SharedReadTestWorker()
        let read = CodexSharedRead { try await worker.run() }
        let first = Task { try await read.value() }
        let second = Task { try await read.value() }
        try await waitForConsumers(2, in: read)
        try await waitForWorker(worker)
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("Expected cancelled consumer")
        } catch is CancellationError {}
        XCTAssertEqual(read.consumerCount, 1)
        XCTAssertTrue(read.acceptsConsumers)
        let startCount = await worker.startCount
        let cancelled = await worker.cancelled
        XCTAssertEqual(startCount, 1)
        XCTAssertFalse(cancelled)
        await worker.complete(42)
        let value = try await second.value
        XCTAssertEqual(value, 42)
    }

    func testLastConsumerCancellationStopsWorkerAndRejectsNewConsumers() async throws {
        let worker = SharedReadTestWorker()
        let read = CodexSharedRead { try await worker.run() }
        let consumer = Task { try await read.value() }
        try await waitForConsumers(1, in: read)
        try await waitForWorker(worker)
        consumer.cancel()

        do {
            _ = try await consumer.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(read.acceptsConsumers)
        for _ in 0..<200 {
            if await worker.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await worker.cancelled
        XCTAssertTrue(cancelled)
        do {
            _ = try await read.value()
            XCTFail("An abandoned request cannot regain consumers")
        } catch is CancellationError {}
    }

    private func waitForConsumers(_ count: Int, in read: CodexSharedRead<Int>) async throws {
        for _ in 0..<200 {
            if read.consumerCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(count) registered consumers, got \(read.consumerCount)")
    }

    private func waitForWorker(_ worker: SharedReadTestWorker) async throws {
        for _ in 0..<200 {
            if await worker.startCount == 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Shared read worker did not start")
    }
}

private actor SharedReadJoinGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SharedReadTestWorker {
    private var continuation: CheckedContinuation<Int, Error>?
    private var completedValue: Int?
    private(set) var startCount = 0
    private(set) var cancelled = false

    func run() async throws -> Int {
        startCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else if let completedValue { continuation.resume(returning: completedValue) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func complete(_ value: Int) {
        completedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
