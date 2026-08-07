import Dispatch
import Darwin
import Foundation

// MARK: - Transport Interface

/// Ordered, frame-oriented transport interface used by the canonical session.
///
/// One `open()` call represents one physical connection. The returned stream
/// yields each complete JSON-RPC frame exactly once in wire order and terminates
/// only after every preceding frame has been yielded. `write(_:)` performs one
/// write attempt; transports never retain or replay frames across connections.
public protocol CodexFrameTransport: Actor, Sendable {
    func open() async throws -> AsyncThrowingStream<Data, Error>
    func write(_ frame: Data) async throws
    func close() async
}

public enum CodexTransportError: Error, Sendable, Equatable, LocalizedError {
    case connectionAlreadyOpen
    case processNotRunning
    case writeFailed
    case connectionClosed(stderr: String?)
    case receiveBufferOverflow
    case frameTooLarge(maximumBytes: Int, observedBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .connectionAlreadyOpen:
            return "Codex transport already has an open physical connection."
        case .processNotRunning:
            return "Codex transport process is not running."
        case .writeFailed:
            return "Failed to encode transport payload as UTF-8."
        case .connectionClosed(let stderr):
            guard let stderr, !stderr.isEmpty else {
                return "Codex transport connection is closed."
            }
            return "Codex transport connection is closed. Stderr tail: \(stderr)"
        case .receiveBufferOverflow:
            return "Codex transport receive buffer overflowed. The connection was closed without silently dropping JSON-RPC frames."
        case .frameTooLarge(let maximumBytes, let observedBytes):
            return "Codex transport received a JSON-RPC frame larger than its \(maximumBytes)-byte limit (observed at least \(observedBytes) bytes)."
        }
    }
}

public struct CodexTransportLimits: Sendable, Hashable {
    public let maximumInboundFrameBytes: Int
    public let maximumBufferedInboundFrames: Int
    public let maximumCapturedStderrBytes: Int

    public init(
        maximumInboundFrameBytes: Int = 64 * 1_024 * 1_024,
        maximumBufferedInboundFrames: Int = 4_096,
        maximumCapturedStderrBytes: Int = 16 * 1_024
    ) {
        precondition(maximumInboundFrameBytes > 0, "Inbound frame limit must be positive")
        precondition(
            maximumBufferedInboundFrames > 0,
            "Inbound frame buffer limit must be positive"
        )
        precondition(
            maximumCapturedStderrBytes > 0,
            "Captured stderr limit must be positive"
        )
        self.maximumInboundFrameBytes = maximumInboundFrameBytes
        self.maximumBufferedInboundFrames = maximumBufferedInboundFrames
        self.maximumCapturedStderrBytes = maximumCapturedStderrBytes
    }
}

final class CodexLineBuffer: @unchecked Sendable {
    private let maximumLineByteCount: Int
    private var data = Data()
    private var lineStart: Data.Index = 0
    private var scanIndex: Data.Index = 0

    init(maximumLineByteCount: Int = CodexTransportLimits().maximumInboundFrameBytes) {
        precondition(maximumLineByteCount > 0, "Line buffer limit must be positive")
        self.maximumLineByteCount = maximumLineByteCount
    }

    var bufferedByteCount: Int {
        data.distance(from: lineStart, to: data.endIndex)
    }

    func append(_ chunk: Data) throws -> [Data] {
        var frames: [Data] = []
        try append(chunk) { frames.append($0) }
        return frames
    }

    /// Emits each accepted prefix line before reporting a later oversized line
    /// from the same chunk.
    func append(
        _ chunk: Data,
        onLine: (Data) throws -> Void
    ) throws {
        guard !chunk.isEmpty else { return }

        data.append(chunk)

        while scanIndex < data.endIndex {
            if data[scanIndex] == 0x0A {
                let lineByteCount = data.distance(from: lineStart, to: scanIndex)
                guard lineByteCount <= maximumLineByteCount else {
                    reset()
                    throw CodexTransportError.frameTooLarge(
                        maximumBytes: maximumLineByteCount,
                        observedBytes: lineByteCount
                    )
                }
                let lineData = data.subdata(in: lineStart..<scanIndex)
                do {
                    try onLine(lineData)
                } catch {
                    reset()
                    throw error
                }
                scanIndex = data.index(after: scanIndex)
                lineStart = scanIndex
            } else {
                scanIndex = data.index(after: scanIndex)
                let pendingByteCount = data.distance(from: lineStart, to: scanIndex)
                guard pendingByteCount <= maximumLineByteCount else {
                    reset()
                    throw CodexTransportError.frameTooLarge(
                        maximumBytes: maximumLineByteCount,
                        observedBytes: pendingByteCount
                    )
                }
            }
        }

        compactIfNeeded()
    }

    private func reset() {
        data.removeAll(keepingCapacity: false)
        lineStart = data.startIndex
        scanIndex = data.startIndex
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

/// Thread-safe bounded tail capture for a subprocess's stderr pipe.
///
/// File-handle readability callbacks run outside the transport actor, while a
/// terminal-error callback may snapshot the same bytes from an actor task. The
/// lock keeps those two paths race-free without retaining unbounded diagnostics.
private final class CodexStderrRing: @unchecked Sendable {
    private let maximumByteCount: Int
    private let lock = NSLock()
    private var data = Data()

    init(maximumByteCount: Int) {
        precondition(maximumByteCount > 0, "Captured stderr limit must be positive")
        self.maximumByteCount = maximumByteCount
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        lock.withLock {
            if chunk.count >= maximumByteCount {
                data = Data(chunk.suffix(maximumByteCount))
                return
            }

            data.append(chunk)
            guard data.count > maximumByteCount else { return }
            data = Data(data.suffix(maximumByteCount))
        }
    }

    func snapshot() -> String? {
        lock.withLock {
            guard !data.isEmpty else { return nil }
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

// MARK: - Subprocess Stdio Transport

public actor CodexStdioTransport: CodexFrameTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL?
    private let limits: CodexTransportLimits
    private let prepareForLaunch: @Sendable () throws -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stderrCapture: CodexStderrRing?

    private var isConnected = false
    private var terminationTask: Task<Void, Never>?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        limits: CodexTransportLimits = .init(),
        prepareForLaunch: @escaping @Sendable () throws -> Void = {}
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.limits = limits
        self.prepareForLaunch = prepareForLaunch
    }

    public func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard !isConnected, process == nil, terminationTask == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(limits.maximumBufferedInboundFrames)
        )

        do {
            try await startReading(
                onFrame: { frame in
                    if case .dropped = pair.continuation.yield(frame) {
                        throw CodexTransportError.receiveBufferOverflow
                    }
                },
                onError: { error in
                    pair.continuation.finish(throwing: error)
                }
            )
            return pair.stream
        } catch {
            pair.continuation.finish(throwing: error)
            throw error
        }
    }

    private func startReading(
        onFrame: @escaping @Sendable (Data) throws -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard !isConnected, process == nil, terminationTask == nil else {
            throw CodexTransportError.connectionAlreadyOpen
        }

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

        // Repeat home validation synchronously at the narrowest local launch
        // seam. CodexSession also prepares once per connection attempt so
        // custom transports receive the same invariant.
        try await Self.runOffActorExecutor(prepareForLaunch)
        try process.run()

        let stdinHandle = stdin.fileHandleForWriting
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        self.process = process
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        let stderrCapture = CodexStderrRing(
            maximumByteCount: limits.maximumCapturedStderrBytes
        )
        self.stderrCapture = stderrCapture
        self.isConnected = true

        // --- stdout: FileHandle.readabilityHandler runs on a GCD serial queue,
        //     NOT on Swift's cooperative pool. No blocking read() on the pool.
        let stdoutBuffer = CodexLineBuffer(
            maximumLineByteCount: limits.maximumInboundFrameBytes
        )
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                Task { [weak self] in
                    guard let self else { return }
                    if await self.stopAfterUnexpectedClose() {
                        onError(CodexTransportError.connectionClosed(
                            stderr: stderrCapture.snapshot()
                        ))
                    }
                }
                return
            }
            do {
                try stdoutBuffer.append(chunk, onLine: onFrame)
            } catch {
                handle.readabilityHandler = nil
                Task { [weak self] in
                    await self?.stop()
                    onError(error)
                }
            }
        }

        // --- stderr: similarly dispatched by GCD, retaining only a bounded tail
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrCapture.append(chunk)
        }
    }

    public func write(_ frame: Data) async throws {
        guard let handle = stdinHandle else {
            throw CodexTransportError.processNotRunning
        }
        var data = frame
        data.append(0x0A)
        try await Self.write(data, to: handle)
    }

    public func close() async {
        await stop()
    }

    private func stop() async {
        if let terminationTask, let process {
            await terminationTask.value
            await drainStderr()
            finishStopping(process)
            return
        }
        guard isConnected, let process else { return }

        stdoutHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        isConnected = false

        if process.isRunning {
            process.terminate()
        }
        let terminationTask = Task {
            await Self.waitUntilExit(
                process,
                forceAfter: .seconds(2)
            )
        }
        self.terminationTask = terminationTask
        await terminationTask.value
        await drainStderr()
        finishStopping(process)
    }

    private func stopAfterUnexpectedClose() async -> Bool {
        guard isConnected, terminationTask == nil else { return false }
        await stop()
        return true
    }

    private func drainStderr() async {
        guard let handle = stderrHandle, let stderrCapture else { return }
        self.stderrHandle = nil
        handle.readabilityHandler = nil
        await Self.drain(handle, into: stderrCapture)
    }

    private func finishStopping(_ process: Process) {
        guard self.process === process else { return }
        terminationTask = nil
        self.process = nil
        stdoutHandle = nil
        stderrHandle = nil
        stderrCapture = nil
    }

    /// `prepareForLaunch` may perform filesystem work and a version probe. Run
    /// that synchronous closure on a dispatch worker before returning to the
    /// actor, so launch preparation cannot occupy Swift's cooperative pool.
    nonisolated private static func runOffActorExecutor(
        _ operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// FileHandle writes can block when the subprocess stops draining stdin.
    /// Dispatch the syscall so a full pipe never monopolizes the actor's
    /// executor and a concurrent `close()` can continue to make progress.
    nonisolated private static func write(_ data: Data, to handle: FileHandle) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try handle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The process has been reaped before this is called, so the pipe reaches
    /// EOF and the loop cannot block indefinitely. It still runs off the actor
    /// because `availableData` is a blocking FileHandle API.
    /// Collects whatever the child already wrote to stderr without ever blocking.
    ///
    /// The previous implementation looped on `FileHandle.availableData`, which
    /// returns empty only at EOF and otherwise blocks. Clearing
    /// `readabilityHandler` does not cancel an invocation already dispatched on
    /// GCD's queue, so that handler and this drain could read the same
    /// descriptor concurrently; whichever one lost the race then waited forever
    /// for an EOF the other had already consumed. `close()` never returned, and
    /// every caller behind it — app shutdown included — hung with it. It
    /// reproduced as an intermittent CI timeout rather than a consistent
    /// failure, which is exactly what a race looks like.
    ///
    /// Reading the descriptor directly in non-blocking mode cannot deadlock. The
    /// child is already reaped by the time this runs, so everything it wrote is
    /// sitting in the pipe buffer, and the loop stops at EOF, `EAGAIN`, or an
    /// error. A concurrent handler is harmless: the ring is lock-guarded, and a
    /// racing reader now sees `EAGAIN` instead of blocking.
    nonisolated private static func drain(
        _ handle: FileHandle,
        into stderrCapture: CodexStderrRing
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let descriptor = handle.fileDescriptor
                let existingFlags = fcntl(descriptor, F_GETFL)
                if existingFlags != -1 {
                    _ = fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK)
                }

                var buffer = [UInt8](repeating: 0, count: 4_096)
                readLoop: while true {
                    let bytesRead = buffer.withUnsafeMutableBytes { raw in
                        read(descriptor, raw.baseAddress, raw.count)
                    }
                    if bytesRead > 0 {
                        stderrCapture.append(Data(buffer[0..<bytesRead]))
                        continue
                    }
                    if bytesRead == 0 { break readLoop }
                    if errno == EINTR { continue }
                    // EAGAIN/EWOULDBLOCK means nothing further is buffered.
                    break readLoop
                }
                continuation.resume()
            }
        }
    }

    /// `Process.waitUntilExit()` blocks its caller. Run it on a dispatch worker
    /// so transport shutdown does not occupy Swift's cooperative executor. A
    /// child that ignores SIGTERM is killed after a bounded grace period, and
    /// `close()` still does not return until that exact child has been reaped.
    ///
    /// Three details here are load-bearing. Each was observed hanging `close()`
    /// -- and therefore app shutdown -- against a child that ignores SIGTERM:
    ///
    /// - `Process.waitUntilExit()` is not used. A sampled hang showed a thread
    ///   parked inside it while the child had already exited and been reaped,
    ///   with no descendant left in the process table: once Foundation misses
    ///   the termination it waits for one that can never arrive, and SIGKILL
    ///   cannot help something already dead. `terminationHandler` plus a
    ///   semaphore observes exit without that failure mode.
    /// - Escalation must not consult `Process.isRunning`. Foundation can report
    ///   it `false` while termination is still pending, so a guard on it skipped
    ///   the kill and left the child running. Reaping is tracked explicitly,
    ///   which also makes the kill safe from PID reuse: an unreaped PID is still
    ///   this child.
    /// - The timer must not be `Task.sleep`. That schedules on the cooperative
    ///   pool, which other work in the same process can saturate, delaying the
    ///   escalation past any useful deadline. A dispatch timer is independent of
    ///   the pool.
    ///
    /// The wait is bounded, so shutdown makes progress even if every one of
    /// those mechanisms fails.
    nonisolated private static func waitUntilExit(
        _ process: Process,
        forceAfter gracePeriod: Duration
    ) async {
        let processID = process.processIdentifier
        let hasBeenReaped = CodexTransportFlag()
        let finished = DispatchSemaphore(value: 0)
        let graceSeconds = Double(gracePeriod.components.seconds)
            + Double(gracePeriod.components.attoseconds) / 1e18

        process.terminationHandler = { _ in
            hasBeenReaped.value = true
            finished.signal()
        }
        // The child can exit before the handler is installed, in which case
        // Foundation never invokes it.
        if !process.isRunning {
            hasBeenReaped.value = true
            finished.signal()
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) {
            guard !hasBeenReaped.value else { return }
            _ = Darwin.kill(processID, SIGKILL)
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Bounded on purpose. SIGKILL has already been sent by this
                // deadline, so the child is gone; waiting longer would only
                // reproduce the unbounded block this replaced.
                _ = finished.wait(timeout: .now() + graceSeconds + 5)
                continuation.resume()
            }
        }
    }
}

/// Minimal lock-guarded boolean shared between a dispatch timer and the thread
/// blocked in `waitUntilExit()`.
private final class CodexTransportFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

// MARK: - Native WebSocket Transport (Tauri-Ready)

public actor CodexWebSocketTransport: CodexFrameTransport {
    private let url: URL
    private let limits: CodexTransportLimits
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false

    public init(url: URL, limits: CodexTransportLimits = .init()) {
        self.url = url
        self.limits = limits
    }

    public func open() async throws -> AsyncThrowingStream<Data, Error> {
        guard !isConnected else {
            throw CodexTransportError.connectionAlreadyOpen
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(limits.maximumBufferedInboundFrames)
        )

        do {
            try startReceiving(
                onFrame: { [weak self] frame in
                    if case .dropped = pair.continuation.yield(frame) {
                        pair.continuation.finish(
                            throwing: CodexTransportError.receiveBufferOverflow
                        )
                        Task { await self?.stop() }
                    }
                },
                onError: { error in
                    pair.continuation.finish(throwing: error)
                }
            )
            return pair.stream
        } catch {
            pair.continuation.finish(throwing: error)
            throw error
        }
    }

    private func startReceiving(
        onFrame: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        guard !isConnected else {
            throw CodexTransportError.connectionAlreadyOpen
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        isConnected = true

        // Start receiving messages
        listenForMessages(
            task: task,
            maximumInboundFrameBytes: limits.maximumInboundFrameBytes,
            onFrame: onFrame,
            onError: onError
        )
    }

    nonisolated private func listenForMessages(
        task: URLSessionWebSocketTask,
        maximumInboundFrameBytes: Int,
        onFrame: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                guard await self.isConnected else { return }

                switch result {
                case .success(let message):
                    let frame: Data
                    switch message {
                    case .string(let text):
                        frame = Data(text.utf8)
                    case .data(let data):
                        frame = data
                    @unknown default:
                        return
                    }
                    guard frame.count <= maximumInboundFrameBytes else {
                        onError(CodexTransportError.frameTooLarge(
                            maximumBytes: maximumInboundFrameBytes,
                            observedBytes: frame.count
                        ))
                        Task { [weak self] in await self?.stop() }
                        return
                    }
                    onFrame(frame)
                    self.listenForMessages(
                        task: task,
                        maximumInboundFrameBytes: maximumInboundFrameBytes,
                        onFrame: onFrame,
                        onError: onError
                    )

                case .failure(let error):
                    onError(error)
                    await self.stop()
                }
            }
        }
    }

    public func write(_ frame: Data) async throws {
        guard isConnected, let task = webSocketTask else {
            throw CodexTransportError.connectionClosed(stderr: nil)
        }
        guard let text = String(data: frame, encoding: .utf8) else {
            throw CodexTransportError.writeFailed
        }
        try await task.send(.string(text))
    }

    public func close() async {
        await stop()
    }

    private func stop() async {
        guard isConnected else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }
}
