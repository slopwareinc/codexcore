import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexSubagentPresentationCoordinatorTests {
    @Test func childLeaseSurvivesReconnectProjectsContentAndReleasesOnRemoval() async throws {
        let homeURL = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
            .appendingPathComponent(
                "codexcore-subagent-coordinator-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(
                codexHome: home,
                reconnectPolicy: .init(
                    isEnabled: true,
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0,
                    multiplier: 1
                )
            )
        )
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        coordinator.selectParent("parent")

        await transport.sendParentDiscovery()
        try await eventually {
            coordinator.agents.count == 1
                && coordinator.agents[0].threadID == "child"
                && !coordinator.agents[0].transcript.turns.isEmpty
        }
        #expect(coordinator.diagnostics.childLeaseAcquisitionCount == 1)
        #expect(coordinator.agents[0].transcript.turns[0].narrative.contains { !$0.id.isEmpty })

        await transport.failCurrentConnection()
        try await eventually {
            let counts = await transport.counts()
            return counts.open >= 2 && counts.resume >= 2
        }
        try await eventually {
            coordinator.agents.first?.transcript.turns.isEmpty == false
        }

        await transport.sendThreadDeleted("child")
        try await eventually { coordinator.agents.isEmpty }
        #expect(coordinator.diagnostics.childLeaseReleaseCount >= 1)

        await coordinator.disconnect()
        await codex.close()
    }

    @Test func childProjectionRunsOffMainAndOldParentResultIsDiscarded() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "codexcore-subagent-off-main-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home)
        )
        let gate = CoordinatorProjectionGate()
        defer { gate.releaseFirstProjection() }
        let coordinator = CodexSubagentPresentationCoordinator(
            codex: codex,
            projectionOperation: { snapshot, threadID, previous in
                gate.project(
                    snapshot: snapshot,
                    threadID: threadID,
                    previous: previous
                )
            }
        )
        coordinator.selectParent("parent")

        await transport.sendParentDiscovery()
        try await eventually { gate.invocationCount == 1 }
        #expect(gate.firstProjectionWasOnMainThread == false)

        coordinator.selectParent(nil)
        gate.releaseFirstProjection()
        try await eventually {
            coordinator.diagnostics.childProjectionDiscardCount == 1
        }

        #expect(coordinator.agents.isEmpty)
        #expect(coordinator.retainedProjectionPreparedUTF8ByteCount == 0)
        #expect(coordinator.diagnostics.childProjectionCount == 0)

        await coordinator.disconnect()
        await codex.close()
    }

    @Test func streamingChildSnapshotsAreSingleFlightAndOnlyNewestPublishes() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "codexcore-subagent-single-flight-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home)
        )
        let gate = CoordinatorProjectionGate()
        defer { gate.releaseFirstProjection() }
        let coordinator = CodexSubagentPresentationCoordinator(
            codex: codex,
            projectionOperation: { snapshot, threadID, previous in
                gate.project(
                    snapshot: snapshot,
                    threadID: threadID,
                    previous: previous
                )
            }
        )
        coordinator.selectParent("parent")

        await transport.sendParentDiscovery()
        try await eventually { gate.invocationCount == 1 }
        #expect(gate.firstProjectionWasOnMainThread == false)

        await transport.sendChildDelta(" middle")
        try await eventually {
            coordinator.diagnostics.childSnapshotCoalescingCount >= 1
        }
        await transport.sendChildDelta(" newest")
        try await eventually {
            coordinator.diagnostics.childSnapshotCoalescingCount >= 2
        }

        #expect(coordinator.agents.first?.transcript.turns.isEmpty == true)
        #expect(gate.invocationCount == 1)

        gate.releaseFirstProjection()
        try await eventually {
            coordinator.diagnostics.childProjectionCount == 1
                && coordinator.agents.first.map {
                    Self.transcriptText($0.transcript).contains("newest")
                } == true
        }

        #expect(gate.invocationCount == 2)
        #expect(coordinator.diagnostics.childProjectionScheduleCount == 2)
        #expect(coordinator.diagnostics.childProjectionDiscardCount == 1)

        await coordinator.disconnect()
        await codex.close()
    }

    private static func transcriptText(_ transcript: CodexTranscriptV2) -> String {
        transcript.turns.flatMap { turn in
            var values = turn.narrative.compactMap { entry -> String? in
                guard case .prose(let prose) = entry else { return nil }
                return prose.text
            }
            if let finalAnswer = turn.finalAnswer?.text {
                values.append(finalAnswer)
            }
            if let liveTail = turn.liveTail {
                values.append(liveTail)
            }
            return values
        }.joined(separator: "\n")
    }
}

private enum CoordinatorTestError: Error {
    case disconnected
    case timedOut
}

private actor CoordinatorTestTransport: CodexFrameTransport {
    private let homePath: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var openCount = 0
    private(set) var resumeCount = 0

    init(homePath: String) {
        self.homePath = homePath
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard continuation == nil else { throw CodexTransportError.connectionAlreadyOpen }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        openCount += 1
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard case .dictionary(let object) = value,
              case .string(let method)? = object["method"],
              let rawID = object["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(homePath),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex/0.145.0-alpha.20"),
            ])
        case "thread/read":
            let threadID = object.objectParams?["threadId"]?.flatString ?? "child"
            result = Self.threadMetadataResult(threadID: threadID)
        case "thread/resume":
            resumeCount += 1
            let threadID = object.objectParams?["threadId"]?.flatString ?? "child"
            result = Self.resumeResult(threadID: threadID)
        case "thread/unsubscribe":
            result = .dictionary([:])
        default:
            result = .dictionary([:])
        }
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func failCurrentConnection() {
        let current = continuation
        continuation = nil
        current?.finish(throwing: CoordinatorTestError.disconnected)
    }

    func counts() -> (open: Int, resume: Int) {
        (openCount, resumeCount)
    }

    func sendParentDiscovery() {
        sendNotification(
            method: "turn/started",
            params: [
                "threadId": .string("parent"),
                "turn": .dictionary([
                    "id": .string("parent-turn"),
                    "items": .array([]),
                    "itemsView": .string("notLoaded"),
                    "status": .string("inProgress"),
                    "error": .null,
                    "startedAt": .int(1_700_000_000),
                    "completedAt": .null,
                    "durationMs": .null,
                ]),
            ]
        )
        sendNotification(
            method: "item/completed",
            params: [
                "threadId": .string("parent"),
                "turnId": .string("parent-turn"),
                "completedAtMs": .int(1_700_000_000_100),
                "item": .dictionary([
                    "type": .string("subAgentActivity"),
                    "id": .string("spawn-child"),
                    "kind": .string("started"),
                    "agentThreadId": .string("child"),
                    "agentPath": .string("/root/scout"),
                ]),
            ]
        )
    }

    func sendThreadDeleted(_ threadID: String) {
        sendNotification(
            method: "thread/deleted",
            params: ["threadId": .string(threadID)]
        )
    }

    func sendChildDelta(_ delta: String) {
        sendNotification(
            method: "item/agentMessage/delta",
            params: [
                "threadId": .string("child"),
                "turnId": .string("child-turn"),
                "itemId": .string("child-message"),
                "delta": .string(delta),
            ]
        )
    }

    private func sendNotification(
        method: String,
        params: [String: CodexJSONValue]
    ) {
        guard let frame = try? CodexJSONRPCCodec.encodeNotification(
            method: method,
            objectParams: params
        ) else { return }
        continuation?.yield(frame)
    }

    private static func threadMetadataResult(threadID: String) -> CodexJSONValue {
        .dictionary([
            "thread": .dictionary([
                "agentNickname": .string("Scout"),
                "agentRole": .string("explorer"),
                "cliVersion": .string("0.145.0-alpha.20"),
                "createdAt": .int(1_700_000_000),
                "cwd": .string("/tmp"),
                "ephemeral": .bool(true),
                "historyMode": .string("legacy"),
                "id": .string(threadID),
                "modelProvider": .string("openai"),
                "parentThreadId": .string("parent"),
                "path": .string("/root/scout"),
                "preview": .string("Working"),
                "sessionId": .string("session-\(threadID)"),
                "source": .string("appServer"),
                "status": .dictionary(["type": .string("active"), "activeFlags": .array([])]),
                "turns": .array([]),
                "updatedAt": .int(1_700_000_001),
            ]),
        ])
    }

    private static func resumeResult(threadID: String) -> CodexJSONValue {
        .dictionary([
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("auto_review"),
            "cwd": .string("/tmp"),
            "model": .string("gpt-5.6"),
            "modelProvider": .string("openai"),
            "sandbox": .dictionary(["type": .string("workspaceWrite")]),
            "thread": .dictionary([
                "agentNickname": .string("Scout"),
                "agentRole": .string("explorer"),
                "cliVersion": .string("0.145.0-alpha.20"),
                "createdAt": .int(1_700_000_000),
                "cwd": .string("/tmp"),
                "ephemeral": .bool(true),
                "historyMode": .string("legacy"),
                "id": .string(threadID),
                "modelProvider": .string("openai"),
                "parentThreadId": .string("parent"),
                "path": .string("/root/scout"),
                "preview": .string("Working"),
                "sessionId": .string("session-\(threadID)"),
                "source": .string("appServer"),
                "status": .dictionary(["type": .string("active"), "activeFlags": .array([])]),
                "turns": .array([.dictionary([
                    "id": .string("child-turn"),
                    "items": .array([.dictionary([
                        "type": .string("agentMessage"),
                        "id": .string("child-message"),
                        "phase": .string("commentary"),
                        "text": .string("Inspecting the repository"),
                    ])]),
                    "itemsView": .string("full"),
                    "status": .string("inProgress"),
                    "error": .null,
                    "startedAt": .int(1_700_000_000),
                    "completedAt": .null,
                    "durationMs": .null,
                ])]),
                "updatedAt": .int(1_700_000_001),
            ]),
        ])
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    var objectParams: [String: CodexJSONValue]? {
        CodexJSONCoercion.dictionary(from: self["params"])
    }
}

private extension CodexJSONValue {
    var flatString: String? { CodexJSONCoercion.flatString(from: self) }
}

private final class CoordinatorProjectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didReleaseFirstProjection = false
    private var invocations = 0
    private var firstWasOnMainThread: Bool?

    var invocationCount: Int {
        condition.lock()
        let value = invocations
        condition.unlock()
        return value
    }

    var firstProjectionWasOnMainThread: Bool? {
        condition.lock()
        let value = firstWasOnMainThread
        condition.unlock()
        return value
    }

    func releaseFirstProjection() {
        condition.lock()
        didReleaseFirstProjection = true
        condition.broadcast()
        condition.unlock()
    }

    func project(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        previous: CodexCanonicalTranscriptPresentation?
    ) -> CodexCanonicalTranscriptProjectionResult {
        condition.lock()
        invocations += 1
        let shouldWait = invocations == 1
        if shouldWait {
            firstWasOnMainThread = Thread.isMainThread
            condition.broadcast()
        }
        let deadline = Date().addingTimeInterval(2)
        while shouldWait && !didReleaseFirstProjection
            && condition.wait(until: deadline) {}
        if shouldWait && !didReleaseFirstProjection {
            didReleaseFirstProjection = true
        }
        condition.unlock()

        return CodexSubagentStoreV2.projectChildSnapshot(
            snapshot,
            threadID: threadID,
            previous: previous
        )
    }
}

@MainActor
private func eventually(
    attempts: Int = 300,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CoordinatorTestError.timedOut
}
