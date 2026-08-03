@testable import CodexCore
import Foundation
import XCTest

final class SessionOperationPrimitivesTests: XCTestCase {
    func testDiagnosticRingSanitizesBoundsAndReportsEviction() {
        var ring = CodexProtocolDiagnosticRing(limits: .init(
            maximumEntries: 2,
            maximumTextUTF8Bytes: 5
        ))

        ring.record(
            kind: .unknownMethod,
            method: "first-method",
            cursor: .init(connectionEpoch: 1, ordinal: 1)
        )
        ring.record(
            kind: .unmatchedResponse,
            method: "second-method",
            cursor: .init(connectionEpoch: 1, ordinal: 2),
            keyDescription: "abcdef",
            detail: "🙂🙂"
        )
        ring.record(
            kind: .lateServerRequestResolution,
            method: "third-method",
            cursor: .init(connectionEpoch: 1, ordinal: 3)
        )

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.totalRecordedCount, 3)
        XCTAssertEqual(snapshot.evictedCount, 1)
        XCTAssertEqual(snapshot.entries.map(\.cursor.ordinal), [2, 3])
        XCTAssertEqual(snapshot.entries[0].method, "secon")
        XCTAssertEqual(snapshot.entries[0].keyDescription, "abcde")
        XCTAssertEqual(snapshot.entries[0].detail, "🙂")
    }

    func testCommandOutputRouterRoutesExactIdentityAndFinishesOnResponse() async throws {
        var router = CodexCommandOutputRouter()
        let subscription = try router.register(
            connectionEpoch: 4,
            processID: "process-a",
            maximumDeltaCount: 2
        )

        XCTAssertThrowsError(try router.register(
            connectionEpoch: 4,
            processID: "process-a"
        )) { error in
            XCTAssertEqual(
                error as? CodexCommandOutputRouterError,
                .duplicateActiveProcess(subscription.token.key)
            )
        }

        let delta = Self.commandDelta(processID: "process-a", text: "hello")
        XCTAssertEqual(
            router.publish(connectionEpoch: 3, notification: delta),
            .unmatched(.init(connectionEpoch: 3, processID: "process-a"))
        )
        XCTAssertEqual(
            router.publish(connectionEpoch: 4, notification: delta),
            .delivered
        )
        XCTAssertTrue(router.finish(connectionEpoch: 4, processID: "process-a"))
        XCTAssertEqual(router.activeCount, 0)

        var iterator = subscription.deltas.makeAsyncIterator()
        let receivedDelta = try await iterator.next()
        XCTAssertEqual(receivedDelta, delta)
        let streamEnd = try await iterator.next()
        XCTAssertNil(streamEnd)
    }

    func testCommandOutputRouterDisconnectFailsOnlyMatchingEpoch() async throws {
        var router = CodexCommandOutputRouter()
        let first = try router.register(connectionEpoch: 1, processID: "same")
        let second = try router.register(connectionEpoch: 2, processID: "same")

        XCTAssertEqual(router.disconnect(connectionEpoch: 1), 1)
        XCTAssertEqual(router.activeCount, 1)

        var firstIterator = first.deltas.makeAsyncIterator()
        do {
            _ = try await firstIterator.next()
            XCTFail("Disconnected command stream should fail")
        } catch let error as CodexCommandOutputRouterError {
            XCTAssertEqual(error, .disconnected(connectionEpoch: 1))
        }

        let delta = Self.commandDelta(processID: "same", text: "epoch-two")
        XCTAssertEqual(router.publish(connectionEpoch: 2, notification: delta), .delivered)
        XCTAssertTrue(router.finish(connectionEpoch: 2, processID: "same"))
        var secondIterator = second.deltas.makeAsyncIterator()
        let receivedDelta = try await secondIterator.next()
        XCTAssertEqual(receivedDelta, delta)
        let streamEnd = try await secondIterator.next()
        XCTAssertNil(streamEnd)
    }

    func testSkillsHubCoalescesAndSupportsExplicitCancellation() async throws {
        var hub = CodexSkillsChangeObserverHub()
        let observation = hub.observe(connectionEpoch: 7)
        let first = CodexSchemaSkillsChangedNotification(.dictionary(["value": .int(1)]))
        let latest = CodexSchemaSkillsChangedNotification(.dictionary(["value": .int(2)]))

        XCTAssertEqual(hub.publish(connectionEpoch: 6, notification: first), 0)
        XCTAssertEqual(hub.publish(connectionEpoch: 7, notification: first), 1)
        XCTAssertEqual(hub.publish(connectionEpoch: 7, notification: latest), 1)

        var iterator = observation.changes.makeAsyncIterator()
        let receivedChange = try await iterator.next()
        XCTAssertEqual(receivedChange, latest)
        XCTAssertTrue(hub.cancel(observation.id))
        do {
            _ = try await iterator.next()
            XCTFail("Cancelled skills stream should fail")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(hub.observerCount, 0)
    }

    func testSkillsHubDisconnectFailsMatchingObservers() async throws {
        var hub = CodexSkillsChangeObserverHub()
        let first = hub.observe(connectionEpoch: 1)
        let second = hub.observe(connectionEpoch: 2)

        XCTAssertEqual(hub.disconnect(connectionEpoch: 1), 1)
        XCTAssertEqual(hub.observerCount, 1)

        var firstIterator = first.changes.makeAsyncIterator()
        do {
            _ = try await firstIterator.next()
            XCTFail("Disconnected skills stream should fail")
        } catch let error as CodexSkillsChangeObserverError {
            XCTAssertEqual(error, .disconnected(connectionEpoch: 1))
        }

        let change = CodexSchemaSkillsChangedNotification(.dictionary(["value": .int(2)]))
        XCTAssertEqual(hub.publish(connectionEpoch: 2, notification: change), 1)
        XCTAssertTrue(hub.cancel(second.id))
    }

    func testRealtimeHubRoutesOnlyTheMatchingEpochAndThread() async throws {
        var hub = CodexRealtimeObserverHub()
        let observation = hub.observe(connectionEpoch: 4, threadID: "voice")
        let event = CodexRealtimeEvent.transcriptDone(.init(
            role: "assistant",
            text: "Ready",
            threadID: "voice"
        ))

        XCTAssertEqual(hub.publish(connectionEpoch: 3, event: event), 0)
        XCTAssertEqual(
            hub.publish(
                connectionEpoch: 4,
                event: .transcriptDone(.init(
                    role: "assistant",
                    text: "Wrong task",
                    threadID: "other"
                ))
            ),
            0
        )
        XCTAssertEqual(hub.publish(connectionEpoch: 4, event: event), 1)

        var iterator = observation.events.makeAsyncIterator()
        let received = try await iterator.next()
        XCTAssertEqual(received, event)
        XCTAssertTrue(hub.cancel(observation.id))
    }

    func testRealtimeHubDisconnectFailsTheStream() async throws {
        var hub = CodexRealtimeObserverHub()
        let observation = hub.observe(connectionEpoch: 9, threadID: "voice")
        XCTAssertEqual(hub.disconnect(connectionEpoch: 9), 1)

        var iterator = observation.events.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Disconnected realtime stream should fail")
        } catch let error as CodexRealtimeObserverError {
            XCTAssertEqual(error, .disconnected(connectionEpoch: 9))
        }
    }

    func testOperationHubsRouteKeyedEventsAndTearDownByEpoch() async throws {
        var fileHub = CodexFSChangeObserverHub()
        let fileObservation = fileHub.observe(connectionEpoch: 4, watchID: "watch")
        let fileChange = CodexSchemaFSChangedNotification(changedPaths: [], watchID: "watch")
        XCTAssertEqual(
            fileHub.publish(connectionEpoch: 3, notification: fileChange),
            0
        )
        XCTAssertEqual(
            fileHub.publish(connectionEpoch: 4, notification: fileChange),
            1
        )
        var fileIterator = fileObservation.changes.makeAsyncIterator()
        XCTAssertEqual(try await fileIterator.next(), fileChange)
        XCTAssertTrue(fileHub.cancel(fileObservation.id))
        XCTAssertNil(try await fileIterator.next())

        var processHub = CodexProcessObserverHub()
        let processObservation = try processHub.observe(
            connectionEpoch: 2,
            processHandle: "process"
        )
        let output = CodexSchemaProcessOutputDeltaNotification(
            capReached: false,
            deltaBase64: "aGVsbG8=",
            processHandle: "process",
            stream: .stdout
        )
        let exited = CodexSchemaProcessExitedNotification(
            exitCode: 7,
            processHandle: "process",
            stderr: "",
            stderrCapReached: false,
            stdout: "",
            stdoutCapReached: false
        )
        XCTAssertEqual(
            processHub.publish(connectionEpoch: 2, event: .output(output)),
            1
        )
        XCTAssertEqual(
            processHub.publish(connectionEpoch: 2, event: .exited(exited)),
            1
        )
        var processIterator = processObservation.events.makeAsyncIterator()
        XCTAssertEqual(try await processIterator.next(), .output(output))
        XCTAssertEqual(try await processIterator.next(), .exited(exited))
        XCTAssertNil(try await processIterator.next())

        var fuzzyHub = CodexFuzzyFileSearchObserverHub()
        let fuzzyObservation = fuzzyHub.observe(connectionEpoch: 8, sessionID: "search")
        let update = CodexSchemaFuzzyFileSearchSessionUpdatedNotification(
            files: [],
            query: "readme",
            sessionID: "search"
        )
        let completion = CodexSchemaFuzzyFileSearchSessionCompletedNotification(sessionID: "search")
        XCTAssertEqual(
            fuzzyHub.publish(connectionEpoch: 8, event: .updated(update)),
            1
        )
        XCTAssertEqual(
            fuzzyHub.publish(connectionEpoch: 8, event: .completed(completion)),
            1
        )
        var fuzzyIterator = fuzzyObservation.events.makeAsyncIterator()
        XCTAssertEqual(try await fuzzyIterator.next(), .updated(update))
        XCTAssertEqual(try await fuzzyIterator.next(), .completed(completion))
        XCTAssertNil(try await fuzzyIterator.next())

        var epochHub = CodexFSChangeObserverHub()
        let oldEpoch = epochHub.observe(connectionEpoch: 1, watchID: "same")
        let newEpoch = epochHub.observe(connectionEpoch: 2, watchID: "same")
        XCTAssertEqual(epochHub.disconnect(connectionEpoch: 1), 1)
        var oldIterator = oldEpoch.changes.makeAsyncIterator()
        do {
            _ = try await oldIterator.next()
            XCTFail("Old epoch observer should fail on disconnect")
        } catch let error as CodexFSChangeObserverError {
            XCTAssertEqual(error, .disconnected(connectionEpoch: 1))
        }
        XCTAssertEqual(epochHub.publish(connectionEpoch: 2, notification: fileChange), 1)
        var newIterator = newEpoch.changes.makeAsyncIterator()
        XCTAssertEqual(try await newIterator.next(), fileChange)
        XCTAssertTrue(epochHub.cancel(newEpoch.id))
    }

    func testGlobalAndImportOperationHubsSupportCancellationAndEpochTeardown() async throws {
        var appHub = CodexAppListObserverHub()
        let appObservation = appHub.observe(connectionEpoch: 5)
        let app = CodexSchemaAppListUpdatedNotification(data: [])
        XCTAssertEqual(appHub.publish(connectionEpoch: 5, event: app), 1)
        var appIterator = appObservation.events.makeAsyncIterator()
        XCTAssertEqual(try await appIterator.next(), app)
        XCTAssertTrue(appHub.cancel(appObservation.id))
        XCTAssertNil(try await appIterator.next())

        var importHub = CodexExternalAgentConfigImportObserverHub()
        let importObservation = importHub.observe(connectionEpoch: 6, importID: "import")
        let result = CodexSchemaExternalAgentConfigImportTypeResult(
            failures: [],
            itemType: .mCPSERVERCONFIG,
            successes: []
        )
        let progress = CodexSchemaExternalAgentConfigImportProgressNotification(
            importID: "import",
            itemTypeResults: [result]
        )
        let completed = CodexSchemaExternalAgentConfigImportCompletedNotification(
            importID: "import",
            itemTypeResults: [result]
        )
        XCTAssertEqual(
            importHub.publish(connectionEpoch: 6, event: .progress(progress)),
            1
        )
        XCTAssertEqual(
            importHub.publish(connectionEpoch: 6, event: .completed(completed)),
            1
        )
        var importIterator = importObservation.events.makeAsyncIterator()
        XCTAssertEqual(try await importIterator.next(), .progress(progress))
        XCTAssertEqual(try await importIterator.next(), .completed(completed))
        XCTAssertNil(try await importIterator.next())

        var oauthHub = CodexMCPServerOAuthLoginObserverHub()
        let oauthObservation = oauthHub.observe(
            connectionEpoch: 7,
            name: "calendar",
            threadID: nil
        )
        let oauth = CodexSchemaMCPServerOAuthLoginCompletedNotification(
            name: "calendar",
            success: true
        )
        XCTAssertEqual(oauthHub.publish(connectionEpoch: 7, notification: oauth), 1)
        var oauthIterator = oauthObservation.completions.makeAsyncIterator()
        XCTAssertEqual(try await oauthIterator.next(), oauth)
        XCTAssertNil(try await oauthIterator.next())

        var sandboxHub = CodexWindowsSandboxSetupObserverHub()
        let sandboxObservation = sandboxHub.observe(connectionEpoch: 11)
        XCTAssertEqual(
            sandboxHub.disconnect(connectionEpoch: 11),
            1
        )
        var sandboxIterator = sandboxObservation.events.makeAsyncIterator()
        do {
            _ = try await sandboxIterator.next()
            XCTFail("Sandbox observer should fail on epoch teardown")
        } catch let error as CodexGlobalOperationObserverError {
            XCTAssertEqual(error, .disconnected(connectionEpoch: 11))
        }
    }
}

private extension SessionOperationPrimitivesTests {
    static func commandDelta(
        processID: String,
        text: String
    ) -> CodexSchemaCommandExecOutputDeltaNotification {
        .init(
            capReached: false,
            deltaBase64: Data(text.utf8).base64EncodedString(),
            processID: processID,
            stream: .stdout
        )
    }
}
