import XCTest
@testable import CodexCore

final class CodexJSONCoercionTests: XCTestCase {
    func testFlatLookupPreservesScalarAndWhitespacePolicies() {
        let object: [String: CodexJSONValue] = ["nested": .dictionary(["text": .string("nested")]), "blank": .string("  "), "value": .string("  value  ")]
        XCTAssertEqual(CodexJSONCoercion.flatString(in: object, keys: ["nested", "blank", "value"]), "  ")
        XCTAssertEqual(CodexJSONCoercion.flatString(in: object, keys: ["nested", "blank", "value"], trimmingWhitespace: true), "value")
        XCTAssertEqual(CodexJSONCoercion.flatString(in: ["value": .bool(false)], keys: ["value"]), "false")
    }

    func testReconnectDelaySaturatesWithoutIntegerOverflow() {
        let policy = CodexReconnectPolicy(initialDelayMilliseconds: 1, maximumDelayMilliseconds: .max, multiplier: 2)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 2), 2)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 65), UInt64.max)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: Int.max), UInt64.max)
        let huge = CodexReconnectPolicy(initialDelayMilliseconds: .max, maximumDelayMilliseconds: .max)
        XCTAssertEqual(huge.delayMilliseconds(forAttempt: 2), UInt64.max)
    }

    func testIntegerCoercionRejectsNonfiniteAndOutOfRangeNumbers() {
        for number in [Double.nan, .infinity, -.infinity, 1e100, -1e100, Double(Int.max)] {
            XCTAssertNil(CodexJSONCoercion.int(from: .double(number)))
        }
        XCTAssertEqual(CodexJSONCoercion.int(from: .double(-2.9)), -2)
        XCTAssertEqual(CodexJSONCoercion.int(from: .double(Double(Int.min))), Int.min)
        XCTAssertEqual(CodexJSONCoercion.int(from: .double(Double(Int.max).nextDown)), Int.max - 1023)
    }

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

    func testDefaultDictionaryPrecedencePrefersContentOverDiscriminators() {
        let object: CodexJSONValue = .dictionary([
            "type": .string("kind"),
            "text": .string("body"),
            "message": .string("msg"),
        ])
        // Default precedence prefers content ("text") over discriminators ("type").
        XCTAssertEqual(CodexJSONCoercion.string(from: object), "body")
        XCTAssertEqual(CodexJSONCoercion.defaultStringKeys, ["text", "value", "message", "type", "raw", "id"])
    }

    func testTypeIsOnlyUsedAsFallbackWhenNoContentPresent() {
        // A payload carrying only a discriminator still resolves to it.
        let object: CodexJSONValue = .dictionary(["type": .string("kind")])
        XCTAssertEqual(CodexJSONCoercion.string(from: object), "kind")
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
