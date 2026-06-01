import Foundation

// MARK: - PTY Models

public struct PTYDelta: Sendable {
    public enum StreamKind: String, Codable, Sendable {
        case stdout
        case stderr
    }

    public let stream: StreamKind
    public let data: Data
    public let capReached: Bool
}

// MARK: - CodexProcessSession

public final class CodexProcessSession: @unchecked Sendable {
    public let processHandle: String
    private let connection: CodexConnection

    private let outputContinuation: AsyncStream<PTYDelta>.Continuation
    public let outputStream: AsyncStream<PTYDelta>

    private let exitContinuation: AsyncStream<Int32>.Continuation
    public let exitStream: AsyncStream<Int32>

    public private(set) var hasExited = false
    public private(set) var exitCode: Int32?

    public init(processHandle: String, connection: CodexConnection) {
        self.processHandle = processHandle
        self.connection = connection

        let (outputStream, outputContinuation) = AsyncStream<PTYDelta>.makeStream()
        self.outputStream = outputStream
        self.outputContinuation = outputContinuation

        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        self.exitStream = exitStream
        self.exitContinuation = exitContinuation
    }

    /// Write raw binary stdin bytes into the active PTY shell.
    public func write(data: Data) async throws {
        guard !hasExited else {
            throw CodexTransportError.connectionClosed
        }

        let base64 = data.base64EncodedString()
        let params: [String: CodexJSONValue] = [
            "processHandle": .string(processHandle),
            "deltaBase64": .string(base64),
            "closeStdin": .bool(false)
        ]

        _ = try await connection.request(method: "process/writeStdin", params: params)
    }

    /// Resize the active PTY dimensions (winsize rows and cols).
    public func resize(rows: UInt16, cols: UInt16) async throws {
        guard !hasExited else { return }

        let params: [String: CodexJSONValue] = [
            "processHandle": .string(processHandle),
            "size": .dictionary([
                "rows": .int(Int(rows)),
                "cols": .int(Int(cols))
            ])
        ]

        _ = try await connection.request(method: "process/resizePty", params: params)
    }

    /// Terminate/kill the process and clean up the active process group.
    public func kill() async throws {
        guard !hasExited else { return }

        let params: [String: CodexJSONValue] = [
            "processHandle": .string(processHandle)
        ]

        _ = try await connection.request(method: "process/kill", params: params)
    }

    // MARK: - Internal Packet Routing Hooks

    internal func receiveOutput(streamName: String, base64Data: String, capReached: Bool) {
        guard let data = Data(base64Encoded: base64Data) else { return }
        let streamKind = PTYDelta.StreamKind(rawValue: streamName) ?? .stdout

        let delta = PTYDelta(stream: streamKind, data: data, capReached: capReached)
        outputContinuation.yield(delta)
    }

    internal func handleExit(exitCode: Int32) {
        guard !hasExited else { return }
        hasExited = true
        self.exitCode = exitCode

        outputContinuation.finish()

        exitContinuation.yield(exitCode)
        exitContinuation.finish()
    }
}
