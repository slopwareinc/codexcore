import Darwin
import XCTest
@testable import CodexCore

final class CodexStdioTransportLifecycleTests: XCTestCase {
    func testUnexpectedEOFIncludesBoundedStderrTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTransportStderr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-stderr")
        try "#!/bin/sh\nprintf 'discarded-tail!' >&2\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let transport = CodexStdioTransport(
            executableURL: executable,
            limits: .init(maximumCapturedStderrBytes: 5)
        )
        let stream = try await transport.open()
        var iterator = stream.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            XCTFail("The child should terminate without a frame")
        } catch let error as CodexTransportError {
            guard case .connectionClosed(let stderr) = error else {
                return XCTFail("Unexpected transport error: \(error)")
            }
            XCTAssertEqual(stderr, "tail!")
            XCTAssertTrue(error.localizedDescription.contains("tail!"))
        }

        await transport.close()
    }

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
