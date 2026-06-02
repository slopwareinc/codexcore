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
    public let experimentalApi: Bool

    public init(
        codexBinaryPath: String? = nil,
        launchArgumentsOverride: [String]? = nil,
        configOverrides: [String] = [],
        cwd: String? = nil,
        environment: [String: String] = [:],
        clientName: String = "codex_swift_sdk",
        clientTitle: String = "Codex Swift SDK",
        clientVersion: String = "1.0.0",
        experimentalApi: Bool = true
    ) {
        self.codexBinaryPath = codexBinaryPath
        self.launchArgumentsOverride = launchArgumentsOverride
        self.configOverrides = configOverrides
        self.cwd = cwd
        self.environment = environment
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        self.experimentalApi = experimentalApi
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
    public let metadata: InitializeResponse

    private let client: CodexClient
    private let config: CodexConfig

    public convenience init(
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexServerRequestHandler? = nil
    ) async throws {
        let transport = try Self.makeDefaultTransport(config: config)
        let store = await CodexCoreStore()
        try await self.init(transport: transport, store: store, config: config, serverRequestHandler: serverRequestHandler)
    }

    public init(
        transport: any CodexTransport,
        store: CodexCoreStore,
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexServerRequestHandler? = nil
    ) async throws {
        let client = CodexClient(transport: transport, store: store, serverRequestHandler: serverRequestHandler)
        let metadata: InitializeResponse

        do {
            metadata = try await client.connect(
                clientName: config.clientName,
                clientTitle: config.clientTitle,
                clientVersion: config.clientVersion,
                experimentalApi: config.experimentalApi
            )
        } catch {
            await client.disconnect()
            throw error
        }

        self.store = store
        self.client = client
        self.config = config
        self.metadata = metadata
    }

    public func close() async {
        await client.disconnect()
    }

    public func notifications() -> AsyncStream<CodexNotification> {
        client.notifications()
    }

    public func loginNotifications(loginId: String) -> AsyncStream<CodexNotification> {
        client.loginNotifications(loginId: loginId)
    }

    public func loginAPIKey(_ apiKey: String) async throws {
        _ = try await client.accountLoginStart(.apiKey(apiKey))
    }

    public func loginApiKey(_ apiKey: String) async throws {
        try await loginAPIKey(apiKey)
    }

    public func account(refreshToken: Bool = false) async throws -> GetAccountResponse {
        try await client.accountRead(GetAccountParams(refreshToken: refreshToken))
    }

    public func logout() async throws {
        _ = try await client.accountLogout()
    }

    public func threadStart(
        approvalMode: ApprovalMode = .autoReview,
        baseInstructions: String? = nil,
        config threadConfig: [String: CodexJSONValue]? = nil,
        cwd: String? = nil,
        developerInstructions: String? = nil,
        ephemeral: Bool? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        personality: Personality? = nil,
        sandbox: Sandbox? = nil,
        serviceName: String? = nil,
        serviceTier: String? = nil,
        sessionStartSource: ThreadStartSource? = nil,
        threadSource: ThreadSource? = nil
    ) async throws -> CodexThread {
        let approvals = approvalMode.settings
        let response = try await client.threadStart(ThreadStartParams(
            approvalPolicy: approvals.approvalPolicy,
            approvalsReviewer: approvals.approvalsReviewer,
            baseInstructions: baseInstructions,
            config: threadConfig,
            cwd: cwd ?? config.cwd,
            developerInstructions: developerInstructions,
            ephemeral: ephemeral,
            model: model,
            modelProvider: modelProvider,
            personality: personality,
            sandbox: sandbox?.threadMode,
            serviceName: serviceName,
            serviceTier: serviceTier,
            sessionStartSource: sessionStartSource,
            threadSource: threadSource
        ))
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadResume(
        _ threadId: String,
        approvalMode: ApprovalMode? = nil,
        baseInstructions: String? = nil,
        config threadConfig: [String: CodexJSONValue]? = nil,
        cwd: String? = nil,
        developerInstructions: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        personality: Personality? = nil,
        sandbox: Sandbox? = nil,
        serviceTier: String? = nil
    ) async throws -> CodexThread {
        let approvals = approvalMode?.settings ?? ApprovalSettings()
        var params = ThreadResumeParams(threadId: threadId)
        params.approvalPolicy = approvals.approvalPolicy
        params.approvalsReviewer = approvals.approvalsReviewer
        params.baseInstructions = baseInstructions
        params.config = threadConfig
        params.cwd = cwd
        params.developerInstructions = developerInstructions
        params.model = model
        params.modelProvider = modelProvider
        params.personality = personality
        params.sandbox = sandbox?.threadMode
        params.serviceTier = serviceTier

        let response = try await client.threadResume(threadId: threadId, params: params)
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadList(
        archived: Bool? = nil,
        cursor: String? = nil,
        cwd: ThreadListCwdFilter? = nil,
        limit: Int? = nil,
        modelProviders: [String]? = nil,
        searchTerm: String? = nil,
        sortDirection: SortDirection? = nil,
        sortKey: ThreadSortKey? = nil,
        sourceKinds: [ThreadSourceKind]? = nil,
        useStateDbOnly: Bool? = nil
    ) async throws -> ThreadListResponse {
        try await client.threadList(ThreadListParams(
            archived: archived,
            cursor: cursor,
            cwd: cwd,
            limit: limit,
            modelProviders: modelProviders,
            searchTerm: searchTerm,
            sortDirection: sortDirection,
            sortKey: sortKey,
            sourceKinds: sourceKinds,
            useStateDbOnly: useStateDbOnly
        ))
    }

    public func threadListRaw(params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await client.request(method: CodexAppServerClientMethod.threadList.rawValue, params: params)
    }

    public func threadFork(
        _ threadId: String,
        approvalMode: ApprovalMode? = nil,
        baseInstructions: String? = nil,
        config threadConfig: [String: CodexJSONValue]? = nil,
        cwd: String? = nil,
        developerInstructions: String? = nil,
        ephemeral: Bool? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        sandbox: Sandbox? = nil,
        serviceTier: String? = nil,
        threadSource: ThreadSource? = nil
    ) async throws -> CodexThread {
        let approvals = approvalMode?.settings ?? ApprovalSettings()
        var params = ThreadForkParams(threadId: threadId)
        params.approvalPolicy = approvals.approvalPolicy
        params.approvalsReviewer = approvals.approvalsReviewer
        params.baseInstructions = baseInstructions
        params.config = threadConfig
        params.cwd = cwd
        params.developerInstructions = developerInstructions
        params.ephemeral = ephemeral
        params.model = model
        params.modelProvider = modelProvider
        params.sandbox = sandbox?.threadMode
        params.serviceTier = serviceTier
        params.threadSource = threadSource

        let response = try await client.threadFork(threadId: threadId, params: params)
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadArchive(_ threadId: String) async throws -> ThreadArchiveResponse {
        try await client.threadArchive(threadId: threadId)
    }

    public func threadUnarchive(_ threadId: String) async throws -> CodexThread {
        let response = try await client.threadUnarchive(threadId: threadId)
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func models(includeHidden: Bool = false) async throws -> ModelListResponse {
        try await client.modelList(includeHidden: includeHidden)
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
        try await turn([CodexInput.text(input)], params: additionalParams)
    }

    public func turn(
        _ input: [CodexInput],
        approvalMode: ApprovalMode? = nil,
        cwd: String? = nil,
        effort: ReasoningEffort? = nil,
        model: String? = nil,
        outputSchema: CodexJSONValue? = nil,
        personality: Personality? = nil,
        sandbox: Sandbox? = nil,
        serviceTier: String? = nil,
        summary: ReasoningSummary? = nil,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> CodexTurnHandle {
        let approvals = approvalMode?.settings ?? ApprovalSettings()
        var params = TurnStartParams(threadId: id, input: input)
        params.approvalPolicy = approvals.approvalPolicy
        params.approvalsReviewer = approvals.approvalsReviewer
        params.cwd = cwd
        params.effort = effort
        params.model = model
        params.outputSchema = outputSchema
        params.personality = personality
        params.sandboxPolicy = sandbox?.turnPolicy
        params.serviceTier = serviceTier
        params.summary = summary

        var payload = try CodexJSONValue(encoding: params).objectValue ?? [:]
        for (key, value) in additionalParams {
            payload[key] = value
        }
        let turnId = try await client.startTurn(
            threadId: id,
            input: input.map(\.jsonValue),
            additionalParams: payload.filter { $0.key != "threadId" && $0.key != "input" }
        )
        return CodexTurnHandle(client: client, store: store, threadId: id, id: turnId)
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

    public func run(
        _ input: [CodexInput],
        timeout: TimeInterval = 300,
        approvalMode: ApprovalMode? = nil,
        cwd: String? = nil,
        effort: ReasoningEffort? = nil,
        model: String? = nil,
        outputSchema: CodexJSONValue? = nil,
        personality: Personality? = nil,
        sandbox: Sandbox? = nil,
        serviceTier: String? = nil,
        summary: ReasoningSummary? = nil
    ) async throws -> CodexTurnResult {
        let handle = try await turn(
            input,
            approvalMode: approvalMode,
            cwd: cwd,
            effort: effort,
            model: model,
            outputSchema: outputSchema,
            personality: personality,
            sandbox: sandbox,
            serviceTier: serviceTier,
            summary: summary
        )
        return try await handle.run(timeout: timeout)
    }

    public func read(includeTurns: Bool = false) async throws -> ThreadReadResponse {
        try await client.threadRead(threadId: id, includeTurns: includeTurns)
    }

    public func setName(_ name: String) async throws -> ThreadSetNameResponse {
        try await client.threadSetName(threadId: id, name: name)
    }

    public func compact() async throws -> ThreadCompactStartResponse {
        try await client.threadCompact(threadId: id)
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
        try await steer([CodexInput.text(input)])
    }

    public func steer(_ input: [CodexInput]) async throws -> CodexJSONValue {
        let response = try await client.turnSteer(threadId: threadId, expectedTurnId: id, input: input)
        return try CodexJSONValue(encoding: response)
    }

    public func steer(input: [CodexWireInputItem]) async throws -> CodexJSONValue {
        try await client.steerTurn(threadId: threadId, expectedTurnId: id, input: input.map(\.jsonValue))
    }

    public func interrupt() async throws -> CodexJSONValue {
        try await client.interruptTurn(threadId: threadId, turnId: id)
    }

    public func stream() -> AsyncStream<CodexNotification> {
        client.turnNotifications(turnId: id)
    }

    public func textDeltas() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                for await notification in stream() {
                    if case .agentMessageDelta(let delta) = notification.payload {
                        continuation.yield(delta.delta)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
