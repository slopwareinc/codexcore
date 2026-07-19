import XCTest
@testable import CodexCore

final class ANSIParserTests: XCTestCase {
    func testSGRStylesAndOSCHyperlinkControlSequences() {
        let parser = ANSIParser()

        let segments = parser.parse("\u{001B}[31mRed Text\u{001B}[0m Standard Text")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Red Text")
        XCTAssertEqual(segments[0].style.foregroundColor, .red)
        XCTAssertEqual(segments[1].text, " Standard Text")
        XCTAssertEqual(segments[1].style.foregroundColor, .default)

        let complex = parser.parse("\u{001B}[1;4;44;33mStyled Text\u{001B}[0m")
        XCTAssertEqual(complex.count, 1)
        XCTAssertEqual(complex[0].text, "Styled Text")
        XCTAssertTrue(complex[0].style.isBold)
        XCTAssertTrue(complex[0].style.isUnderlined)
        XCTAssertEqual(complex[0].style.foregroundColor, .yellow)
        XCTAssertEqual(complex[0].style.backgroundColor, .blue)

        let osc = parser.parse(
            "\u{001B}]8;;http://google.com\u{0007}Google Link\u{001B}]8;;\u{0007} Rest"
        )
        XCTAssertEqual(osc.map(\.text), ["Google Link", " Rest"])
    }
}
