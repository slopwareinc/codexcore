import XCTest
@testable import CodexCoreUI

final class CodexMCPStatusSheetTests: XCTestCase {
    func testConfigurationTextValuesTrimBlankLinesWithoutRetainingTemporaryMappedStrings() {
        XCTAssertEqual(
            CodexMCPConfigurationText.values(" first \n\n  \nsecond\n"),
            ["first", "second"]
        )
    }

    func testConfigurationTextDictionaryPreservesMalformedLineFilteringAndFirstEqualsValue() {
        XCTAssertEqual(
            CodexMCPConfigurationText.dictionary(" A = B \nmissing equals\n=leading\ntrailing=\nx==y\n"),
            ["A ": " B", "x": "=y"]
        )
    }
}
