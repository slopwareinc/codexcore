import Foundation

// MARK: - Transport Interface

public protocol CodexTransport: Actor, Sendable {
    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws

    func send(_ payload: [String: CodexJSONValue]) async throws
    func stop() async

    var isConnected: Bool { get }
}

public enum CodexTransportError: Error, Sendable, LocalizedError {
    case processNotRunning
    case writeFailed
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Codex transport process is not running."
        case .writeFailed:
            return "Failed to encode transport payload as UTF-8."
        case .connectionClosed:
            return "Codex transport connection is closed."
        }
    }
}

final class CodexLineBuffer: @unchecked Sendable {
    private var data = Data()
    private var lineStart: Data.Index = 0
    private var scanIndex: Data.Index = 0

    var bufferedByteCount: Int {
        data.distance(from: lineStart, to: data.endIndex)
    }

    func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }

        data.append(chunk)
        var lines: [String] = []

        while scanIndex < data.endIndex {
            if data[scanIndex] == 0x0A {
                let lineData = data.subdata(in: lineStart..<scanIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
                scanIndex = data.index(after: scanIndex)
                lineStart = scanIndex
            } else {
                scanIndex = data.index(after: scanIndex)
            }
        }

        compactIfNeeded()
        return lines
    }

    private func compactIfNeeded() {
        guard lineStart > data.startIndex else { return }

        if lineStart == data.endIndex {
            data.removeAll(keepingCapacity: true)
            lineStart = data.startIndex
            scanIndex = data.startIndex
            return
        }

        let consumedByteCount = data.distance(from: data.startIndex, to: lineStart)
        guard consumedByteCount >= 64 * 1_024 || consumedByteCount > data.count / 2 else {
            return
        }

        let scanOffset = data.distance(from: lineStart, to: scanIndex)
        data.removeSubrange(data.startIndex..<lineStart)
        lineStart = data.startIndex
        scanIndex = data.index(lineStart, offsetBy: scanOffset)
    }
}

// MARK: - Subprocess Stdio Transport

public actor CodexStdioTransport: CodexTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    public private(set) var isConnected: Bool = false

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    public func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard !isConnected else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            env[k] = v
        }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let stdinHandle = stdin.fileHandleForWriting
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        self.process = process
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.isConnected = true

        // --- stdout: FileHandle.readabilityHandler runs on a GCD serial queue,
        //     NOT on Swift's cooperative pool. No blocking read() on the pool.
        let stdoutBuffer = CodexLineBuffer()
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                Task { [weak self] in
                    guard let self else { return }
                    if await self.markUnexpectedClose() {
                        onError(CodexTransportError.connectionClosed)
                    }
                }
                return
            }
            for line in stdoutBuffer.append(chunk) {
                onMessage(line)
            }
        }

        // --- stderr: similarly dispatched by GCD
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if let text = String(data: chunk, encoding: .utf8) {
                print("[Codex app-server stderr]: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    public func send(_ payload: [String: CodexJSONValue]) async throws {
        guard let handle = stdinHandle else {
            throw CodexTransportError.processNotRunning
        }
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    public func stop() async {
        guard isConnected else { return }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        isConnected = false
    }

    private func markUnexpectedClose() -> Bool {
        guard isConnected else { return false }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        isConnected = false
        return true
    }
}

// MARK: - Native WebSocket Transport (Tauri-Ready)

public actor CodexWebSocketTransport: CodexTransport {
    private let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    public private(set) var isConnected: Bool = false

    public init(url: URL) {
        self.url = url
    }

    public func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard !isConnected else { return }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true

        // Start receiving messages
        listenForMessages(task: task, onMessage: onMessage, onError: onError)
    }

    nonisolated private func listenForMessages(
        task: URLSessionWebSocketTask,
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                guard await self.isConnected else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        onMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            onMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.listenForMessages(task: task, onMessage: onMessage, onError: onError)

                case .failure(let error):
                    onError(error)
                    await self.stop()
                }
            }
        }
    }

    public func send(_ payload: [String: CodexJSONValue]) async throws {
        guard isConnected, let task = webSocketTask else {
            throw CodexTransportError.connectionClosed
        }
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexTransportError.writeFailed
        }
        try await task.send(.string(text))
    }

    public func stop() async {
        guard isConnected else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }
}
