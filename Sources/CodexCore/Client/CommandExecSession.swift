import Foundation

public struct CodexCommandExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let raw: CodexJSONValue

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        raw: CodexJSONValue = .null
    ) {
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
            guard let exact = Int32(exactly: value) else {
                throw CodexSDKError.invalidResponse(method: "command/exec", value: jsonValue)
            }
            exitCode = exact
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

    init(response: CodexSchemaCommandExecResponse) throws {
        let raw = try CodexJSONValue(encoding: response)
        guard let exitCode = Int32(exactly: response.exitCode) else {
            throw CodexSDKError.invalidResponse(method: "command/exec", value: raw)
        }
        self.init(
            exitCode: exitCode,
            stdout: response.stdout,
            stderr: response.stderr,
            raw: raw
        )
    }
}

public enum CodexCommandExecSessionError: Error, Sendable, Equatable, LocalizedError {
    case missingProcessID
    case invalidTimeoutMilliseconds(Int64)
    case alreadyCompleted
    case outputBufferOverflow(maximumBufferedDeltaCount: Int)
    case completionEndedWithoutResult

    public var errorDescription: String? {
        switch self {
        case .missingProcessID:
            "A streaming command requires a nonempty caller-supplied processId."
        case .invalidTimeoutMilliseconds(let value):
            "timeoutMilliseconds \(value) is outside the platform Int range."
        case .alreadyCompleted:
            "The command operation has already completed."
        case .outputBufferOverflow(let maximumBufferedDeltaCount):
            "The command output consumer exceeded its \(maximumBufferedDeltaCount)-delta buffer."
        case .completionEndedWithoutResult:
            "The command completion channel ended without a result."
        }
    }
}

/// A session-backed streaming `command/exec` operation.
///
/// The handle consumes only its exact epoch/process output stream. It never
/// observes the legacy raw notification router or owns a transport connection.
public actor CodexCommandExecSession {
    public static let maximumBufferedOutputDeltaCount = 512

    public nonisolated let processID: String
    public nonisolated var processId: String { processID }
    public nonisolated let outputStream: AsyncStream<PTYDelta>
    public nonisolated let completionStream: AsyncThrowingStream<CodexCommandExecResult, Error>

    public private(set) var hasCompleted = false
    public private(set) var result: CodexCommandExecResult?

    private let session: CodexSession
    private let outputSubscription: CodexCommandOutputSubscription
    private let outputContinuation: AsyncStream<PTYDelta>.Continuation
    private let completionContinuation: AsyncThrowingStream<CodexCommandExecResult, Error>.Continuation

    private var requestTask: Task<Void, Never>?
    private var outputPumpTask: Task<Void, Never>?
    private var requestOutcome: Result<CodexCommandExecResult, Error>?
    private var routedOutputStreamEnded = false
    private var completionError: Error?

    init(
        processID: String,
        session: CodexSession,
        outputSubscription: CodexCommandOutputSubscription
    ) {
        self.processID = processID
        self.session = session
        self.outputSubscription = outputSubscription

        let outputPair = AsyncStream<PTYDelta>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedOutputDeltaCount)
        )
        self.outputStream = outputPair.stream
        self.outputContinuation = outputPair.continuation

        let completionPair = AsyncThrowingStream<CodexCommandExecResult, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.completionStream = completionPair.stream
        self.completionContinuation = completionPair.continuation
    }

    deinit {
        requestTask?.cancel()
        outputPumpTask?.cancel()
        outputContinuation.finish()
        completionContinuation.finish()
    }

    func start(_ params: CodexSchemaCommandExecParams) {
        precondition(requestTask == nil && outputPumpTask == nil)
        let subscription = outputSubscription
        let session = session

        outputPumpTask = Task { [weak self] in
            do {
                for try await value in subscription.deltas {
                    guard let delta = PTYDelta(
                        streamName: value.stream.rawValue,
                        base64Data: value.deltaBase64,
                        capReached: value.capReached
                    ) else {
                        continue
                    }
                    guard await self?.publish(delta) == true else {
                        await session.cancelCommandOutput(subscription.token)
                        await self?.outputPumpFailed(
                            CodexCommandExecSessionError.outputBufferOverflow(
                                maximumBufferedDeltaCount:
                                    Self.maximumBufferedOutputDeltaCount
                            )
                        )
                        return
                    }
                }
                await self?.outputPumpEnded()
            } catch CodexCommandOutputRouterError.bufferOverflow {
                await self?.outputPumpFailed(
                    CodexCommandExecSessionError.outputBufferOverflow(
                        maximumBufferedDeltaCount:
                            Self.maximumBufferedOutputDeltaCount
                    )
                )
            } catch {
                await self?.outputPumpFailed(error)
            }
        }

        requestTask = Task { [weak self] in
            do {
                let response = try await session.performCommandExec(params)
                let result = try CodexCommandExecResult(response: response)
                await self?.requestEnded(.success(result))
            } catch {
                // Pre-write cancellation/encoding failures have no response to
                // close the output stream. This is an idempotent no-op after a normal
                // response-side finish.
                await session.cancelCommandOutput(subscription.token)
                await self?.requestEnded(.failure(error))
            }
        }
    }

    public func write(data: Data, closeStdin: Bool = false) async throws {
        guard !hasCompleted else { throw CodexCommandExecSessionError.alreadyCompleted }
        _ = try await session.perform(CodexRequest.commandExecWrite(.init(
            closeStdin: closeStdin,
            deltaBase64: data.base64EncodedString(),
            processID: processID
        )))
    }

    public func closeStdin() async throws {
        guard !hasCompleted else { return }
        _ = try await session.perform(CodexRequest.commandExecWrite(.init(
            closeStdin: true,
            processID: processID
        )))
    }

    public func resize(rows: UInt16, cols: UInt16) async throws {
        guard !hasCompleted else { return }
        _ = try await session.perform(CodexRequest.commandExecResize(.init(
            processID: processID,
            size: .init(cols: Int(cols), rows: Int(rows))
        )))
    }

    public func terminate() async throws {
        guard !hasCompleted else { return }
        _ = try await session.perform(CodexRequest.commandExecTerminate(.init(
            processID: processID
        )))
    }

    public func wait() async throws -> CodexCommandExecResult {
        if let result { return result }
        if let completionError { throw completionError }

        for try await result in completionStream {
            return result
        }
        if let completionError { throw completionError }
        throw CodexCommandExecSessionError.completionEndedWithoutResult
    }
}

private extension CodexCommandExecSession {
    func publish(_ delta: PTYDelta) -> Bool {
        switch outputContinuation.yield(delta) {
        case .enqueued:
            true
        case .dropped, .terminated:
            false
        @unknown default:
            false
        }
    }

    func requestEnded(_ outcome: Result<CodexCommandExecResult, Error>) {
        requestOutcome = outcome
        finishIfReady()
    }

    func outputPumpEnded() {
        routedOutputStreamEnded = true
        finishIfReady()
    }

    func outputPumpFailed(_ error: Error) {
        guard !hasCompleted else { return }
        completionError = error
        routedOutputStreamEnded = true
        requestTask?.cancel()
        finishFailure(error)
    }

    func finishIfReady() {
        guard !hasCompleted, routedOutputStreamEnded, let requestOutcome else { return }
        switch requestOutcome {
        case .success(let result):
            hasCompleted = true
            self.result = result
            outputContinuation.finish()
            completionContinuation.yield(result)
            completionContinuation.finish()
            requestTask = nil
            outputPumpTask = nil
        case .failure(let error):
            finishFailure(error)
        }
    }

    func finishFailure(_ error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completionError = error
        outputContinuation.finish()
        completionContinuation.finish(throwing: error)
        requestTask = nil
        outputPumpTask = nil
    }
}

public extension CodexSession {
    /// Registers the exact output channel before scheduling the command request.
    func startCommandExec(
        _ supplied: CodexSchemaCommandExecParams
    ) async throws -> CodexCommandExecSession {
        guard let processID = supplied.processID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !processID.isEmpty else {
            throw CodexCommandExecSessionError.missingProcessID
        }

        var params = supplied
        params.processID = processID
        params.streamStdin = true
        params.streamStdoutStderr = true
        _ = try CodexJSONValue(encoding: params)

        let subscription = try registerCommandOutput(
            processID: processID,
            maximumDeltaCount: CodexCommandExecSession.maximumBufferedOutputDeltaCount
        )
        let handle = CodexCommandExecSession(
            processID: processID,
            session: self,
            outputSubscription: subscription
        )
        await handle.start(params)
        return handle
    }

    func performCommandExec(
        _ params: CodexSchemaCommandExecParams
    ) async throws -> CodexSchemaCommandExecResponse {
        let call = try await performCall(
            method: .commandExec,
            params: try CodexJSONValue(encoding: params)
        )
        return try call.value.decode(CodexSchemaCommandExecResponse.self)
    }
}

public extension Codex {
    func startCommandSession(
        _ params: CodexSchemaCommandExecParams
    ) async throws -> CodexCommandExecSession {
        try await session.startCommandExec(params)
    }

    func startCommandSession(
        _ command: [String],
        processID: String,
        cwd: String? = nil,
        environment: [String: String?]? = nil,
        initialSize: PTYSize? = nil,
        tty: Bool = true,
        timeoutMilliseconds: Int64? = nil,
        outputBytesCap: Int? = nil,
        disableTimeout: Bool = false,
        disableOutputCap: Bool = false
    ) async throws -> CodexCommandExecSession {
        let timeout: Int?
        if let timeoutMilliseconds {
            guard let exact = Int(exactly: timeoutMilliseconds) else {
                throw CodexCommandExecSessionError.invalidTimeoutMilliseconds(
                    timeoutMilliseconds
                )
            }
            timeout = exact
        } else {
            timeout = nil
        }
        return try await startCommandSession(CodexSchemaCommandExecParams(
            command: command,
            cwd: cwd,
            disableOutputCap: disableOutputCap ? true : nil,
            disableTimeout: disableTimeout ? true : nil,
            env: environment,
            outputBytesCap: outputBytesCap,
            processID: processID,
            size: initialSize.map {
                .init(cols: $0.cols, rows: $0.rows)
            },
            streamStdin: true,
            streamStdoutStderr: true,
            timeoutMs: timeout,
            tty: tty
        ))
    }
}
