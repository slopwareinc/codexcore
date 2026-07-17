import XCTest
@testable import CodexCore

final class OperationRegistryTests: XCTestCase {
    private struct OperationFixture {
        let method: CodexAppServerNotificationMethod
        let params: [String: CodexJSONValue]
        let correlation: CodexOperationCorrelation
        let isTerminal: Bool
    }

    func testEveryAdapterOperationNotificationDecodesToTypedEvent() throws {
        let adapter = ProtocolStateAdapter()
        let cursor = CodexWireCursor(connectionEpoch: 9, ordinal: 41)

        for fixture in try operationFixtures() {
            let adaptation = try adapter.adaptNotification(
                method: fixture.method.rawValue,
                params: fixture.params
            )
            XCTAssertEqual(
                adaptation.disposition,
                .operation,
                "Adapter classification changed for \(fixture.method.rawValue)"
            )

            var registry = CodexOperationRegistry()
            let result = try registry.ingest(
                method: fixture.method,
                params: fixture.params,
                cursor: cursor
            )

            XCTAssertEqual(result.event.method, fixture.method)
            XCTAssertEqual(result.event.cursor, cursor)
            XCTAssertEqual(
                result.event.key,
                CodexOperationKey(
                    connectionEpoch: cursor.connectionEpoch,
                    correlation: fixture.correlation
                )
            )
            XCTAssertEqual(result.event.isTerminal, fixture.isTerminal)
            XCTAssertTrue(result.wasUnmatched)
        }
    }

    func testLosslessStreamBuffersOrderedOutputUntilTypedTerminal() async throws {
        var registry = CodexOperationRegistry()
        let key = CodexOperationKey(
            connectionEpoch: 3,
            correlation: .process(handle: "process-1")
        )
        let channel = registry.register(key: key)

        for ordinal in 0..<100 {
            let value = CodexSchemaProcessOutputDeltaNotification(
                capReached: false,
                deltaBase64: "chunk-\(ordinal)",
                processHandle: "process-1",
                stream: .stdout
            )
            let result = try registry.ingest(
                method: .processOutputDelta,
                params: try encodedParams(value),
                cursor: .init(connectionEpoch: 3, ordinal: UInt64(ordinal))
            )
            XCTAssertEqual(result.deliveredChannelCount, 1)
            XCTAssertEqual(result.completedChannelCount, 0)
        }

        let exited = CodexSchemaProcessExitedNotification(
            exitCode: 0,
            processHandle: "process-1",
            stderr: "",
            stderrCapReached: false,
            stdout: "complete",
            stdoutCapReached: false
        )
        let terminalResult = try registry.ingest(
            method: .processExited,
            params: try encodedParams(exited),
            cursor: .init(connectionEpoch: 3, ordinal: 100)
        )
        XCTAssertEqual(terminalResult.deliveredChannelCount, 1)
        XCTAssertEqual(terminalResult.completedChannelCount, 1)
        XCTAssertEqual(registry.activeChannelCount, 0)

        var iterator = channel.events.makeAsyncIterator()
        for ordinal in 0..<100 {
            let next = try await iterator.next()
            let event = try XCTUnwrap(next)
            XCTAssertEqual(event.cursor.ordinal, UInt64(ordinal))
            guard case .processOutputDelta(let value) = event.payload else {
                return XCTFail("Expected process output at ordinal \(ordinal)")
            }
            XCTAssertEqual(value.deltaBase64, "chunk-\(ordinal)")
        }
        let next = try await iterator.next()
        let terminal = try XCTUnwrap(next)
        XCTAssertEqual(terminal.cursor.ordinal, 100)
        XCTAssertTrue(terminal.isTerminal)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testFirstEventWaiterIsExactKeyAndEpochScoped() async throws {
        var registry = CodexOperationRegistry()
        let key = CodexOperationKey(
            connectionEpoch: 1,
            correlation: .fuzzyFileSearch(sessionID: "search")
        )
        let waiter = registry.registerWaiter(key: key)

        let update = CodexSchemaFuzzyFileSearchSessionUpdatedNotification(
            files: [],
            query: "swift",
            sessionID: "search"
        )
        let stale = try registry.ingest(
            method: .fuzzyFileSearchSessionUpdated,
            params: try encodedParams(update),
            cursor: .init(connectionEpoch: 2, ordinal: 1)
        )
        XCTAssertTrue(stale.wasUnmatched)
        XCTAssertEqual(registry.activeChannelCount, 1)

        let matched = try registry.ingest(
            method: .fuzzyFileSearchSessionUpdated,
            params: try encodedParams(update),
            cursor: .init(connectionEpoch: 1, ordinal: 2)
        )
        XCTAssertEqual(matched.deliveredChannelCount, 1)
        XCTAssertEqual(matched.completedChannelCount, 1)

        var iterator = waiter.events.makeAsyncIterator()
        let next = try await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.cursor, .init(connectionEpoch: 1, ordinal: 2))
        let end = try await iterator.next()
        XCTAssertNil(end)

        let diagnostics = registry.diagnostics()
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertEqual(diagnostics.entries[0].kind, .unmatchedOperation)
        XCTAssertEqual(
            diagnostics.entries[0].cursor,
            .init(connectionEpoch: 2, ordinal: 1)
        )
    }

    func testSameIdentifierInDifferentOperationFamilyDoesNotCrossDeliver() async throws {
        var registry = CodexOperationRegistry()
        let processKey = CodexOperationKey(
            connectionEpoch: 6,
            correlation: .process(handle: "shared")
        )
        let waiter = registry.registerWaiter(key: processKey)

        let command = CodexSchemaCommandExecOutputDeltaNotification(
            capReached: false,
            deltaBase64: "command",
            processID: "shared",
            stream: .stdout
        )
        let wrongFamily = try registry.ingest(
            method: .commandExecOutputDelta,
            params: try encodedParams(command),
            cursor: .init(connectionEpoch: 6, ordinal: 1)
        )
        XCTAssertTrue(wrongFamily.wasUnmatched)
        XCTAssertEqual(registry.activeChannelCount, 1)

        let process = CodexSchemaProcessOutputDeltaNotification(
            capReached: false,
            deltaBase64: "process",
            processHandle: "shared",
            stream: .stdout
        )
        let rightFamily = try registry.ingest(
            method: .processOutputDelta,
            params: try encodedParams(process),
            cursor: .init(connectionEpoch: 6, ordinal: 2)
        )
        XCTAssertFalse(rightFamily.wasUnmatched)

        var iterator = waiter.events.makeAsyncIterator()
        let next = try await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.method, .processOutputDelta)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testStateBearingTurnHookCanAlsoPublishToOperationChannel() async throws {
        var registry = CodexOperationRegistry()
        let notification = CodexSchemaHookStartedNotification(
            run: hookRun(id: "run", status: .running),
            threadID: "thread",
            turnID: "turn"
        )
        let params = try encodedParams(notification)
        let adaptation = try ProtocolStateAdapter().adaptNotification(
            method: CodexAppServerNotificationMethod.hookStarted.rawValue,
            params: params
        )
        XCTAssertEqual(adaptation.disposition, .state)

        let key = CodexOperationKey(
            connectionEpoch: 7,
            correlation: .hook(threadID: "thread", runID: "run")
        )
        let waiter = registry.registerWaiter(key: key)
        let result = try registry.ingest(
            method: .hookStarted,
            params: params,
            cursor: .init(connectionEpoch: 7, ordinal: 1)
        )
        XCTAssertEqual(result.deliveredChannelCount, 1)

        var iterator = waiter.events.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.method, .hookStarted)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testExplicitFinishDrainsBufferedEventsThenEndsStream() async throws {
        var registry = CodexOperationRegistry()
        let key = CodexOperationKey(
            connectionEpoch: 4,
            correlation: .commandExec(processID: "command")
        )
        let channel = registry.register(key: key)
        let delta = CodexSchemaCommandExecOutputDeltaNotification(
            capReached: false,
            deltaBase64: "b3V0cHV0",
            processID: "command",
            stream: .stdout
        )
        try registry.ingest(
            method: .commandExecOutputDelta,
            params: try encodedParams(delta),
            cursor: .init(connectionEpoch: 4, ordinal: 7)
        )

        XCTAssertEqual(registry.finish(key: key), 1)
        XCTAssertEqual(registry.activeChannelCount, 0)

        var iterator = channel.events.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.cursor.ordinal, 7)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testCancellationAndDisconnectFinishOnlyTargetedChannels() async throws {
        var registry = CodexOperationRegistry()
        let firstKey = CodexOperationKey(
            connectionEpoch: 11,
            correlation: .applications
        )
        let secondKey = CodexOperationKey(
            connectionEpoch: 12,
            correlation: .applications
        )
        let cancelled = registry.register(key: firstKey, lifetime: .explicit)
        let disconnected = registry.register(key: firstKey, lifetime: .explicit)
        let survivor = registry.registerWaiter(key: secondKey)

        XCTAssertTrue(registry.cancel(cancelled.token))
        XCTAssertEqual(registry.disconnect(connectionEpoch: 11), 1)
        XCTAssertEqual(registry.activeChannelCount, 1)

        var cancelledIterator = cancelled.events.makeAsyncIterator()
        do {
            _ = try await cancelledIterator.next()
            XCTFail("Cancelled channel must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        var disconnectedIterator = disconnected.events.makeAsyncIterator()
        do {
            _ = try await disconnectedIterator.next()
            XCTFail("Disconnected channel must throw")
        } catch {
            XCTAssertEqual(
                error as? CodexOperationChannelError,
                .disconnected(connectionEpoch: 11)
            )
        }

        let update = CodexSchemaAppListUpdatedNotification(data: [])
        let result = try registry.ingest(
            method: .appListUpdated,
            params: try encodedParams(update),
            cursor: .init(connectionEpoch: 12, ordinal: 1)
        )
        XCTAssertFalse(result.wasUnmatched)
        var survivorIterator = survivor.events.makeAsyncIterator()
        let event = try await survivorIterator.next()
        XCTAssertEqual(event?.cursor.connectionEpoch, 12)
        let end = try await survivorIterator.next()
        XCTAssertNil(end)
    }

    func testStalledConsumerFailsExplicitlyAtConfiguredBufferBound() async throws {
        var registry = CodexOperationRegistry(limits: .init(
            defaultMaximumBufferedEventsPerChannel: 2
        ))
        let key = CodexOperationKey(
            connectionEpoch: 13,
            correlation: .process(handle: "bounded")
        )
        let channel = registry.register(
            key: key,
            lifetime: .explicit
        )

        for ordinal in 0..<2 {
            let value = CodexSchemaProcessOutputDeltaNotification(
                capReached: false,
                deltaBase64: "\(ordinal)",
                processHandle: "bounded",
                stream: .stdout
            )
            let result = try registry.ingest(
                method: .processOutputDelta,
                params: try encodedParams(value),
                cursor: .init(connectionEpoch: 13, ordinal: UInt64(ordinal))
            )
            XCTAssertEqual(result.deliveredChannelCount, 1)
            XCTAssertEqual(result.overflowedChannelCount, 0)
        }

        let overflow = CodexSchemaProcessOutputDeltaNotification(
            capReached: false,
            deltaBase64: "overflow",
            processHandle: "bounded",
            stream: .stdout
        )
        let overflowResult = try registry.ingest(
            method: .processOutputDelta,
            params: try encodedParams(overflow),
            cursor: .init(connectionEpoch: 13, ordinal: 2)
        )
        XCTAssertEqual(overflowResult.matchedChannelCount, 1)
        XCTAssertEqual(overflowResult.deliveredChannelCount, 0)
        XCTAssertEqual(overflowResult.overflowedChannelCount, 1)
        XCTAssertFalse(overflowResult.wasUnmatched)
        XCTAssertEqual(registry.activeChannelCount, 0)

        var iterator = channel.events.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.cursor.ordinal, 0)
        let second = try await iterator.next()
        XCTAssertEqual(second?.cursor.ordinal, 1)
        do {
            _ = try await iterator.next()
            XCTFail("Overflowed channel must fail after draining accepted events")
        } catch {
            XCTAssertEqual(
                error as? CodexOperationChannelError,
                .bufferOverflow(
                    key: key,
                    maximumBufferedEventCount: 2
                )
            )
        }

        let diagnostics = registry.diagnostics()
        XCTAssertEqual(diagnostics.entries.map(\.kind), [.bufferOverflow])
        XCTAssertEqual(diagnostics.entries[0].cursor.ordinal, 2)
    }

    func testDiagnosticsAreCursorBearingCountAndTextBounded() {
        var registry = CodexOperationRegistry(limits: .init(
            maximumDiagnosticEntries: 3,
            maximumDiagnosticTextUTF8Bytes: 8
        ))

        for ordinal in 0..<5 {
            registry.recordDiagnostic(
                kind: ordinal.isMultiple(of: 2) ? .warning : .unknownMethod,
                method: "method-\(ordinal)-much-too-long",
                cursor: .init(connectionEpoch: 5, ordinal: UInt64(ordinal)),
                keyDescription: "correlation-\(ordinal)-much-too-long",
                detail: "detail-\(ordinal)-much-too-long"
            )
        }

        let snapshot = registry.diagnostics()
        XCTAssertEqual(snapshot.totalRecordedCount, 5)
        XCTAssertEqual(snapshot.evictedCount, 2)
        XCTAssertEqual(snapshot.entries.map(\.cursor.ordinal), [2, 3, 4])
        for entry in snapshot.entries {
            XCTAssertLessThanOrEqual(entry.method.utf8.count, 8)
            XCTAssertLessThanOrEqual(entry.keyDescription?.utf8.count ?? 0, 8)
            XCTAssertLessThanOrEqual(entry.detail?.utf8.count ?? 0, 8)
        }
    }

    func testMalformedOperationRecordsBoundedDiagnosticAndThrows() {
        var registry = CodexOperationRegistry()
        let cursor = CodexWireCursor(connectionEpoch: 8, ordinal: 99)

        XCTAssertThrowsError(try registry.ingest(
            method: .processExited,
            params: ["processHandle": .string("missing-fields")],
            cursor: cursor
        )) { error in
            guard case CodexOperationRegistryError.malformedNotification(let method, _) = error else {
                return XCTFail("Expected typed malformed notification error")
            }
            XCTAssertEqual(method, CodexAppServerNotificationMethod.processExited.rawValue)
        }

        let diagnostics = registry.diagnostics()
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertEqual(diagnostics.entries[0].kind, .malformedOperation)
        XCTAssertEqual(diagnostics.entries[0].cursor, cursor)
    }
}

private extension OperationRegistryTests {
    func encodedParams<T: Encodable>(_ value: T) throws -> [String: CodexJSONValue] {
        let encoded = try CodexJSONValue(encoding: value)
        guard let params = encoded.objectValue else {
            throw CodexJSONRPCEnvelopeError.paramsMustBeObject(encoded)
        }
        return params
    }

    private func operationFixtures() throws -> [OperationFixture] {
        let runningHook = hookRun(id: "hook", status: .running)
        let completedHook = hookRun(id: "hook", status: .completed)
        let audio = CodexSchemaThreadRealtimeAudioChunk(
            data: "audio",
            numChannels: 1,
            sampleRate: 24_000
        )

        return try [
            fixture(
                .skillsChanged,
                CodexSchemaSkillsChangedNotification(.dictionary([:])),
                .skills
            ),
            fixture(
                .hookStarted,
                CodexSchemaHookStartedNotification(
                    run: runningHook,
                    threadID: "thread"
                ),
                .hook(threadID: "thread", runID: "hook")
            ),
            fixture(
                .hookCompleted,
                CodexSchemaHookCompletedNotification(
                    run: completedHook,
                    threadID: "thread"
                ),
                .hook(threadID: "thread", runID: "hook"),
                terminal: true
            ),
            fixture(
                .commandExecOutputDelta,
                CodexSchemaCommandExecOutputDeltaNotification(
                    capReached: false,
                    deltaBase64: "command",
                    processID: "command",
                    stream: .stdout
                ),
                .commandExec(processID: "command")
            ),
            fixture(
                .processOutputDelta,
                CodexSchemaProcessOutputDeltaNotification(
                    capReached: false,
                    deltaBase64: "process",
                    processHandle: "process",
                    stream: .stderr
                ),
                .process(handle: "process")
            ),
            fixture(
                .processExited,
                CodexSchemaProcessExitedNotification(
                    exitCode: 1,
                    processHandle: "process",
                    stderr: "error",
                    stderrCapReached: false,
                    stdout: "",
                    stdoutCapReached: false
                ),
                .process(handle: "process"),
                terminal: true
            ),
            fixture(
                .mcpServerOAuthLoginCompleted,
                CodexSchemaMCPServerOAuthLoginCompletedNotification(
                    name: "server",
                    success: true,
                    threadID: "thread"
                ),
                .mcpServerOAuth(name: "server", threadID: "thread"),
                terminal: true
            ),
            fixture(
                .mcpServerStartupStatusUpdated,
                CodexSchemaMCPServerStatusUpdatedNotification(
                    name: "server",
                    status: .ready,
                    threadID: "thread"
                ),
                .mcpServerStartup(name: "server", threadID: "thread"),
                terminal: true
            ),
            fixture(
                .appListUpdated,
                CodexSchemaAppListUpdatedNotification(data: []),
                .applications
            ),
            fixture(
                .remoteControlStatusChanged,
                CodexSchemaRemoteControlStatusChangedNotification(
                    installationID: "installation",
                    serverName: "server",
                    status: .connected
                ),
                .remoteControl(installationID: "installation")
            ),
            fixture(
                .externalAgentConfigImportProgress,
                CodexSchemaExternalAgentConfigImportProgressNotification(
                    importID: "import",
                    itemTypeResults: []
                ),
                .externalAgentConfigImport(importID: "import")
            ),
            fixture(
                .externalAgentConfigImportCompleted,
                CodexSchemaExternalAgentConfigImportCompletedNotification(
                    importID: "import",
                    itemTypeResults: []
                ),
                .externalAgentConfigImport(importID: "import"),
                terminal: true
            ),
            fixture(
                .fsChanged,
                CodexSchemaFSChangedNotification(
                    changedPaths: [],
                    watchID: "watch"
                ),
                .fileSystemWatch(watchID: "watch")
            ),
            fixture(
                .fuzzyFileSearchSessionUpdated,
                CodexSchemaFuzzyFileSearchSessionUpdatedNotification(
                    files: [],
                    query: "query",
                    sessionID: "search"
                ),
                .fuzzyFileSearch(sessionID: "search")
            ),
            fixture(
                .fuzzyFileSearchSessionCompleted,
                CodexSchemaFuzzyFileSearchSessionCompletedNotification(
                    sessionID: "search"
                ),
                .fuzzyFileSearch(sessionID: "search"),
                terminal: true
            ),
            fixture(
                .threadRealtimeStarted,
                CodexSchemaThreadRealtimeStartedNotification(
                    realtimeSessionID: "realtime",
                    threadID: "thread",
                    version: .v2
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeItemAdded,
                CodexSchemaThreadRealtimeItemAddedNotification(
                    item: .dictionary(["id": .string("item")]),
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeTranscriptDelta,
                CodexSchemaThreadRealtimeTranscriptDeltaNotification(
                    delta: "delta",
                    role: "assistant",
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeTranscriptDone,
                CodexSchemaThreadRealtimeTranscriptDoneNotification(
                    role: "assistant",
                    text: "done",
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeOutputAudioDelta,
                CodexSchemaThreadRealtimeOutputAudioDeltaNotification(
                    audio: audio,
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeSdp,
                CodexSchemaThreadRealtimeSdpNotification(
                    sdp: "sdp",
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeError,
                CodexSchemaThreadRealtimeErrorNotification(
                    message: "recoverable",
                    threadID: "thread"
                ),
                .realtime(threadID: "thread")
            ),
            fixture(
                .threadRealtimeClosed,
                CodexSchemaThreadRealtimeClosedNotification(
                    reason: "done",
                    threadID: "thread"
                ),
                .realtime(threadID: "thread"),
                terminal: true
            ),
            fixture(
                .windowsSandboxSetupCompleted,
                CodexSchemaWindowsSandboxSetupCompletedNotification(
                    mode: .elevated,
                    success: true
                ),
                .windowsSandbox(mode: "elevated"),
                terminal: true
            ),
            fixture(
                .accountLoginCompleted,
                CodexSchemaAccountLoginCompletedNotification(
                    loginID: "login",
                    success: true
                ),
                .accountLogin(loginID: "login"),
                terminal: true
            ),
        ]
    }

    private func fixture<T: Encodable>(
        _ method: CodexAppServerNotificationMethod,
        _ value: T,
        _ correlation: CodexOperationCorrelation,
        terminal: Bool = false
    ) throws -> OperationFixture {
        OperationFixture(
            method: method,
            params: try encodedParams(value),
            correlation: correlation,
            isTerminal: terminal
        )
    }

    func hookRun(
        id: String,
        status: CodexSchemaHookRunStatus
    ) -> CodexSchemaHookRunSummary {
        CodexSchemaHookRunSummary(
            displayOrder: 0,
            entries: [],
            eventName: .sessionStart,
            executionMode: .sync,
            handlerType: .command,
            id: id,
            scope: .thread,
            sourcePath: CodexSchemaAbsolutePathBuf(.string("/tmp/hook")),
            startedAt: 1,
            status: status
        )
    }
}
