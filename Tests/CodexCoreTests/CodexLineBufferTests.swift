import XCTest
@testable import CodexCore

final class CodexLineBufferTests: XCTestCase {
    func testEmitsCompleteLinesAcrossChunks() throws {
        let buffer = CodexLineBuffer()

        XCTAssertEqual(try buffer.append(Data("one".utf8)), [])
        XCTAssertEqual(
            try buffer.append(Data("\ntwo\nthr".utf8)),
            [Data("one".utf8), Data("two".utf8)]
        )
        XCTAssertEqual(buffer.bufferedByteCount, 3)
        XCTAssertEqual(
            try buffer.append(Data("ee\n".utf8)),
            [Data("three".utf8)]
        )
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testCompactsConsumedLinesWithoutDroppingPartialTail() throws {
        let buffer = CodexLineBuffer()

        for index in 0..<2_000 {
            XCTAssertEqual(
                try buffer.append(Data("line-\(index)\n".utf8)),
                [Data("line-\(index)".utf8)]
            )
        }

        XCTAssertEqual(try buffer.append(Data("partial".utf8)), [])
        XCTAssertEqual(buffer.bufferedByteCount, "partial".utf8.count)
        XCTAssertEqual(
            try buffer.append(Data("-tail\n".utf8)),
            [Data("partial-tail".utf8)]
        )
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testPartialLineFailsAsSoonAsConfiguredByteLimitIsExceeded() throws {
        let buffer = CodexLineBuffer(maximumLineByteCount: 8)

        XCTAssertEqual(try buffer.append(Data("1234".utf8)), [])
        XCTAssertEqual(try buffer.append(Data("5678".utf8)), [])
        XCTAssertEqual(buffer.bufferedByteCount, 8)

        XCTAssertThrowsError(try buffer.append(Data("9".utf8))) { error in
            XCTAssertEqual(
                error as? CodexTransportError,
                .frameTooLarge(maximumBytes: 8, observedBytes: 9)
            )
        }
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testLineAtConfiguredByteLimitStillEmits() throws {
        let buffer = CodexLineBuffer(maximumLineByteCount: 8)

        XCTAssertEqual(
            try buffer.append(Data("12345678\n".utf8)),
            [Data("12345678".utf8)]
        )
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testOversizedLinePreservesAcceptedPrefixFromSameChunk() {
        let buffer = CodexLineBuffer(maximumLineByteCount: 8)
        var accepted: [Data] = []

        XCTAssertThrowsError(try buffer.append(
            Data("ok\n123456789".utf8),
            onLine: { accepted.append($0) }
        )) { error in
            XCTAssertEqual(
                error as? CodexTransportError,
                .frameTooLarge(maximumBytes: 8, observedBytes: 9)
            )
        }
        XCTAssertEqual(accepted, [Data("ok".utf8)])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testInvalidUTF8LineIsPreservedByteForByte() throws {
        let buffer = CodexLineBuffer()
        let invalidFrame = Data([0x7B, 0xFF, 0x7D])

        XCTAssertEqual(
            try buffer.append(invalidFrame + Data([0x0A])),
            [invalidFrame]
        )
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testConsumerFailureIsTerminalForCurrentChunk() {
        let buffer = CodexLineBuffer()
        var accepted: [Data] = []
        let followingFrame = Data("must-not-deliver".utf8)
        let chunk = Data("reject\n".utf8) + followingFrame + Data([0x0A])

        XCTAssertThrowsError(try buffer.append(chunk) { frame in
            guard frame != Data("reject".utf8) else {
                throw LineBufferTestError.rejectedFrame
            }
            accepted.append(frame)
        }) { error in
            XCTAssertEqual(error as? LineBufferTestError, .rejectedFrame)
        }
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testDefaultInboundFrameLimitIsSixtyFourMiB() {
        XCTAssertEqual(
            CodexTransportLimits().maximumInboundFrameBytes,
            64 * 1_024 * 1_024
        )
    }
}

private enum LineBufferTestError: Error {
    case rejectedFrame
}
