import XCTest
import AppKit
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

    func testMakeAppKitAttributedStringRemovesEscapesAndPreservesStyle() throws {
        let parser = ANSIParser()
        let segments = parser.parse("\u{001B}[32mGreen\u{001B}[0m plain")
        let result = ANSITerminalStyle.makeAppKitAttributedString(
            from: segments,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            defaultForeground: .labelColor
        )

        XCTAssertEqual(result.string, "Green plain")
        let green = try XCTUnwrap(
            (result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.deviceRGB)
        )
        XCTAssertEqual(green.greenComponent, 1, accuracy: 0.001)
        XCTAssertNotNil(result.attribute(.foregroundColor, at: 6, effectiveRange: nil))
    }
}
