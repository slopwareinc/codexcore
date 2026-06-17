import Foundation

public struct CodexCommandExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let raw: CodexJSONValue

    public init(exitCode: Int32, stdout: String, stderr: String, raw: CodexJSONValue = .null) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.raw = raw
    }

    public init(jsonValue: CodexJSONValue) throws {
        guard case .dictionary(let dict) = jsonValue else {
            throw CodexSDKError.invalidResponse(method: "command/exec", value: jsonValue)
        }

        let exitCode: Int32
        switch dict["exitCode"] {
        case .int(let value):
            exitCode = Int32(value)
        case .string(let value):
            guard let parsed = Int32(value) else {
                throw CodexSDKError.invalidResponse(method: "command/exec", value: jsonValue)
            }
            exitCode = parsed
        default:
            throw CodexSDKError.invalidResponse(method: "command/exec", value: jsonValue)
        }

        guard case .string(let stdout)? = dict["stdout"],
              case .string(let stderr)? = dict["stderr"] else {
            throw CodexSDKError.invalidResponse(method: "command/exec", value: jsonValue)
        }

        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.raw = jsonValue
    }
}

public final class CodexCommandExecSession: @unchecked Sendable {
    public let processId: String

    private let connection: CodexConnection
    private let outputContinuation: AsyncStream<PTYDelta>.Continuation
    private let completionContinuation: AsyncThrowingStream<CodexCommandExecResult, Error>.Continuation

    public let outputStream: AsyncStream<PTYDelta>
    public let completionStream: AsyncThrowingStream<CodexCommandExecResult, Error>

    public private(set) var hasCompleted = false
    public private(set) var result: CodexCommandExecResult?

    public init(processId: String, connection: CodexConnection) {
        self.processId = processId
        self.connection = connection

        let (outputStream, outputContinuation) = AsyncStream<PTYDelta>.makeStream()
        self.outputStream = outputStream
        self.outputContinuation = outputContinuation

        let (completionStream, completionContinuation) = AsyncThrowingStream<CodexCommandExecResult, Error>.makeStream()
        self.completionStream = completionStream
        self.completionContinuation = completionContinuation
    }

    public func write(data: Data, closeStdin: Bool = false) async throws {
        guard !hasCompleted else {
            throw CodexTransportError.connectionClosed
        }

        _ = try await connection.request(
            method: CodexAppServerClientMethod.commandExecWrite.rawValue,
            params: [
                "processId": .string(processId),
                "deltaBase64": .string(data.base64EncodedString()),
                "closeStdin": .bool(closeStdin)
            ]
        )
    }

    public func closeStdin() async throws {
        guard !hasCompleted else { return }

        _ = try await connection.request(
            method: CodexAppServerClientMethod.commandExecWrite.rawValue,
            params: [
                "processId": .string(processId),
                "closeStdin": .bool(true)
            ]
        )
    }

    public func resize(rows: UInt16, cols: UInt16) async throws {
        guard !hasCompleted else { return }

        _ = try await connection.request(
            method: CodexAppServerClientMethod.commandExecResize.rawValue,
            params: [
                "processId": .string(processId),
                "size": .dictionary([
                    "rows": .int(Int(rows)),
                    "cols": .int(Int(cols))
                ])
            ]
        )
    }

    public func terminate() async throws {
        guard !hasCompleted else { return }

        _ = try await connection.request(
            method: CodexAppServerClientMethod.commandExecTerminate.rawValue,
            params: ["processId": .string(processId)]
        )
    }

    public func wait() async throws -> CodexCommandExecResult {
        if let result { return result }

        for try await result in completionStream {
            return result
        }

        throw CodexConnectionError.closed
    }

    internal func receiveOutput(streamName: String, base64Data: String, capReached: Bool) {
        guard let delta = PTYDelta(streamName: streamName, base64Data: base64Data, capReached: capReached) else { return }
        outputContinuation.yield(delta)
    }

    internal func complete(_ result: CodexCommandExecResult) {
        guard !hasCompleted else { return }
        hasCompleted = true
        self.result = result
        outputContinuation.finish()
        completionContinuation.yield(result)
        completionContinuation.finish()
    }

    internal func fail(_ error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        outputContinuation.finish()
        completionContinuation.finish(throwing: error)
    }
}
