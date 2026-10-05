import XCTest
@testable import CodexCore

final class RequiredNullableSchemaTests: XCTestCase {
    func testNoAuthenticationMCPResourceTargetSendsExplicitNull() throws {
        let value = try CodexJSONValue(encoding: CodexSchemaMCPResourceReadTarget(connectorID: "connector", linkID: nil))
        XCTAssertEqual(value, .dictionary(["connectorId": .string("connector"), "linkId": .null]))
        let decoded = try value.decode(CodexSchemaMCPResourceReadTarget.self)
        XCTAssertNil(decoded.linkID)
    }

    func testNullableDecodingAcceptsFieldsAbsentInOlderRuntimeResponses() throws {
        let value = try CodexJSONValue.dictionary(["connectorId": .string("connector")])
            .decode(CodexSchemaMCPResourceReadTarget.self)
        XCTAssertNil(value.linkID)
    }
}
