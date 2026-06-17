import XCTest
@testable import CodexCore

final class CodexConnectionDecodeFailureTests: XCTestCase {

    func testDecodeFailureResumesPendingRequest() async throws {
        let transport = MockTransport(suspendedMethods: ["test/decodeFailure"])
        let connection = CodexConnection(transport: transport)

        _ = try await connection.start(
            onNotification: { _ in },
            onServerRequest: { _ in .null }
        )

        let requestTask = Task {
            try await connection.request(method: "test/decodeFailure")
        }

        try await Task.sleep(for: .milliseconds(50))

        let sent = await transport.sentPayloads
        let requestPayload = try XCTUnwrap(sent.first { ($0["method"]?.description ?? "") == "test/decodeFailure" })
        let requestId = try XCTUnwrap(requestPayload["id"]?.description)

        let malformedResponse = """
        {
            "jsonrpc": "2.0",
            "id": "\(requestId)",
            "result": {}
        }
        """
        await transport.receiveMessage(malformedResponse)

        do {
            _ = try await requestTask.value
            XCTFail("Expected decode failure to resume pending request with an error")
        } catch let error as CodexConnectionError {
            guard case .decodeFailed = error else {
                XCTFail("Expected CodexConnectionError.decodeFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected CodexConnectionError.decodeFailed, got \(error)")
        }

        await connection.stop()
    }

    func testDisconnectFailsPendingRequests() async throws {
        let transport = MockTransport(suspendedMethods: ["test/hung"])
        let connection = CodexConnection(transport: transport)

        _ = try await connection.start(
            onNotification: { _ in },
            onServerRequest: { _ in .null }
        )

        let requestTask = Task {
            try await connection.request(method: "test/hung")
        }

        try await Task.sleep(for: .milliseconds(50))
        await connection.stop()

        do {
            _ = try await requestTask.value
            XCTFail("Expected disconnect to fail pending request")
        } catch let error as CodexConnectionError {
            guard case .closed = error else {
                XCTFail("Expected CodexConnectionError.closed, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected CodexConnectionError.closed, got \(error)")
        }
    }
}
