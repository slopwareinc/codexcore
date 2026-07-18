import Foundation
import XCTest
@testable import CodexCore

final class JSONRPCEnvelopeTests: XCTestCase {
    func testInboundAppServerResponseMayOmitJSONRPCVersion() throws {
        let frame = try JSONEncoder().encode(CodexJSONValue.dictionary([
            "id": .int(1),
            "result": .dictionary(["codexHome": .string("/tmp/home")]),
        ]))

        guard case .response(let response) = try CodexJSONRPCCodec.decode(frame) else {
            return XCTFail("Expected response")
        }
        XCTAssertEqual(response.id, .integer(1))
    }

    func testInboundAppServerNotificationMayOmitJSONRPCVersion() throws {
        let frame = try JSONEncoder().encode(CodexJSONValue.dictionary([
            "method": .string("thread/started"),
            "params": .dictionary([:]),
        ]))

        guard case .notification(let notification) = try CodexJSONRPCCodec.decode(frame) else {
            return XCTFail("Expected notification")
        }
        XCTAssertEqual(notification.method, "thread/started")
    }

    func testInboundAppServerRequestMayOmitJSONRPCVersion() throws {
        let frame = try JSONEncoder().encode(CodexJSONValue.dictionary([
            "id": .string("approval-1"),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .dictionary([:]),
        ]))

        guard case .serverRequest(let request) = try CodexJSONRPCCodec.decode(frame) else {
            return XCTFail("Expected server request")
        }
        XCTAssertEqual(request.id, .string("approval-1"))
    }

    func testInboundAppServerFrameRejectsConflictingJSONRPCVersion() throws {
        let frame = try JSONEncoder().encode(CodexJSONValue.dictionary([
            "jsonrpc": .string("1.0"),
            "method": .string("thread/started"),
            "params": .dictionary([:]),
        ]))

        XCTAssertThrowsError(try CodexJSONRPCCodec.decode(frame)) { error in
            XCTAssertEqual(
                error as? CodexJSONRPCEnvelopeError,
                .invalidVersion(.string("1.0"))
            )
        }
    }
}
