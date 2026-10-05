import Foundation
import Testing
@testable import CodexCore

struct CodexOutOfBandElicitationTests {
    @Test func successAndNestedInteractionsBalanceExactThreadCounters() async throws {
        let (session, transport, thread) = try await runtime()
        let value = try await thread.withOutOfBandElicitation {
            try await thread.withOutOfBandElicitation { 42 }
        }
        #expect(value == 42)
        #expect(await transport.pauseCount == 0)
        #expect(await transport.maximumPauseCount == 2)
        #expect(await transport.parameters("thread/increment_elicitation").count == 2)
        #expect(await transport.parameters("thread/decrement_elicitation").allSatisfy { $0["threadId"] == .string("thread") })
        await thread.close(); await session.stop()
    }

    @Test func throwingInteractionPreservesOriginalErrorAndReleasesOnce() async throws {
        let (session, transport, thread) = try await runtime()
        do {
            let _: Int = try await thread.withOutOfBandElicitation { throw InteractionFailure() }
            Issue.record("Expected the original interaction failure")
        } catch is InteractionFailure {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await transport.pauseCount == 0)
        #expect(await transport.parameters("thread/decrement_elicitation").count == 1)
        await thread.close(); await session.stop()
    }

    @Test func cancellationBeforeIncrementAcknowledgmentStillReleasesAcceptedPause() async throws {
        let (session, transport, thread) = try await runtime()
        await transport.holdIncrement()
        let body = InteractionProbe()
        let operation = Task {
            try await thread.withOutOfBandElicitation { await body.markEntered(); return 42 }
        }
        try await transport.waitForHeldIncrement()
        operation.cancel()
        await transport.releaseIncrement()
        do { _ = try await operation.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await !body.entered)
        #expect(await transport.pauseCount == 0)
        #expect(await transport.parameters("thread/decrement_elicitation").count == 1)
        await thread.close(); await session.stop()
    }

    @Test func closedLeaseDuringInteractionStillReleasesOriginalCounter() async throws {
        let (session, transport, thread) = try await runtime()
        let value = try await thread.withOutOfBandElicitation { await thread.close(); return true }
        #expect(value)
        #expect(thread.isClosed)
        #expect(await transport.pauseCount == 0)
        #expect(await transport.parameters("thread/decrement_elicitation").count == 1)
        await session.stop()
    }

    @Test func reconnectNeverReleasesOnReplacementEpochAndReportsFailure() async throws {
        let (session, transport, thread) = try await runtime()
        do {
            _ = try await thread.withOutOfBandElicitation {
                await session.stop()
                _ = try await session.start()
                return true
            }
            Issue.record("Expected original-epoch release failure")
        } catch let error as CodexOutOfBandElicitationReleaseError {
            #expect(error.threadID == .init("thread"))
            #expect(error.connectionEpoch == 1)
            #expect(error.operationFailure == nil)
        }
        #expect(await transport.parameters("thread/decrement_elicitation").isEmpty)
        await thread.close(); await session.stop()
    }

    @Test func immediateRestartsKeepReplacementConnectionsReady() async throws {
        let (session, transport, thread) = try await runtime()
        for expectedEpoch in 2...12 {
            await session.stop()
            _ = try await session.start()
            #expect(await session.lifecycle == .ready(connectionEpoch: UInt64(expectedEpoch)))
            try await thread.injectItems([])
        }
        #expect(await transport.parameters("thread/inject_items").count == 11)
        await thread.close(); await session.stop()
    }

    @Test func failedIncrementNeverRunsInteractionOrAttemptsRelease() async throws {
        let (session, transport, thread) = try await runtime()
        await transport.failIncrement()
        let body = InteractionProbe()
        do { _ = try await thread.withOutOfBandElicitation { await body.markEntered(); return true }; Issue.record("Expected failure") }
        catch {}
        #expect(await !body.entered)
        #expect(await transport.parameters("thread/decrement_elicitation").isEmpty)
        await thread.close(); await session.stop()
    }

    @Test func responseItemConvenienceInjectsExactPayloadAndRejectsWrongOrClosedThread() async throws {
        let (session, transport, thread) = try await runtime()
        let item = CodexSchemaResponseItem(.dictionary([
            "type": .string("message"), "role": .string("user"),
            "content": .array([.dictionary(["type": .string("input_text"), "text": .string("Boundary")])])
        ]))
        try await thread.injectItems([item])
        let params = await transport.parameters("thread/inject_items")
        #expect(params.count == 1)
        #expect(params[0]["threadId"] == .string("thread"))
        #expect(params[0]["items"] == .array([item.rawValue]))
        do { try await thread.injectItems(.init(items: [item.rawValue], threadID: "other")); Issue.record("Expected mismatch") }
        catch let error as CodexLeaseError { #expect(error == .requestThreadMismatch(expected: "thread", actual: "other")) }
        await thread.close()
        do { try await thread.injectItems([item]); Issue.record("Expected closed lease") }
        catch let error as CodexLeaseError { #expect(error == .closedThread("thread")) }
        #expect(await transport.parameters("thread/inject_items").count == 1)
        await session.stop()
    }

    private func runtime() async throws -> (CodexSession, ElicitationFixtureTransport, CodexThreadLease) {
        let transport = ElicitationFixtureTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let thread = try await session.startThread()
        return (session, transport, thread)
    }
    private struct InteractionFailure: Error {}
}

private actor InteractionProbe {
    private(set) var entered = false
    func markEntered() { entered = true }
}

private actor ElicitationFixtureTransport: CodexFrameTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var calls: [(method: String, params: [String: CodexJSONValue])] = []
    private var holdsIncrement = false
    private var failsIncrement = false
    private var heldIncrement: (id: CodexJSONRPCID, value: CodexJSONValue)?
    private(set) var pauseCount = 0
    private(set) var maximumPauseCount = 0

    func open() -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func close() { continuation?.finish(); continuation = nil }
    func holdIncrement() { holdsIncrement = true }
    func failIncrement() { failsIncrement = true }
    func parameters(_ method: String) -> [[String: CodexJSONValue]] { calls.filter { $0.method == method }.map(\.params) }
    func waitForHeldIncrement() async throws {
        for _ in 0..<1_000 { if heldIncrement != nil { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw FixtureTimeout()
    }
    func releaseIncrement() {
        if let heldIncrement { respond(heldIncrement.id, value: heldIncrement.value); self.heldIncrement = nil }
    }

    func write(_ frame: Data) throws {
        let object = try JSONDecoder().decode(CodexJSONValue.self, from: frame).objectValue ?? [:]
        guard case .string(let method)? = object["method"] else { return }
        let params = object["params"]?.objectValue ?? [:]
        calls.append((method, params))
        guard let rawID = object["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let value: CodexJSONValue
        switch method {
        case "initialize":
            value = .dictionary(["codexHome": .string(CodexHome.default.path), "platformFamily": .string("unix"), "platformOs": .string("macos"), "userAgent": .string("Codex/0.160.0 test")])
        case "thread/start", "thread/resume", "thread/read":
            value = .dictionary([
                "approvalPolicy": .string("never"), "approvalsReviewer": .string("user"),
                "cwd": .string("/tmp"), "model": .string("model"), "modelProvider": .string("openai"),
                "sandbox": .dictionary(["type": .string("readOnly")]), "serviceTier": .null,
                "thread": .dictionary([
                    "id": .string("thread"), "cliVersion": .string("0.160.0"), "createdAt": .int(1), "updatedAt": .int(1),
                    "cwd": .string("/tmp"), "ephemeral": .bool(false), "modelProvider": .string("openai"),
                    "preview": .string(""), "sessionId": .string("session"), "projectId": .null, "historyMode": .string("legacy"),
                    "source": .string("appServer"), "status": .dictionary(["type": .string("idle")]), "turns": .array([])
                ])
            ])
        case "thread/unsubscribe":
            value = .dictionary(["status": .string("unsubscribed")])
        case "thread/increment_elicitation":
            if failsIncrement {
                let frame = try CodexJSONRPCCodec.encodeError(id: id, error: .init(code: -32_000, message: "increment rejected"))
                continuation?.yield(frame); return
            }
            pauseCount += 1; maximumPauseCount = max(maximumPauseCount, pauseCount)
            value = .dictionary(["count": .int(pauseCount), "paused": .bool(pauseCount > 0)])
            if holdsIncrement { heldIncrement = (id, value); holdsIncrement = false; return }
        case "thread/decrement_elicitation":
            pauseCount -= 1
            value = .dictionary(["count": .int(pauseCount), "paused": .bool(pauseCount > 0)])
        default: value = .dictionary([:])
        }
        respond(id, value: value)
    }
    private func respond(_ id: CodexJSONRPCID, value: CodexJSONValue) {
        if let data = try? CodexJSONRPCCodec.encodeResult(id: id, result: value) { continuation?.yield(data) }
    }
    private struct FixtureTimeout: Error {}
}
