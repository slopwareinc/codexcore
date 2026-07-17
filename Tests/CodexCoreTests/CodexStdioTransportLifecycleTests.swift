import Darwin
import XCTest
@testable import CodexCore

final class CodexStdioTransportLifecycleTests: XCTestCase {
    func testCloseForceTerminatesAndReapsChildBeforeAllowingReopen() async throws {
        let transport = CodexStdioTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; echo $$; while IFS= read -r line; do if [ \"$line\" = exit ]; then echo exit-ack; exit 0; fi; done; while :; do sleep 0.05; done",
            ]
        )

        let (firstPID, _) = try await openAndReadPID(transport)
        await transport.close()

        XCTAssertEqual(
            Darwin.kill(firstPID, 0),
            -1,
            "close() returned while its child process was still alive"
        )

        let (secondPID, secondIterator) = try await openAndReadPID(transport)
        XCTAssertNotEqual(secondPID, firstPID)
        try await transport.write(Data("exit".utf8))

        var iterator = secondIterator
        let acknowledgement = try await iterator.next()
        XCTAssertEqual(acknowledgement, Data("exit-ack".utf8))
        await transport.close()

        XCTAssertEqual(
            Darwin.kill(secondPID, 0),
            -1,
            "the reopened transport also must reap its child before close() returns"
        )
    }

    private func openAndReadPID(
        _ transport: CodexStdioTransport
    ) async throws -> (pid_t, AsyncThrowingStream<Data, Error>.Iterator) {
        let stream = try await transport.open()
        var iterator = stream.makeAsyncIterator()
        let nextFrame = try await iterator.next()
        let frame = try XCTUnwrap(nextFrame)
        let text = String(decoding: frame, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (try XCTUnwrap(pid_t(text)), iterator)
    }
}
