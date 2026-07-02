import XCTest
@testable import CodexCore

final class CodexLineBufferTests: XCTestCase {
    func testEmitsCompleteLinesAcrossChunks() {
        let buffer = CodexLineBuffer()

        XCTAssertEqual(buffer.append(Data("one".utf8)), [])
        XCTAssertEqual(buffer.append(Data("\ntwo\nthr".utf8)), ["one", "two"])
        XCTAssertEqual(buffer.bufferedByteCount, 3)
        XCTAssertEqual(buffer.append(Data("ee\n".utf8)), ["three"])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testCompactsConsumedLinesWithoutDroppingPartialTail() {
        let buffer = CodexLineBuffer()

        for index in 0..<2_000 {
            XCTAssertEqual(buffer.append(Data("line-\(index)\n".utf8)), ["line-\(index)"])
        }

        XCTAssertEqual(buffer.append(Data("partial".utf8)), [])
        XCTAssertEqual(buffer.bufferedByteCount, "partial".utf8.count)
        XCTAssertEqual(buffer.append(Data("-tail\n".utf8)), ["partial-tail"])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }
}
