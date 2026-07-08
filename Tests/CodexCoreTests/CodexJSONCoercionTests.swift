import XCTest
@testable import CodexCore

final class CodexJSONCoercionTests: XCTestCase {
    // MARK: - String helpers

    func testNilIfEmptyDoesNotTrim() {
        XCTAssertNil("".nilIfEmpty)
        XCTAssertEqual("  ".nilIfEmpty, "  ")
        XCTAssertEqual("x".nilIfEmpty, "x")
    }

    func testNilIfBlankTrims() {
        XCTAssertNil("".nilIfBlank)
        XCTAssertNil("  \n\t ".nilIfBlank)
        XCTAssertEqual("  x  ".nilIfBlank, "x")
    }

    // MARK: - Status heuristics

    func testIsActiveStreamingMatchesWireValues() {
        XCTAssertTrue(CodexStatusHeuristics.isActiveStreaming("active"))
        XCTAssertTrue(CodexStatusHeuristics.isActiveStreaming("inProgress"))
        XCTAssertTrue(CodexStatusHeuristics.isActiveStreaming("running"))
        XCTAssertFalse(CodexStatusHeuristics.isActiveStreaming("in_progress"))
        XCTAssertFalse(CodexStatusHeuristics.isActiveStreaming("completed"))
        XCTAssertFalse(CodexStatusHeuristics.isActiveStreaming(""))
    }

    // MARK: - Path formatter

    func testAbbreviatingHome() {
        let home = "/Users/tester"
        XCTAssertEqual(CodexPathFormatter.abbreviatingHome(home, home: home), "~")
        XCTAssertEqual(CodexPathFormatter.abbreviatingHome("/Users/tester/dev/x", home: home), "~/dev/x")
        // A sibling directory sharing the home prefix must NOT be abbreviated.
        XCTAssertEqual(CodexPathFormatter.abbreviatingHome("/Users/tester2/x", home: home), "/Users/tester2/x")
        XCTAssertEqual(CodexPathFormatter.abbreviatingHome("/opt/other", home: home), "/opt/other")
    }

    // MARK: - JSON coercion (default precedence)

    func testStringCoercionScalars() {
        XCTAssertEqual(CodexJSONCoercion.string(from: .string("hi")), "hi")
        XCTAssertEqual(CodexJSONCoercion.string(from: .int(3)), "3")
        XCTAssertEqual(CodexJSONCoercion.string(from: .bool(true)), "true")
        XCTAssertNil(CodexJSONCoercion.string(from: .null))
        XCTAssertNil(CodexJSONCoercion.string(from: nil))
    }

    func testDefaultDictionaryPrecedenceIsTextValueMessageTypeRaw() {
        let object: CodexJSONValue = .dictionary([
            "type": .string("kind"),
            "text": .string("body"),
            "message": .string("msg"),
        ])
        // Default precedence prefers "text" over "message"/"type".
        XCTAssertEqual(CodexJSONCoercion.string(from: object), "body")
        XCTAssertEqual(CodexJSONCoercion.defaultStringKeys, ["text", "value", "message", "type", "raw"])
    }

    func testCustomDictionaryPrecedenceIsHonored() {
        let object: CodexJSONValue = .dictionary([
            "type": .string("kind"),
            "text": .string("body"),
        ])
        // A call site that intentionally wants "type" first still gets it.
        XCTAssertEqual(
            CodexJSONCoercion.string(from: object, dictionaryKeys: ["type", "text", "value"]),
            "kind"
        )
    }

    func testArraySeparatorIsConfigurable() {
        let array: CodexJSONValue = .array([.string("a"), .string("b")])
        XCTAssertEqual(CodexJSONCoercion.string(from: array), "a b")
        XCTAssertEqual(
            CodexJSONCoercion.string(from: array, dictionaryKeys: [], separator: "\n"),
            "a\nb"
        )
    }

    func testTrimScalarsDropsEmptyScalarStrings() {
        XCTAssertEqual(CodexJSONCoercion.string(from: .string("")), "")
        XCTAssertNil(CodexJSONCoercion.string(from: .string(""), dictionaryKeys: [], trimScalars: true))
    }

    func testIntAndBoolAndStringArrayCoercion() {
        XCTAssertEqual(CodexJSONCoercion.int(from: .string("42")), 42)
        XCTAssertEqual(CodexJSONCoercion.int(from: .double(2.9)), 2)
        XCTAssertEqual(CodexJSONCoercion.bool(from: .int(1)), true)
        XCTAssertEqual(CodexJSONCoercion.bool(from: .int(0)), false)
        XCTAssertEqual(
            CodexJSONCoercion.stringArray(from: .array([.string("a"), .string(" "), .string("b")])),
            ["a", "b"]
        )
    }
}
