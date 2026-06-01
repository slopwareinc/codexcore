import Foundation

public struct CodexConfig: Sendable {
    public let codexBinaryPath: String?
    public let launchArgumentsOverride: [String]?
    public let configOverrides: [String]
    public let cwd: String?
    public let environment: [String: String]
    public let clientName: String
    public let clientTitle: String
    public let clientVersion: String

    public init(
        codexBinaryPath: String? = nil,
        launchArgumentsOverride: [String]? = nil,
        configOverrides: [String] = [],
        cwd: String? = nil,
        environment: [String: String] = [:],
        clientName: String = "codex_swift_sdk",
        clientTitle: String = "Codex Swift SDK",
        clientVersion: String = "1.0.0"
    ) {
        self.codexBinaryPath = codexBinaryPath
        self.launchArgumentsOverride = launchArgumentsOverride
        self.configOverrides = configOverrides
        self.cwd = cwd
        self.environment = environment
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
    }
}

public enum CodexSDKError: Error, Sendable, CustomStringConvertible {
    case runtimeNotFound
    case invalidRuntimePath(String)
    case invalidResponse(method: String, value: CodexJSONValue)
    case turnTimedOut(turnId: String)
    case turnFailed(CodexTurnResult)

    public var description: String {
        switch self {
        case .runtimeNotFound:
            return "Codex runtime not found. Set CodexConfig.codexBinaryPath to a valid codex binary."
        case .invalidRuntimePath(let path):
            return "Codex runtime not found at \(path)."
        case .invalidResponse(let method, let value):
            return "Invalid \(method) response: \(value)"
        case .turnTimedOut(let turnId):
            return "Turn \(turnId) did not complete before the timeout."
        case .turnFailed(let result):
            return result.error ?? "Turn \(result.id) failed."
        }
    }
}

public struct CodexTurnResult: Sendable, Equatable {
    public let id: String
    public let status: CodexTurnStatus
    public let error: String?
    public let startedAt: Date
    public let completedAt: Date?
    public let duration: TimeInterval?
    public let finalResponse: String?
    public let items: [CodexTimelineItem]
}

public final class Codex: @unchecked Sendable {
    public let store: CodexCoreStore

    private let client: CodexClient
    private let config: CodexConfig

    public convenience init(config: CodexConfig = CodexConfig()) async throws {
        let transport = try Self.makeDefaultTransport(config: config)
        let store = await CodexCoreStore()
        try await self.init(transport: transport, store: store, config: config)
    }

    public init(
        transport: any CodexTransport,
        store: CodexCoreStore,
        config: CodexConfig = CodexConfig()
    ) async throws {
        self.store = store
        self.client = CodexClient(transport: transport, store: store)
        self.config = config

        do {
            try await client.connect(
                clientName: config.clientName,
                clientTitle: config.clientTitle,
                clientVersion: config.clientVersion
            )
        } catch {
            await client.disconnect()
            throw error
        }
    }

    public func close() async {
        await client.disconnect()
    }

    public func threadStart(
        cwd: String? = nil,
        model: String? = nil,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexThread {
        var params = additionalParams
        if let cwd {
            params["cwd"] = .string(cwd)
        } else if let cwd = config.cwd {
            params["cwd"] = .string(cwd)
        }
        if let model {
            params["model"] = .string(model)
        }

        let threadId = try await client.startThread(params: params)
        return CodexThread(client: client, store: store, id: threadId)
    }

    public func threadResume(
        _ threadId: String,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexThread {
        var params = additionalParams
        params["threadId"] = .string(threadId)
        let response = try await client.request(method: "thread/resume", params: params)
        let resumedId = try Self.extractThreadId(from: response, method: "thread/resume") ?? threadId
        await MainActor.run {
            store.dispatch(.threadStarted(threadId: resumedId, name: nil, status: "idle"))
        }
        return CodexThread(client: client, store: store, id: resumedId)
    }

    public func threadList(params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await client.request(method: "thread/list", params: params)
    }

    public func models(includeHidden: Bool = false) async throws -> CodexJSONValue {
        try await client.request(method: "model/list", params: ["includeHidden": .bool(includeHidden)])
    }

    public func execCommand(
        _ command: [String],
        cwd: String? = nil,
        environment: [String: String?]? = nil,
        timeoutMilliseconds: Int64? = nil,
        outputBytesCap: Int? = nil,
        disableTimeout: Bool = false,
        disableOutputCap: Bool = false
    ) async throws -> CodexCommandExecResult {
        try await client.execCommand(
            command: command,
            cwd: cwd,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds,
            outputBytesCap: outputBytesCap,
            disableTimeout: disableTimeout,
            disableOutputCap: disableOutputCap
        )
    }

    public func startCommandSession(
        _ command: [String],
        cwd: String? = nil,
        environment: [String: String?]? = nil,
        initialSize: PTYSize? = nil,
        tty: Bool = true,
        timeoutMilliseconds: Int64? = nil,
        outputBytesCap: Int? = nil,
        disableTimeout: Bool = false,
        disableOutputCap: Bool = false
    ) async throws -> CodexCommandExecSession {
        try await client.startCommandSession(
            command: command,
            cwd: cwd,
            environment: environment,
            initialSize: initialSize,
            tty: tty,
            timeoutMilliseconds: timeoutMilliseconds,
            outputBytesCap: outputBytesCap,
            disableTimeout: disableTimeout,
            disableOutputCap: disableOutputCap
        )
    }

    public func rawRequest(method: String, params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await client.request(method: method, params: params)
    }

    private static func makeDefaultTransport(config: CodexConfig) throws -> CodexStdioTransport {
        let binaryURL = try resolveCodexBinary(config: config)
        var arguments: [String]
        if let override = config.launchArgumentsOverride {
            arguments = override
        } else {
            arguments = []
            for override in config.configOverrides {
                arguments.append("--config")
                arguments.append(override)
            }
            arguments.append(contentsOf: ["app-server", "--listen", "stdio://"])
        }

        return CodexStdioTransport(
            executableURL: binaryURL,
            arguments: arguments,
            environment: config.environment,
            currentDirectoryURL: config.cwd.map { URL(fileURLWithPath: $0) }
        )
    }

    private static func resolveCodexBinary(config: CodexConfig) throws -> URL {
        let fileManager = FileManager.default

        if let path = config.codexBinaryPath {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        let appBundlePath = "/Applications/Codex.app/Contents/Resources/codex"
        if fileManager.isExecutableFile(atPath: appBundlePath) {
            return URL(fileURLWithPath: appBundlePath)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw CodexSDKError.runtimeNotFound
    }

    fileprivate static func extractThreadId(from response: CodexJSONValue, method: String) throws -> String? {
        guard case .dictionary(let dict) = response else {
            throw CodexSDKError.invalidResponse(method: method, value: response)
        }
        if case .dictionary(let thread)? = dict["thread"], case .string(let id)? = thread["id"] {
            return id
        }
        return nil
    }
}

public final class CodexThread: Identifiable, @unchecked Sendable {
    public let id: String

    private let client: CodexClient
    private let store: CodexCoreStore

    fileprivate init(client: CodexClient, store: CodexCoreStore, id: String) {
        self.client = client
        self.store = store
        self.id = id
    }

    public func turn(
        _ input: String,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexTurnHandle {
        try await turn(input: [.text(input)], params: additionalParams)
    }

    public func turn(
        input: [CodexWireInputItem],
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexTurnHandle {
        let turnId = try await client.startTurn(
            threadId: id,
            input: input.map(\.jsonValue),
            additionalParams: additionalParams
        )
        return CodexTurnHandle(client: client, store: store, threadId: id, id: turnId)
    }

    public func run(
        _ input: String,
        timeout: TimeInterval = 300,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexTurnResult {
        let handle = try await turn(input, params: additionalParams)
        return try await handle.run(timeout: timeout)
    }

    public func read(includeTurns: Bool = false) async throws -> CodexJSONValue {
        try await client.request(
            method: "thread/read",
            params: ["threadId": .string(id), "includeTurns": .bool(includeTurns)]
        )
    }

    public func setName(_ name: String) async throws -> CodexJSONValue {
        try await client.request(method: "thread/name/set", params: ["threadId": .string(id), "name": .string(name)])
    }

    public func compact() async throws -> CodexJSONValue {
        try await client.request(method: "thread/compact/start", params: ["threadId": .string(id)])
    }
}

public final class CodexTurnHandle: Identifiable, @unchecked Sendable {
    public let threadId: String
    public let id: String

    private let client: CodexClient
    private let store: CodexCoreStore

    fileprivate init(client: CodexClient, store: CodexCoreStore, threadId: String, id: String) {
        self.client = client
        self.store = store
        self.threadId = threadId
        self.id = id
    }

    public func steer(_ input: String) async throws -> CodexJSONValue {
        try await steer(input: [.text(input)])
    }

    public func steer(input: [CodexWireInputItem]) async throws -> CodexJSONValue {
        try await client.steerTurn(threadId: threadId, expectedTurnId: id, input: input.map(\.jsonValue))
    }

    public func interrupt() async throws -> CodexJSONValue {
        try await client.interruptTurn(threadId: threadId, turnId: id)
    }

    public func snapshots(pollInterval: Duration = .milliseconds(200)) -> AsyncThrowingStream<CodexTurnSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastSnapshot: CodexTurnSnapshot?
                while !Task.isCancelled {
                    if let snapshot = await self.currentSnapshot(), snapshot != lastSnapshot {
                        continuation.yield(snapshot)
                        lastSnapshot = snapshot
                        if snapshot.status != .running {
                            continuation.finish()
                            return
                        }
                    }
                    try await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run(timeout: TimeInterval = 300) async throws -> CodexTurnResult {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let snapshot = await currentSnapshot(), snapshot.status != .running {
                let result = makeResult(from: snapshot)
                if snapshot.status == .failed {
                    throw CodexSDKError.turnFailed(result)
                }
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        throw CodexSDKError.turnTimedOut(turnId: id)
    }

    private func currentSnapshot() async -> CodexTurnSnapshot? {
        await MainActor.run {
            store.activeThread?.turns.first(where: { $0.id == id })
        }
    }

    private func makeResult(from snapshot: CodexTurnSnapshot) -> CodexTurnResult {
        let duration = snapshot.completedAt.map { $0.timeIntervalSince(snapshot.startedAt) }
        return CodexTurnResult(
            id: snapshot.id,
            status: snapshot.status,
            error: snapshot.error,
            startedAt: snapshot.startedAt,
            completedAt: snapshot.completedAt,
            duration: duration,
            finalResponse: snapshot.items.finalAssistantResponse,
            items: snapshot.items
        )
    }
}

public enum CodexWireInputItem: Sendable, Equatable {
    case text(String)
    case raw(CodexJSONValue)

    public var jsonValue: CodexJSONValue {
        switch self {
        case .text(let text):
            return .dictionary(["type": .string("text"), "text": .string(text)])
        case .raw(let value):
            return value
        }
    }
}

private extension Array where Element == CodexTimelineItem {
    var finalAssistantResponse: String? {
        for item in reversed() {
            if case .assistantMessage(_, let text, _, _) = item, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
