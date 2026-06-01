import XCTest
@testable import CodexCore

final class JSONBridgeTests: XCTestCase {
    private struct Params: Codable, Equatable {
        var threadId: String
        var includeTurns: Bool
        var omitted: String?
    }

    private struct Response: Codable, Equatable {
        var threadId: String
        var count: Int
    }

    func testEncodesCodableToJSONValueObject() throws {
        let params = Params(threadId: "thread-1", includeTurns: true, omitted: nil)
        let value = try CodexJSONValue(encoding: params)

        guard case .dictionary(let object) = value else {
            XCTFail("Params should encode to an object")
            return
        }

        XCTAssertEqual(object["threadId"], .string("thread-1"))
        XCTAssertEqual(object["includeTurns"], .bool(true))
        XCTAssertNil(object["omitted"])
    }

    func testDecodesJSONValueToCodableResponse() throws {
        let value = CodexJSONValue.dictionary([
            "threadId": .string("thread-1"),
            "count": .int(3)
        ])

        let response = try value.decode(Response.self)
        XCTAssertEqual(response, Response(threadId: "thread-1", count: 3))
    }
}
