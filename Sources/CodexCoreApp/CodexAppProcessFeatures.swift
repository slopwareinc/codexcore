import Foundation
import Observation
import CodexCore

struct CodexAppCommandOperation: Sendable {
    let output: AsyncStream<PTYDelta>
    let completion: @Sendable () async throws -> CodexCommandExecResult
    let write: @Sendable (Data, Bool) async throws -> Void
    let resize: @Sendable (UInt16, UInt16) async throws -> Void
    let terminate: @Sendable () async throws -> Void

    init(_ session: CodexCommandExecSession) {
        output = session.outputStream
        completion = { try await session.wait() }
        write = { try await session.write(data: $0, closeStdin: $1) }
        resize = { try await session.resize(rows: $0, cols: $1) }
        terminate = { try await session.terminate() }
    }
}

protocol CodexAppProcessRuntimeProviding: CodexAppRuntimeProviding {
    func processEvents(handle: String) async throws -> AsyncThrowingStream<CodexProcessEvent, Error>
    func command(_ params: CodexSchemaCommandExecParams) async throws -> CodexAppCommandOperation
}

extension CodexAppRuntimeProvider: CodexAppProcessRuntimeProviding {
    func processEvents(handle: String) async throws -> AsyncThrowingStream<CodexProcessEvent, Error> {
        try await codex.observeProcessEvents(processHandle: handle)
    }
    func command(_ params: CodexSchemaCommandExecParams) async throws -> CodexAppCommandOperation {
        .init(try await codex.startCommandSession(params))
    }
}

@MainActor @Observable
final class CodexAppProcessFeatures {
    enum Mode: String, CaseIterable, Identifiable {
        case process = "Runtime process", command = "Sandboxed command", shell = "Chat shell command"
        var id: String { rawValue }
    }
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var stdout = ""
    private(set) var stderr = ""
    private(set) var exitCode: Int?
    private(set) var error: String?
    private(set) var capReached = false
    @ObservationIgnored private var provider: (any CodexAppProcessRuntimeProviding)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var processHandle: String?
    @ObservationIgnored private var commandOperation: CodexAppCommandOperation?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var stdoutBytes = Data()
    @ObservationIgnored private var stderrBytes = Data()
    static let outputLimit = 128 * 1_024
    var contextVersion: Int { generation }

    func bind(_ provider: (any CodexAppProcessRuntimeProviding)?) async {
        generation += 1
        let expected = generation
        let previousProvider = self.provider
        let previousHandle = processHandle
        let previousCommand = commandOperation
        outputTask?.cancel(); completionTask?.cancel()
        outputTask = nil; completionTask = nil; processHandle = nil; commandOperation = nil; operationID = nil
        self.provider = provider
        isRunning = false; isStarting = false; stdout = ""; stderr = ""; error = nil; exitCode = nil
        stdoutBytes = Data(); stderrBytes = Data(); capReached = false
        do {
            if let previousCommand { try await previousCommand.terminate() }
            if let previousHandle, let previousProvider {
                _ = try await previousProvider.perform(CodexRequest.processKill(.init(processHandle: previousHandle)))
            }
        } catch { if generation == expected { self.error = "Previous process cleanup failed: \(error.localizedDescription)" } }
    }

    func start(mode: Mode, arguments: [String], cwd: String, tty: Bool, threadID: String?) async {
        guard !isRunning, !isStarting, let provider else { return }
        do {
            let cwd = try CodexAppFileFeatures.absolutePath(cwd)
            guard !arguments.isEmpty, !arguments[0].isEmpty, arguments.allSatisfy({ !$0.contains("\0") }) else {
                throw CodexAppFeatureError.invalidInput("Enter an executable followed by one argument per line.")
            }
            let expected = generation
            let id = UUID(); operationID = id
            let handle = "codexcore-process-" + id.uuidString
            isStarting = true; isRunning = true; exitCode = nil; error = nil; capReached = false
            stdoutBytes = Data(); stderrBytes = Data(); stdout = ""; stderr = ""
            defer { if generation == expected, operationID == id { isStarting = false } }
            do {
                switch mode {
                case .process:
                    let events = try await provider.processEvents(handle: handle)
                    guard generation == expected, operationID == id else { return }
                    processHandle = handle
                    outputTask = Task { [weak self] in
                        do {
                            for try await event in events {
                                guard let self, self.generation == expected, self.operationID == id else { return }
                                switch event {
                                case .output(let delta):
                                    guard let data = Data(base64Encoded: delta.deltaBase64) else {
                                        throw CodexAppFeatureError.invalidInput("Codex sent invalid process output.")
                                    }
                                    self.append(data, stderr: delta.stream.rawValue == "stderr", capped: delta.capReached)
                                case .exited(let result):
                                    self.exitCode = result.exitCode
                                    self.capReached = self.capReached || result.stdoutCapReached || result.stderrCapReached
                                    self.isRunning = false; self.processHandle = nil
                                    return
                                }
                            }
                            guard let self, self.generation == expected, self.operationID == id, self.isRunning else { return }
                            self.error = "Process observation ended before exit. Stop it or reconnect to reconcile."
                        } catch is CancellationError { }
                        catch { if let self, self.generation == expected, self.operationID == id { self.error = error.localizedDescription } }
                    }
                    _ = try await provider.perform(CodexRequest.processSpawn(.init(
                        command: arguments, cwd: .init(.string(cwd)), outputBytesCap: Self.outputLimit,
                        processHandle: handle, size: tty ? .init(cols: 100, rows: 30) : nil,
                        streamStdin: true, streamStdoutStderr: true, timeoutMs: 300_000, tty: tty
                    )))
                    if generation != expected || operationID != id {
                        _ = try? await provider.perform(CodexRequest.processKill(.init(processHandle: handle)))
                    }
                case .command:
                    let operation = try await provider.command(.init(
                        command: arguments, cwd: cwd, outputBytesCap: Self.outputLimit, processID: handle,
                        size: tty ? .init(cols: 100, rows: 30) : nil, streamStdin: true,
                        streamStdoutStderr: true, timeoutMs: 300_000, tty: tty
                    ))
                    guard generation == expected, operationID == id else { try? await operation.terminate(); return }
                    commandOperation = operation
                    outputTask = Task { [weak self] in
                        for await delta in operation.output {
                            guard let self, self.generation == expected, self.operationID == id else { return }
                            self.append(delta.data, stderr: delta.stream == .stderr, capped: delta.capReached)
                        }
                    }
                    completionTask = Task { [weak self] in
                        do {
                            let result = try await operation.completion()
                            guard let self, self.generation == expected, self.operationID == id else { return }
                            self.exitCode = Int(result.exitCode); self.isRunning = false; self.commandOperation = nil
                        } catch {
                            guard let self, self.generation == expected, self.operationID == id else { return }
                            self.error = error.localizedDescription
                            // Retain the operation for explicit termination on ambiguous failure.
                        }
                    }
                case .shell:
                    guard let threadID else { throw CodexAppFeatureError.invalidInput("Select a chat before running a chat shell command.") }
                    guard arguments.count == 1 else { throw CodexAppFeatureError.invalidInput("Enter one shell command in chat shell mode.") }
                    _ = try await provider.perform(CodexRequest.threadShellCommand(.init(command: arguments[0], threadID: threadID, timeoutMs: 300_000)))
                    guard generation == expected, operationID == id else { return }
                    isRunning = false
                }
            } catch {
                guard generation == expected, operationID == id else { return }
                self.error = error.localizedDescription
                if processHandle == nil, commandOperation == nil { isRunning = false }
            }
        } catch { self.error = error.localizedDescription }
    }

    func write(_ input: String, closeStdin: Bool) async {
        guard let provider, isRunning else { return }
        let expected = generation, id = operationID
        do {
            if let commandOperation { try await commandOperation.write(Data(input.utf8), closeStdin) }
            else if let processHandle {
                _ = try await provider.perform(CodexRequest.processWriteStdin(.init(
                    closeStdin: closeStdin, deltaBase64: Data(input.utf8).base64EncodedString(), processHandle: processHandle
                )))
            }
        } catch { if generation == expected, operationID == id { self.error = error.localizedDescription } }
    }

    func resize(rows: Int, cols: Int) async {
        guard let provider, isRunning else { return }
        guard let rows16 = UInt16(exactly: rows), rows16 > 0, let cols16 = UInt16(exactly: cols), cols16 > 0 else {
            error = "Rows and columns must be between 1 and 65535."; return
        }
        let expected = generation, id = operationID
        do {
            if let commandOperation { try await commandOperation.resize(rows16, cols16) }
            else if let processHandle {
                _ = try await provider.perform(CodexRequest.processResizePTY(.init(processHandle: processHandle, size: .init(cols: cols, rows: rows))))
            }
        } catch { if generation == expected, operationID == id { self.error = error.localizedDescription } }
    }

    func stop() async {
        guard let provider else { return }
        let expected = generation, id = operationID
        do {
            if let commandOperation { try await commandOperation.terminate() }
            else if let processHandle { _ = try await provider.perform(CodexRequest.processKill(.init(processHandle: processHandle))) }
            guard generation == expected, operationID == id else { return }
            isRunning = false; isStarting = false; processHandle = nil; commandOperation = nil
            operationID = nil
            outputTask?.cancel(); completionTask?.cancel()
        } catch { if generation == expected, operationID == id { self.error = error.localizedDescription } }
    }

    private func append(_ data: Data, stderr: Bool, capped: Bool) {
        capReached = capReached || capped
        if stderr { appendBounded(data, to: &stderrBytes); self.stderr = String(decoding: stderrBytes, as: UTF8.self) }
        else { appendBounded(data, to: &stdoutBytes); stdout = String(decoding: stdoutBytes, as: UTF8.self) }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data) {
        buffer.append(data)
        if buffer.count > Self.outputLimit {
            buffer.removeFirst(buffer.count - Self.outputLimit)
            capReached = true
        }
    }
}
