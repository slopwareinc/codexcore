import XCTest
@testable import CodexCore

final class CodexReviewTargetTests: XCTestCase {
    func testReviewTargetsEncodeOfficialTaggedUnionShapes() throws {
        XCTAssertEqual(
            try encodedObject(.uncommittedChanges),
            ["type": "uncommittedChanges"]
        )
        XCTAssertEqual(
            try encodedObject(.baseBranch("main")),
            ["branch": "main", "type": "baseBranch"]
        )
        XCTAssertEqual(
            try encodedObject(.commit(sha: "abc123", title: "Fix race")),
            ["sha": "abc123", "title": "Fix race", "type": "commit"]
        )
        XCTAssertEqual(
            try encodedObject(.custom("Focus on cancellation")),
            ["instructions": "Focus on cancellation", "type": "custom"]
        )
    }

    private func encodedObject(
        _ target: CodexReviewTarget
    ) throws -> [String: String] {
        let data = try JSONEncoder().encode(target.schemaValue)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }
}
