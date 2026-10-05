import XCTest
import CodexCore
@testable import CodexCoreApp

final class CodexSideConversationPolicyTests: XCTestCase {
    func testForkDefersInheritedGoalAndPreservesHostInstructions() {
        let original = CodexSchemaThreadForkParams(developerInstructions: "Per-thread rules", model: "model", permissions: "workspace", threadID: "parent")
        let params = CodexSideConversationPolicy.prepare(original, inheritedInstructions: "Host rules")
        XCTAssertEqual(params.threadID, "parent")
        XCTAssertEqual(params.permissions, "workspace")
        XCTAssertEqual(params.model, "model")
        XCTAssertEqual(params.ephemeral, true)
        XCTAssertEqual(params.excludeTurns, true)
        XCTAssertEqual(params.deferGoalContinuation, true)
        XCTAssertTrue(params.developerInstructions?.hasPrefix("Host rules\n\nPer-thread rules") == true)
        XCTAssertTrue(params.developerInstructions?.contains("Do not continue parent tasks") == true)
    }

    func testBoundaryUsesProtocolResponseItemRatherThanThreadItem() throws {
        let object = try XCTUnwrap(CodexSideConversationPolicy.boundary.objectValue)
        XCTAssertEqual(object["type"], .string("message"))
        XCTAssertEqual(object["role"], .string("user"))
        guard case .array(let content)? = object["content"] else { return XCTFail("Expected content blocks") }
        XCTAssertEqual(content.first?.objectValue?["type"], .string("input_text"))
    }
}
