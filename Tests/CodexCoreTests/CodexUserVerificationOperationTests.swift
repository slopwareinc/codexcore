import XCTest
@testable import CodexCore

@MainActor
final class CodexUserVerificationOperationTests: XCTestCase {
    func testOperationRetainsOriginalIDAndDecodedResult() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let operation = try await session.startUserVerification(CodexRequest.userVerificationStatus(.init(.dictionary([:]))))
        try await wait { await transport.requests("userVerification/status").count == 1 }
        let statusRequests = await transport.requests("userVerification/status")
        let request = try XCTUnwrap(statusRequests.first)
        XCTAssertEqual(request.id, operation.requestID)
        try await transport.respond(id: request.id, result: .dictionary(["credentialId": .string("local-key")]))
        let value = try await operation.completion()
        XCTAssertEqual(value.credentialID, "local-key")
        try await operation.cancel()
        let cancellations = await transport.requests("userVerification/cancel")
        XCTAssertTrue(cancellations.isEmpty)
        await session.stop()
    }

    func testCancellationBeforeFirstWriteDropsOriginalFrame() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let blocker = Task { try await session.perform(method: .serverDiagnostics, params: .dictionary([:])) }
        try await wait { await transport.isHoldingWrite }
        let operation = try await session.startUserVerification(CodexRequest.userVerificationEnroll(.init(.dictionary([:]))))
        try await operation.cancel()
        do { _ = try await operation.completion(); XCTFail("Canceled enrollment must not complete") }
        catch is CancellationError { }
        await transport.releaseWrite()
        blocker.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let enrollments = await transport.requests("userVerification/enroll")
        let cancellations = await transport.requests("userVerification/cancel")
        XCTAssertTrue(enrollments.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
        await session.stop()
    }

    func testCancellationAfterWriteUsesOriginalIDAndDiscardsLateProof() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let operation = try await session.startUserVerification(CodexRequest.userVerificationVerify(.init(challenge: "aGVsbG8", description: "Approve this request", title: "Verify")))
        try await wait { await transport.requests("userVerification/verify").count == 1 }
        try await operation.cancel()
        let cancellations = await transport.requests("userVerification/cancel")
        let cancel = try XCTUnwrap(cancellations.first)
        XCTAssertNotEqual(cancel.id, operation.requestID)
        XCTAssertEqual(cancel.params["requestId"], try CodexJSONValue(encoding: operation.requestID))
        try await transport.respond(id: operation.requestID, result: .dictionary([
            "proof": .dictionary(["credentialId": .string("local-key"), "signature": .string("late-proof")]),
        ]))
        do { _ = try await operation.completion(); XCTFail("Late proofs must be discarded") }
        catch is CancellationError { }
        let lifecycle = await session.lifecycle
        XCTAssertEqual(lifecycle, .ready(connectionEpoch: operation.connectionEpoch))
        await session.stop()
    }

    func testCancelingCompletionWaiterSignalsNativeOperation() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let operation = try await session.startUserVerification(CodexRequest.userVerificationDelete(.init(.dictionary([:]))))
        try await wait { await transport.requests("userVerification/delete").count == 1 }
        let waiter = Task { try await operation.completion() }
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Canceled waiter must fail") }
        catch is CancellationError { }
        try await wait { await transport.requests("userVerification/cancel").count == 1 }
        await session.stop()
    }

    func testStaleHandleCannotCancelReplacementConnection() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        let operation = try await session.startUserVerification(CodexRequest.userVerificationStatus(.init(.dictionary([:]))))
        try await wait { await transport.requests("userVerification/status").count == 1 }
        await session.stop()
        do { _ = try await operation.completion(); XCTFail("Disconnect must fail the operation") } catch { }
        _ = try await session.start()
        try await operation.cancel()
        let cancellations = await transport.requests("userVerification/cancel")
        XCTAssertTrue(cancellations.isEmpty)
        await session.stop()
    }

    func testUnrelatedFactoriesCannotCreateVerificationHandles() async throws {
        let transport = VerificationFrameTransport()
        let session = CodexSession(transport: transport, configuration: .init(reconnectPolicy: .disabled))
        _ = try await session.start()
        do {
            _ = try await session.startUserVerification(CodexRequest.accountGatewayOAuthRead())
            XCTFail("Only native verification methods may obtain a handle")
        } catch CodexSessionError.protocolViolation { }
        let gatewayRequests = await transport.requests("account/gatewayOAuth/read")
        XCTAssertTrue(gatewayRequests.isEmpty)
        await session.stop()
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for verification RPC")
        throw VerificationTestError.timeout
    }
}

private enum VerificationTestError: Error { case timeout, closed }

private actor VerificationFrameTransport: CodexFrameTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var recorded: [CodexJSONRPCServerRequestEnvelope] = []
    private var heldWrite: CheckedContinuation<Void, Never>?
    private(set) var isHoldingWrite = false

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func write(_ data: Data) async throws {
        guard let continuation else { throw VerificationTestError.closed }
        guard case .serverRequest(let request) = try CodexJSONRPCCodec.decode(data) else { return }
        recorded.append(request)
        if request.method == "initialize" {
            continuation.yield(try CodexJSONRPCCodec.encodeResult(id: request.id, result: .dictionary([
                "codexHome": .string(CodexHome.default.path), "platformFamily": .string("unix"),
                "platformOs": .string("macos"), "userAgent": .string("verification-test"),
            ])))
        } else if request.method == "userVerification/cancel" {
            continuation.yield(try CodexJSONRPCCodec.encodeResult(id: request.id, result: .dictionary([:])))
        } else if request.method == "server/diagnostics" {
            isHoldingWrite = true
            await withCheckedContinuation { heldWrite = $0 }
            isHoldingWrite = false
        }
    }
    func close() async { continuation?.finish(); continuation = nil; releaseWrite() }
    func releaseWrite() { heldWrite?.resume(); heldWrite = nil }
    func requests(_ method: String) -> [CodexJSONRPCServerRequestEnvelope] { recorded.filter { $0.method == method } }
    func respond(id: CodexJSONRPCID, result: CodexJSONValue) throws {
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }
}
