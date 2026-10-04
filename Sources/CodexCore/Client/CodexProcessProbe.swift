import Darwin
import Foundation

/// Small read-only probes share bounded capture, deadlines, and cancellation.
/// Long-running transports and repository mutations have separate owners.
package enum CodexProcessProbe {
    package struct Result: Sendable {
        package let status: Int32
        package let output: String
    }

    package enum Failure: Error, CustomStringConvertible {
        case timedOut
        case outputLimitExceeded(Int)
        case readFailed(Int32)

        package var description: String {
            switch self {
            case .timedOut: "Subprocess probe timed out."
            case .outputLimitExceeded(let limit): "Subprocess probe exceeded its \(limit)-byte output limit."
            case .readFailed(let code): "Subprocess probe read failed (errno \(code))."
            }
        }
    }

    package static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: Duration = .seconds(3),
        maximumOutputBytes: Int = 64 * 1_024,
        checkpoint: () throws -> Void = {}
    ) throws -> Result {
        precondition(timeout > .zero && maximumOutputBytes > 0)
        try checkpoint()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        try process.run()
        try pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw Failure.readFailed(errno)
        }
        var data = Data()
        var observedExit = false
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            try checkpoint()
            guard clock.now < deadline else { throw Failure.timedOut }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= maximumOutputBytes - data.count else {
                    throw Failure.outputLimitExceeded(maximumOutputBytes)
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno != EAGAIN && errno != EWOULDBLOCK {
                throw Failure.readFailed(errno)
            }
            if !process.isRunning {
                // The child may have written its final bytes between read and exit.
                if !observedExit { observedExit = true; continue }
                return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
            }
            // Async callers dispatch this synchronous boundary to a worker queue.
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    package static func runAsync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: Duration = .seconds(3),
        maximumOutputBytes: Int = 64 * 1_024
    ) async throws -> Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try run(
                            executable: executable, arguments: arguments,
                            environment: environment, directory: directory,
                            timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                            checkpoint: cancellation.check
                        ))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }
}
