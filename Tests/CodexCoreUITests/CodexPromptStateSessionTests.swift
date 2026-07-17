import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPromptStateSessionTests: XCTestCase {
    func testTypedInboxProjectsEveryInteractiveKindInRegistrationOrder() throws {
        let integerKey = requestKey(epoch: 3, id: .integer(7))
        let stringKey = requestKey(epoch: 3, id: .string("7"))
        let nextEpochKey = requestKey(epoch: 4, id: .string("7"))
        let fileKey = requestKey(id: .string("file"))
        let permissionKey = requestKey(id: .string("permissions"))
        let mcpKey = requestKey(id: .string("mcp"))
        let unsupportedKey = requestKey(id: .string("clock"))
        let presentedAt = Date(timeIntervalSince1970: 123)
        let snapshot = inbox(
            revision: 9,
            entries: [
                commandEntry(key: integerKey, sequence: 0),
                userInputEntry(key: stringKey, sequence: 1),
                commandEntry(key: nextEpochKey, sequence: 2, legacy: true),
                fileEntry(key: fileKey, sequence: 3),
                permissionsEntry(key: permissionKey, sequence: 4),
                mcpEntry(key: mcpKey, sequence: 5),
                unsupportedEntry(key: unsupportedKey, sequence: 6, kind: .currentTime),
            ]
        )

        var state = CodexPromptStateSession()
        let activities = state.sync(snapshot, presentedAt: presentedAt)

        XCTAssertEqual(
            state.approvalPrompts.map(\.id),
            [integerKey, nextEpochKey, fileKey, permissionKey]
        )
        XCTAssertEqual(state.interactivePrompts.map(\.id), [stringKey, mcpKey])
        XCTAssertEqual(state.approvalPrompts.map(\.createdAt), Array(repeating: presentedAt, count: 4))
        XCTAssertEqual(activities.count, 6)
        XCTAssertEqual(integerKey.presentationID, "request:3:i:7")
        XCTAssertEqual(stringKey.presentationID, "request:3:s:7")
        XCTAssertEqual(nextEpochKey.presentationID, "request:4:s:7")
        XCTAssertEqual(state.approvalPrompt(for: nextEpochKey)?.kind, .execCommand)
        XCTAssertEqual(state.approvalPrompt(for: fileKey)?.primaryValue, "/tmp/project")
        XCTAssertNil(state.approvalPrompt(for: unsupportedKey))

        XCTAssertEqual(state.sync(snapshot, presentedAt: .distantFuture), [])
        XCTAssertEqual(state.approvalPrompts.first?.createdAt, presentedAt)

        let empty = inbox(revision: 10, entries: [])
        XCTAssertEqual(state.sync(empty), [])
        XCTAssertTrue(state.approvalPrompts.isEmpty)
        XCTAssertTrue(state.interactivePrompts.isEmpty)

        // A stale seed cannot resurrect already-terminal prompts.
        XCTAssertEqual(state.sync(snapshot), [])
        XCTAssertTrue(state.approvalPrompts.isEmpty)
    }

    func testPromptProjectionRedactsMCPMetadataURLAndSchemaDefaults() throws {
        let key = requestKey(id: .string("mcp-secret"))
        let entry = mcpEntry(
            key: key,
            sequence: 0,
            mode: .openAIForm(requestedSchema: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "token": .dictionary([
                        "type": .string("string"),
                        "title": .string("Token"),
                        "default": .string("schema-secret"),
                        "examples": .array([.string("example-secret")]),
                    ]),
                ]),
            ]))
        )
        let prompt = try XCTUnwrap(CodexInteractivePrompt(inboxEntry: entry))
        let description = String(reflecting: prompt)

        XCTAssertFalse(description.contains("schema-secret"))
        XCTAssertFalse(description.contains("example-secret"))
        XCTAssertTrue(prompt.canAcceptElicitation)

        let URLPrompt = try XCTUnwrap(CodexInteractivePrompt(inboxEntry: mcpEntry(
            key: requestKey(id: .string("mcp-url")),
            sequence: 1,
            mode: .url(
                elicitationID: "secret-elicit-id",
                url: "https://example.com/auth?bearer=url-secret"
            )
        )))
        let URLDescription = String(reflecting: URLPrompt)
        XCTAssertFalse(URLDescription.contains("url-secret"))
        XCTAssertFalse(URLDescription.contains("secret-elicit-id"))
        XCTAssertFalse(URLPrompt.canAcceptElicitation)
    }

    @MainActor
    func testRuntimeEncodesModernLegacyPermissionAndInteractiveResponses() async throws {
        let commandKey = requestKey(id: .string("command"))
        let fileKey = requestKey(id: .string("file"))
        let permissionKey = requestKey(id: .string("permission"))
        let legacyCommandKey = requestKey(id: .string("legacy-command"))
        let legacyPatchKey = requestKey(id: .string("legacy-patch"))
        let userKey = requestKey(id: .string("user"))
        let mcpKey = requestKey(id: .string("mcp"))
        let adapter = PromptAdapterFake(snapshot: inbox(revision: 1, entries: [
            commandEntry(key: commandKey, sequence: 0),
            fileEntry(key: fileKey, sequence: 1),
            permissionsEntry(key: permissionKey, sequence: 2),
            commandEntry(key: legacyCommandKey, sequence: 3, legacy: true),
            fileEntry(key: legacyPatchKey, sequence: 4, legacy: true),
            userInputEntry(key: userKey, sequence: 5, isSecret: true),
            mcpEntry(key: mcpKey, sequence: 6),
        ]))
        let runtime = CodexPromptRuntimeSession()
        runtime.connect(adapter: adapter)
        try await waitUntil {
            runtime.approvalPrompts.count == 5 && runtime.interactivePrompts.count == 2
        }

        _ = try await runtime.resolveApprovalPrompt(
            id: commandKey,
            decision: .acceptWithExecpolicyAmendment(["git", "status"])
        )
        _ = try await runtime.resolveApprovalPrompt(id: fileKey, decision: .decline)
        _ = try await runtime.resolveApprovalPrompt(
            id: permissionKey,
            decision: .acceptForSession
        )
        _ = try await runtime.resolveApprovalPrompt(
            id: legacyCommandKey,
            decision: .applyNetworkPolicyAmendment(.init(action: .allow, host: "example.com"))
        )
        _ = try await runtime.resolveApprovalPrompt(id: legacyPatchKey, approved: true)
        _ = try await runtime.submitInteractivePrompt(
            id: userKey,
            answers: ["secret": "one-shot-secret"]
        )
        _ = try await runtime.submitInteractivePrompt(
            id: mcpKey,
            answers: ["confirm": "true"]
        )

        let resolutions = await adapter.recordedResolutions()
        XCTAssertEqual(resolutions, [
            .init(key: commandKey, result: .dictionary([
                "decision": .dictionary([
                    "acceptWithExecpolicyAmendment": .dictionary([
                        "execpolicy_amendment": .array([.string("git"), .string("status")])
                    ])
                ])
            ])),
            .init(key: fileKey, result: .dictionary(["decision": .string("decline")])),
            .init(key: permissionKey, result: .dictionary([
                "permissions": requestedPermissions,
                "scope": .string("session"),
            ])),
            .init(key: legacyCommandKey, result: .dictionary([
                "decision": .dictionary([
                    "network_policy_amendment": .dictionary([
                        "network_policy_amendment": .dictionary([
                            "action": .string("allow"),
                            "host": .string("example.com"),
                        ])
                    ])
                ])
            ])),
            .init(key: legacyPatchKey, result: .dictionary([
                "decision": .string("approved")
            ])),
            .init(key: userKey, result: .dictionary([
                "answers": .dictionary([
                    "secret": .dictionary([
                        "answers": .array([.string("one-shot-secret")])
                    ])
                ])
            ])),
            .init(key: mcpKey, result: .dictionary([
                "action": .string("accept"),
                "content": .dictionary(["confirm": .bool(true)]),
            ])),
        ])
        XCTAssertFalse(String(reflecting: runtime.interactivePrompts).contains("one-shot-secret"))
        runtime.disconnect()
    }

    @MainActor
    func testPermissionDeclineAndMCPDeclineUseProtocolShapes() async throws {
        let permissionKey = requestKey(id: .string("permission"))
        let mcpKey = requestKey(id: .string("mcp"))
        let adapter = PromptAdapterFake(snapshot: inbox(revision: 1, entries: [
            permissionsEntry(key: permissionKey, sequence: 0),
            mcpEntry(key: mcpKey, sequence: 1),
        ]))
        let runtime = CodexPromptRuntimeSession()
        runtime.connect(adapter: adapter)
        try await waitUntil { runtime.approvalPrompts.count == 1 }

        _ = try await runtime.resolveApprovalPrompt(id: permissionKey, approved: false)
        _ = try await runtime.declineInteractivePrompt(id: mcpKey)

        let resolutions = await adapter.recordedResolutions()
        XCTAssertEqual(resolutions, [
            .init(key: permissionKey, result: .dictionary([
                "permissions": .dictionary([:]),
                "scope": .string("turn"),
            ])),
            .init(key: mcpKey, result: .dictionary([
                "action": .string("decline")
            ])),
        ])
        runtime.disconnect()
    }

    @MainActor
    func testRuntimeAutomaticallyTerminatesEveryNoninteractiveInboxKind() async throws {
        let clock = requestKey(id: .string("clock"))
        let dynamic = requestKey(id: .string("dynamic"))
        let token = requestKey(id: .string("token"))
        let attestation = requestKey(id: .string("attestation"))
        let unknown = requestKey(id: .string("unknown"))
        let adapter = PromptAdapterFake(snapshot: inbox(revision: 1, entries: [
            unsupportedEntry(key: clock, sequence: 0, kind: .currentTime),
            unsupportedEntry(key: dynamic, sequence: 1, kind: .dynamicToolCall),
            unsupportedEntry(key: token, sequence: 2, kind: .tokenRefresh),
            unsupportedEntry(key: attestation, sequence: 3, kind: .attestation),
            unsupportedEntry(key: unknown, sequence: 4, kind: .unknown("future/request")),
        ]))
        let runtime = CodexPromptRuntimeSession(now: {
            Date(timeIntervalSince1970: 1_700_000_000.9)
        })
        runtime.connect(adapter: adapter)
        try await waitUntil { await adapter.terminalCount() == 5 }

        let resolutions = await adapter.recordedResolutions()
        let failures = await adapter.recordedFailures()
        XCTAssertEqual(resolutions, [
            .init(key: clock, result: .dictionary(["currentTimeAt": .int(1_700_000_000)])),
            .init(key: dynamic, result: .dictionary([
                "success": .bool(false),
                "contentItems": .array([]),
            ])),
        ])
        XCTAssertEqual(failures.map(\.key), [token, attestation, unknown])
        XCTAssertEqual(failures.map(\.error.code), [-32_004, -32_004, -32_601])
        XCTAssertTrue(runtime.approvalPrompts.isEmpty)
        XCTAssertTrue(runtime.interactivePrompts.isEmpty)
        runtime.disconnect()
    }

    @MainActor
    func testConcurrentResolutionIsFirstTerminalWinsAndFailureDoesNotRemoveLocally() async throws {
        let key = requestKey(id: .string("race"))
        let adapter = PromptAdapterFake(snapshot: inbox(
            revision: 1,
            entries: [commandEntry(key: key, sequence: 0)]
        ))
        let runtime = CodexPromptRuntimeSession()
        runtime.connect(adapter: adapter)
        try await waitUntil { runtime.approvalPrompts.count == 1 }

        let first = Task { @MainActor in
            try await runtime.resolveApprovalPrompt(id: key, approved: true)
        }
        let second = Task { @MainActor in
            try await runtime.resolveApprovalPrompt(id: key, approved: false)
        }
        let firstResult = await first.result
        let secondResult = await second.result
        let results = [firstResult, secondResult]
        XCTAssertEqual(results.filter(\.isSuccess).count, 1)
        XCTAssertEqual(results.filter(\.isAlreadyTerminal).count, 1)
        let recordedResolutions = await adapter.recordedResolutions()
        XCTAssertEqual(recordedResolutions.count, 1)
        XCTAssertEqual(runtime.approvalPrompts.map(\.id), [key])

        // The authoritative higher-revision empty snapshot removes the card.
        await adapter.publish(inbox(revision: 2, entries: []))
        try await waitUntil { runtime.approvalPrompts.isEmpty }
        runtime.disconnect()
    }

    @MainActor
    func testFailForwardsExactKeyAndDisconnectCancelsObservation() async throws {
        let key = requestKey(epoch: 8, id: .integer(42))
        let adapter = PromptAdapterFake(snapshot: inbox(
            revision: 1,
            entries: [userInputEntry(key: key, sequence: 0)]
        ))
        let runtime = CodexPromptRuntimeSession()
        runtime.connect(adapter: adapter)
        try await waitUntil { runtime.interactivePrompts.count == 1 }

        let error = CodexServerRequestResponseError(
            code: -32_000,
            message: "Cancelled in UI"
        )
        try await runtime.failPrompt(id: key, error: error)
        let failures = await adapter.recordedFailures()
        XCTAssertEqual(failures, [.init(key: key, error: error)])

        runtime.disconnect()
        try await waitUntil { await adapter.cancelledObservationCount() == 1 }
    }
}

private let requestedPermissions: CodexJSONValue = .dictionary([
    "network": .dictionary(["enabled": .bool(true)])
])

private func requestKey(
    epoch: UInt64 = 1,
    id: CodexServerRequestID
) -> CodexServerRequestKey {
    .init(connectionEpoch: epoch, requestID: id)
}

private func inbox(
    revision: UInt64,
    entries: [CodexServerRequestInboxEntry]
) -> CodexServerRequestInboxSnapshot {
    .init(revision: StateRevision(revision), requests: entries)
}

private func pendingSnapshot(
    key: CodexServerRequestKey,
    kind: CodexServerRequestKind,
    sequence: UInt64,
    scope: CodexServerRequestScope = .init(
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1"
    )
) -> CodexPendingInteractionSnapshot {
    .init(
        key: key,
        method: kind.method,
        kind: kind,
        scope: scope,
        approvalCorrelation: nil,
        arrivalOrdinal: sequence
    )
}

private func commandEntry(
    key: CodexServerRequestKey,
    sequence: UInt64,
    legacy: Bool = false
) -> CodexServerRequestInboxEntry {
    let kind: CodexServerRequestKind = legacy ? .legacyExecCommandApproval : .commandApproval
    return .init(
        snapshot: pendingSnapshot(key: key, kind: kind, sequence: sequence),
        body: .commandApproval(.init(
            callID: legacy ? "legacy-call" : nil,
            command: "git status",
            commandArguments: legacy ? ["git", "status"] : nil,
            cwd: "/tmp/project",
            reason: "Inspect workspace",
            startedAtMilliseconds: legacy ? nil : 100,
            environmentID: legacy ? nil : "local",
            availableDecisions: legacy ? nil : [
                .accept,
                .acceptForSession,
                .acceptWithExecpolicyAmendment(["git", "status"]),
                .decline,
            ],
            commandActions: [],
            additionalPermissions: nil,
            networkApprovalContext: nil,
            proposedExecpolicyAmendment: nil,
            proposedNetworkPolicyAmendments: []
        ))
    )
}

private func fileEntry(
    key: CodexServerRequestKey,
    sequence: UInt64,
    legacy: Bool = false
) -> CodexServerRequestInboxEntry {
    let kind: CodexServerRequestKind = legacy ? .legacyApplyPatchApproval : .fileChangeApproval
    return .init(
        snapshot: pendingSnapshot(key: key, kind: kind, sequence: sequence),
        body: .fileChangeApproval(.init(
            callID: legacy ? "patch-call" : nil,
            fileChanges: legacy ? ["Sources/App.swift": .add(content: "new file")] : nil,
            grantRoot: "/tmp/project",
            reason: "Edit source",
            startedAtMilliseconds: legacy ? nil : 100
        ))
    )
}

private func permissionsEntry(
    key: CodexServerRequestKey,
    sequence: UInt64
) -> CodexServerRequestInboxEntry {
    .init(
        snapshot: pendingSnapshot(key: key, kind: .permissionsApproval, sequence: sequence),
        body: .permissionsApproval(.init(
            cwd: "/tmp/project",
            permissions: requestedPermissions,
            reason: "Use network",
            startedAtMilliseconds: 100,
            environmentID: "local"
        ))
    )
}

private func userInputEntry(
    key: CodexServerRequestKey,
    sequence: UInt64,
    isSecret: Bool = false
) -> CodexServerRequestInboxEntry {
    .init(
        snapshot: pendingSnapshot(key: key, kind: .userInput, sequence: sequence),
        body: .userInput(.init(
            questions: [.init(
                id: isSecret ? "secret" : "confirm",
                question: isSecret ? "Enter token" : "Continue?",
                header: isSecret ? "Token" : "Confirm",
                isSecret: isSecret
            )],
            autoResolutionMilliseconds: nil
        ))
    )
}

private func mcpEntry(
    key: CodexServerRequestKey,
    sequence: UInt64,
    mode: CodexMCPElicitationMode = .openAIForm(requestedSchema: .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "confirm": .dictionary([
                "type": .string("boolean"),
                "title": .string("Confirm"),
            ]),
        ]),
        "required": .array([.string("confirm")]),
    ]))
) -> CodexServerRequestInboxEntry {
    .init(
        snapshot: pendingSnapshot(key: key, kind: .mcpElicitation, sequence: sequence),
        body: .mcpElicitation(.init(
            serverName: "calendar",
            message: "Allow calendar access?",
            mode: mode
        ))
    )
}

private func unsupportedEntry(
    key: CodexServerRequestKey,
    sequence: UInt64,
    kind: CodexServerRequestKind
) -> CodexServerRequestInboxEntry {
    .init(
        snapshot: pendingSnapshot(
            key: key,
            kind: kind,
            sequence: sequence,
            scope: .init()
        ),
        body: .unsupported(kind)
    )
}

private struct RecordedResolution: Sendable, Equatable {
    let key: CodexServerRequestKey
    let result: CodexJSONValue
}

private struct RecordedFailure: Sendable, Equatable {
    let key: CodexServerRequestKey
    let error: CodexServerRequestResponseError
}

private actor PromptAdapterFake: CodexPromptSessionAdapter {
    private var snapshot: CodexServerRequestInboxSnapshot
    private var nextObservationID: UInt64 = 1
    private var continuations: [
        StateObservationID: AsyncStream<StateRevisionSignal>.Continuation
    ] = [:]
    private var cancelledObservationIDs: Set<StateObservationID> = []
    private var resolutions: [RecordedResolution] = []
    private var failures: [RecordedFailure] = []
    private var terminalKeys: Set<CodexServerRequestKey> = []

    init(snapshot: CodexServerRequestInboxSnapshot) {
        self.snapshot = snapshot
    }

    func serverRequestInboxSnapshot(
        entities: StateEntityScope
    ) -> CodexServerRequestInboxSnapshot {
        snapshot
    }

    func observeServerRequests(
        entities: StateEntityScope
    ) -> StateObservation<CodexServerRequestInboxSnapshot> {
        let id = StateObservationID(rawValue: nextObservationID)
        nextObservationID += 1
        var captured: AsyncStream<StateRevisionSignal>.Continuation?
        let stream = AsyncStream<StateRevisionSignal>(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuations[id] = captured
        return .init(
            id: id,
            scope: .init(entities: entities, fields: .requests),
            seed: snapshot,
            revision: snapshot.revision,
            signals: stream
        )
    }

    func catchUp(
        observationID: StateObservationID,
        after revision: StateRevision
    ) -> StateCatchUp {
        .changes([], through: snapshot.revision)
    }

    func cancelObservation(_ observationID: StateObservationID) {
        cancelledObservationIDs.insert(observationID)
        continuations.removeValue(forKey: observationID)?.finish()
    }

    func resolveServerRequest(
        _ key: CodexServerRequestKey,
        result: CodexJSONValue
    ) throws {
        guard terminalKeys.insert(key).inserted else {
            throw CodexSessionError.unknownServerRequest(key)
        }
        resolutions.append(.init(key: key, result: result))
    }

    func failServerRequest(
        _ key: CodexServerRequestKey,
        error: CodexServerRequestResponseError
    ) throws {
        guard terminalKeys.insert(key).inserted else {
            throw CodexSessionError.unknownServerRequest(key)
        }
        failures.append(.init(key: key, error: error))
    }

    func publish(_ snapshot: CodexServerRequestInboxSnapshot) {
        self.snapshot = snapshot
        for continuation in continuations.values {
            continuation.yield(.init(latestRevision: snapshot.revision))
        }
    }

    func recordedResolutions() -> [RecordedResolution] { resolutions }
    func recordedFailures() -> [RecordedFailure] { failures }
    func terminalCount() -> Int { terminalKeys.count }
    func cancelledObservationCount() -> Int { cancelledObservationIDs.count }
}

@MainActor
private func waitUntil(
    attempts: Int = 200,
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for prompt runtime state")
}

private extension Result where Success == CodexPromptStateActivity?, Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isAlreadyTerminal: Bool {
        guard case .failure(let error) = self,
              let sessionError = error as? CodexSessionError,
              case .unknownServerRequest = sessionError else { return false }
        return true
    }
}
