import XCTest
import CodexCore
@testable import CodexCoreUI

final class ANSITerminalStyleTests: XCTestCase {
    func testMakeAttributedStringPreservesText() throws {
        if #unavailable(macOS 12.0, iOS 15.0) {
            throw XCTSkip("AttributedString styling requires macOS 12 / iOS 15")
        }

        let parser = ANSIParser()
        let rawInput = "\u{001B}[31mRed Text\u{001B}[0m Standard Text"
        let segments = parser.parse(rawInput)
        let attrStr = ANSITerminalStyle.makeAttributedString(from: segments)
        let rawStr = String(attrStr.characters)
        XCTAssertEqual(rawStr, "Red Text Standard Text")
    }
}
