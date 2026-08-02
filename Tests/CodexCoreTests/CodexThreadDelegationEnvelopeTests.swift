import XCTest
@testable import CodexCore

final class CodexThreadDelegationEnvelopeTests: XCTestCase {
    func testRoundTripPreservesSourceAndEscapedPrompt() {
        let value = CodexThreadDelegationEnvelope(
            sourceThreadID: "source-thread",
            input: "Compare a < b && b > c"
        )

        XCTAssertEqual(
            CodexThreadDelegationEnvelope.decode(value.encodedText),
            value
        )
        XCTAssertTrue(value.encodedText.contains("<source_thread_id>source-thread</source_thread_id>"))
        XCTAssertTrue(value.encodedText.contains("&lt;"))
    }

    func testOrdinaryAndPartialTextAreNotDelegations() {
        XCTAssertNil(CodexThreadDelegationEnvelope.decode("ordinary prompt"))
        XCTAssertNil(CodexThreadDelegationEnvelope.decode("<codex_delegation></codex_delegation>"))
    }
}
