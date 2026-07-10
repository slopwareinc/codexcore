import Foundation

public func defaultCodexHome() -> String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
}

public struct CodexConfig: Sendable {
    public let codexBinaryPath: String?
    public let launchArgumentsOverride: [String]?
    public let configOverrides: [String]
    public let cwd: String?
    public let environment: [String: String]
    public let clientName: String
    public let clientTitle: String
    public let clientVersion: String
    public let experimentalAPI: Bool
    public let initializeCapabilities: InitializeCapabilities?
    /// How escalated approval/user-input server requests are answered when no
    /// custom `serverRequestHandler` is installed. `.autoApprove` preserves the
    /// historic behavior; interactive apps should use `.ask` and resolve via
    /// `Codex.respondToApproval(id:decision:)`.
    public let approvalPolicy: CodexApprovalPolicy

    public init(
        codexBinaryPath: String? = nil,
        launchArgumentsOverride: [String]? = nil,
        configOverrides: [String] = [],
        cwd: String? = nil,
        environment: [String: String] = [:],
        clientName: String = "codex_swift_sdk",
        clientTitle: String = "Codex Swift SDK",
        clientVersion: String = "1.0.0",
        experimentalAPI: Bool = true,
        approvalPolicy: CodexApprovalPolicy = .autoApprove,
        initializeCapabilities: InitializeCapabilities? = nil
    ) {
        self.codexBinaryPath = codexBinaryPath
        self.launchArgumentsOverride = launchArgumentsOverride
        self.configOverrides = configOverrides
        self.cwd = cwd
        var resolvedEnvironment = environment
        if resolvedEnvironment["CODEX_HOME"]?.isEmpty ?? true {
            resolvedEnvironment["CODEX_HOME"] = defaultCodexHome()
        }
        self.environment = resolvedEnvironment
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        self.experimentalAPI = experimentalAPI
        self.approvalPolicy = approvalPolicy
        self.initializeCapabilities = initializeCapabilities
    }
}

public enum CodexSDKError: CodexError, Sendable, CustomStringConvertible, LocalizedError {
    case runtimeNotFound
    case invalidRuntimePath(String)
    case invalidResponse(method: String, value: CodexJSONValue)
    case turnTimedOut(turnId: String)
    case turnFailed(CodexTurnResult)
    case loginStreamEnded(loginId: String)
    case turnStreamEnded(turnId: String)

    public var description: String {
        switch self {
        case .runtimeNotFound:
            return "Codex runtime not found. Set CodexConfig.codexBinaryPath, CODEX_BINARY, or CODEX_APP_BUNDLE; install codex on PATH; or install Codex.app."
        case .invalidRuntimePath(let path):
            return "Codex runtime not found at \(path)."
        case .invalidResponse(let method, let value):
            return "Invalid \(method) response: \(value)"
        case .turnTimedOut(let turnId):
            return "Turn \(turnId) did not complete before the timeout."
        case .turnFailed(let result):
            return result.error ?? "Turn \(result.id) failed."
        case .loginStreamEnded(let loginId):
            return "Login \(loginId) completed stream ended before a completion notification."
        case .turnStreamEnded(let turnId):
            return "Turn \(turnId) stream ended before a completion notification."
        }
    }

    public var errorDescription: String? { description }
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
    public let usage: ThreadTokenUsage?
}

public struct CodexThreadResumeResult: Sendable {
    public let thread: CodexThread
    public let response: CodexSchemaThreadResumeResponse

    public init(thread: CodexThread, response: CodexSchemaThreadResumeResponse) {
        self.thread = thread
        self.response = response
    }

    public func rawResponse() throws -> CodexJSONValue {
        try CodexJSONValue(encoding: response)
    }
}

public final class Codex: @unchecked Sendable {
    @MainActor public let store: CodexCoreStore
    public let metadata: InitializeResponse

    internal let client: CodexClient
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
        let client = CodexClient(
            transport: transport,
            store: store,
            serverRequestHandler: serverRequestHandler,
            approvalPolicy: config.approvalPolicy
        )
        let metadata: InitializeResponse

        do {
            metadata = try await client.connect(
                clientName: config.clientName,
                clientTitle: config.clientTitle,
                clientVersion: config.clientVersion,
                experimentalAPI: config.experimentalAPI,
                capabilities: config.initializeCapabilities
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

    public func loginChatGPT(codexStreamlinedLogin: Bool? = nil) async throws -> ChatGPTLoginHandle {
        let response = try await client.accountLoginStart(.chatgpt(codexStreamlinedLogin: codexStreamlinedLogin))
        guard case .chatgpt(let loginId, let authUrl) = response else {
            throw CodexSDKError.invalidResponse(method: CodexAppServerClientMethod.accountLoginStart.rawValue, value: response.jsonValue)
        }
        return ChatGPTLoginHandle(client: client, loginId: loginId, authUrl: authUrl)
    }

    public func loginChatGPTDeviceCode() async throws -> DeviceCodeLoginHandle {
        let response = try await client.accountLoginStart(.chatgptDeviceCode)
        guard case .chatgptDeviceCode(let loginId, let verificationUrl, let userCode) = response else {
            throw CodexSDKError.invalidResponse(method: CodexAppServerClientMethod.accountLoginStart.rawValue, value: response.jsonValue)
        }
        return DeviceCodeLoginHandle(client: client, loginId: loginId, verificationUrl: verificationUrl, userCode: userCode)
    }

    public func loginChatGPTAuthTokens(
        accessToken: String,
        chatGPTAccountID: String,
        chatGPTPlanType: String? = nil
    ) async throws {
        _ = try await client.accountLoginStart(.chatgptAuthTokens(
            accessToken: accessToken,
            chatgptAccountId: chatGPTAccountID,
            chatgptPlanType: chatGPTPlanType
        ))
    }

    public func account(refreshToken: Bool = false) async throws -> GetAccountResponse {
        try await client.accountRead(GetAccountParams(refreshToken: refreshToken))
    }

    public func rateLimits() async throws -> CodexSchemaGetAccountRateLimitsResponse {
        try await client.accountRateLimitsRead()
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
        dynamicTools: [CodexDynamicToolSpec]? = nil,
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
            dynamicTools: dynamicTools,
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
        let params = makeThreadResumeParams(
            threadId,
            approvalMode: approvalMode,
            baseInstructions: baseInstructions,
            config: threadConfig,
            cwd: cwd,
            developerInstructions: developerInstructions,
            model: model,
            modelProvider: modelProvider,
            personality: personality,
            sandbox: sandbox,
            serviceTier: serviceTier
        )
        let response = try await client.threadResume(threadId: threadId, params: params)
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadResumeWithHistory(
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
        serviceTier: String? = nil,
        activateInStore: Bool = true
    ) async throws -> CodexThreadResumeResult {
        let params = makeThreadResumeParams(
            threadId,
            approvalMode: approvalMode,
            baseInstructions: baseInstructions,
            config: threadConfig,
            cwd: cwd,
            developerInstructions: developerInstructions,
            model: model,
            modelProvider: modelProvider,
            personality: personality,
            sandbox: sandbox,
            serviceTier: serviceTier
        )
        let response = try await client.threadResumeSchema(
            threadId: threadId,
            params: params,
            activateThread: activateInStore
        )
        let thread = CodexThread(client: client, store: store, id: response.thread.id)
        return CodexThreadResumeResult(thread: thread, response: response)
    }

    public func threadHandle(id threadId: String) -> CodexThread {
        CodexThread(client: client, store: store, id: threadId)
    }

    private func makeThreadResumeParams(
        _ threadId: String,
        approvalMode: ApprovalMode?,
        baseInstructions: String?,
        config threadConfig: [String: CodexJSONValue]?,
        cwd: String?,
        developerInstructions: String?,
        model: String?,
        modelProvider: String?,
        personality: Personality?,
        sandbox: Sandbox?,
        serviceTier: String?
    ) -> ThreadResumeParams {
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
        return params
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
        useStateDBOnly: Bool? = nil,
        ancestorThreadId: String? = nil,
        parentThreadId: String? = nil
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
            useStateDBOnly: useStateDBOnly,
            ancestorThreadId: ancestorThreadId,
            parentThreadId: parentThreadId
        ))
    }

    public func threadListSchema(_ params: CodexSchemaThreadListParams = CodexSchemaThreadListParams()) async throws -> CodexSchemaThreadListResponse {
        try await client.threadListSchema(params)
    }

    public func threadItemsList(
        threadId: String,
        turnId: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil,
        sortDirection: CodexSchemaSortDirection? = nil
    ) async throws -> CodexSchemaThreadItemsListResponse {
        try await client.threadItemsList(
            threadId: threadId,
            turnId: turnId,
            cursor: cursor,
            limit: limit,
            sortDirection: sortDirection
        )
    }

    public func environmentInfo(environmentId: String) async throws -> CodexSchemaEnvironmentInfoResponse {
        try await client.environmentInfo(environmentId: environmentId)
    }

    public func threadReadSchema(_ threadId: String, includeTurns: Bool = false) async throws -> CodexSchemaThreadReadResponse {
        try await client.threadReadSchema(threadId: threadId, includeTurns: includeTurns)
    }

    public func threadSearch(
        searchTerm: String,
        limit: Int? = nil,
        cursor: String? = nil,
        archived: Bool? = false,
        sortDirection: CodexSchemaSortDirection? = .desc,
        sortKey: CodexSchemaThreadSortKey? = .updatedAt,
        sourceKinds: [CodexSchemaThreadSourceKind]? = nil
    ) async throws -> CodexSchemaThreadSearchResponse {
        try await client.threadSearch(CodexSchemaThreadSearchParams(
            archived: archived,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm,
            sortDirection: sortDirection,
            sortKey: sortKey,
            sourceKinds: sourceKinds
        ))
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
        threadSource: ThreadSource? = nil,
        activateInStore: Bool = true
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

        let response = try await client.threadFork(
            threadId: threadId,
            params: params,
            activateThread: activateInStore
        )
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadArchive(_ threadId: String) async throws -> ThreadArchiveResponse {
        try await client.threadArchive(threadId: threadId)
    }

    public func threadUnarchive(_ threadId: String) async throws -> CodexThread {
        let response = try await client.threadUnarchive(threadId: threadId)
        return CodexThread(client: client, store: store, id: response.thread.id)
    }

    public func threadGoalSet(
        _ threadId: String,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int? = nil
    ) async throws -> ThreadGoalSetResponse {
        try await client.threadGoalSet(
            threadId: threadId,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        )
    }

    public func threadGoalGet(_ threadId: String) async throws -> ThreadGoalGetResponse {
        try await client.threadGoalGet(threadId: threadId)
    }

    public func threadGoalClear(_ threadId: String) async throws -> ThreadGoalClearResponse {
        try await client.threadGoalClear(threadId: threadId)
    }

    public func models(includeHidden: Bool = false) async throws -> ModelListResponse {
        try await client.modelList(includeHidden: includeHidden)
    }

    public func startReview(_ params: CodexSchemaReviewStartParams) async throws -> CodexSchemaReviewStartResponse {
        try await client.reviewStart(params)
    }

    public func startReview(
        threadID: String,
        target: CodexSchemaReviewTarget,
        delivery: CodexSchemaReviewDelivery? = nil
    ) async throws -> CodexSchemaReviewStartResponse {
        try await client.reviewStart(threadID: threadID, target: target, delivery: delivery)
    }

    /// Starts a review targeting specific timeline item IDs, without callers
    /// having to hand-assemble the review-target JSON payload.
    public func startReview(
        threadID: String,
        itemIDs: [String],
        delivery: CodexSchemaReviewDelivery? = nil
    ) async throws -> CodexSchemaReviewStartResponse {
        let target = CodexSchemaReviewTarget(
            .dictionary(["itemIds": .array(itemIDs.map(CodexJSONValue.string))])
        )
        return try await startReview(threadID: threadID, target: target, delivery: delivery)
    }

    /// Fuzzy-searches file names under the given roots (used for @-mentions).
    public func fuzzyFileSearch(
        query: String,
        roots: [String],
        cancellationToken: String? = nil
    ) async throws -> FuzzyFileSearchResponse {
        try await client.fuzzyFileSearch(query: query, roots: roots, cancellationToken: cancellationToken)
    }

    public func skillsList(cwds: [String] = [], forceReload: Bool = false) async throws -> CodexSchemaSkillsListResponse {
        try await client.skillsList(CodexSchemaSkillsListParams(
            cwds: cwds.isEmpty ? nil : cwds,
            forceReload: forceReload ? true : nil
        ))
    }

    public func permissionProfileList(limit: Int? = nil, cursor: String? = nil, cwd: String? = nil) async throws -> CodexSchemaPermissionProfileListResponse {
        try await client.permissionProfileList(CodexSchemaPermissionProfileListParams(cursor: cursor, cwd: cwd, limit: limit))
    }

    public func collaborationModeList() async throws -> CodexSchemaCollaborationModeListResponse {
        try await client.collaborationModeList()
    }

    public func mcpServerStatusList(
        threadId: String? = nil,
        detail: CodexSchemaMCPServerStatusDetail? = .full,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> CodexSchemaListMCPServerStatusResponse {
        try await client.mcpServerStatusList(CodexSchemaListMCPServerStatusParams(
            cursor: cursor,
            detail: detail,
            limit: limit,
            threadID: threadId
        ))
    }

    public func mcpServerToolCall(
        threadId: String,
        server: String,
        tool: String,
        arguments: CodexJSONValue? = nil,
        meta: CodexJSONValue? = nil
    ) async throws -> CodexSchemaMCPServerToolCallResponse {
        try await client.mcpServerToolCall(CodexSchemaMCPServerToolCallParams(
            meta: meta,
            arguments: arguments,
            server: server,
            threadID: threadId,
            tool: tool
        ))
    }

    public func mcpServerResourceRead(
        threadId: String? = nil,
        server: String,
        uri: String
    ) async throws -> CodexSchemaMCPResourceReadResponse {
        try await client.mcpServerResourceRead(CodexSchemaMCPResourceReadParams(
            server: server,
            threadID: threadId,
            uri: uri
        ))
    }

    public func pluginList(
        cwds: [String] = [],
        marketplaceKinds: [CodexSchemaPluginListMarketplaceKind] = []
    ) async throws -> CodexSchemaPluginListResponse {
        try await client.pluginList(CodexSchemaPluginListParams(
            cwds: cwds.isEmpty ? nil : cwds.map { CodexAppServerSchemaValue(.string($0)) },
            marketplaceKinds: marketplaceKinds.isEmpty ? nil : marketplaceKinds
        ))
    }

    public func remoteControlStatusRead() async throws -> CodexSchemaRemoteControlStatusReadResponse {
        try await client.remoteControlStatusRead()
    }

    public func remoteControlEnable(ephemeral: Bool? = nil) async throws -> CodexSchemaRemoteControlEnableResponse {
        try await client.remoteControlEnable(CodexSchemaRemoteControlEnableParams(ephemeral: ephemeral))
    }

    public func remoteControlDisable(ephemeral: Bool? = nil) async throws -> CodexSchemaRemoteControlDisableResponse {
        try await client.remoteControlDisable(CodexSchemaRemoteControlDisableParams(ephemeral: ephemeral))
    }

    public func remoteControlPairingStart(manualCode: Bool? = nil) async throws -> CodexSchemaRemoteControlPairingStartResponse {
        try await client.remoteControlPairingStart(CodexSchemaRemoteControlPairingStartParams(manualCode: manualCode))
    }

    public func remoteControlPairingStatus(
        pairingCode: String? = nil,
        manualPairingCode: String? = nil
    ) async throws -> CodexSchemaRemoteControlPairingStatusResponse {
        try await client.remoteControlPairingStatus(CodexSchemaRemoteControlPairingStatusParams(
            manualPairingCode: manualPairingCode,
            pairingCode: pairingCode
        ))
    }

    public func remoteControlClientList(
        environmentID: String,
        limit: Int? = nil,
        cursor: String? = nil,
        order: CodexSchemaRemoteControlClientsListOrder? = .desc
    ) async throws -> CodexSchemaRemoteControlClientsListResponse {
        try await client.remoteControlClientList(CodexSchemaRemoteControlClientsListParams(
            cursor: cursor,
            environmentID: environmentID,
            limit: limit,
            order: order
        ))
    }

    public func remoteControlClientRevoke(clientID: String, environmentID: String) async throws {
        _ = try await client.remoteControlClientRevoke(CodexSchemaRemoteControlClientsRevokeParams(
            clientID: clientID,
            environmentID: environmentID
        ))
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

    func appServerRequest(method: String, params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await client.request(method: method, params: params)
    }

    func appServerRequestWithClientRetryOnOverload(
        method: String,
        params: [String: CodexJSONValue] = [:],
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> CodexJSONValue {
        try await client.requestWithRetryOnOverload(
            method: method,
            params: params,
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        )
    }

    // MARK: - Approval Resolution (policy `.ask`)

    /// Answers a pending approval from `store.pendingApprovals`. Returns `false`
    /// if no request with this id is awaiting a decision.
    @discardableResult
    public func respondToApproval(id: String, decision: CodexApprovalDecision) async -> Bool {
        await client.resolveApproval(requestId: id, decision: decision)
    }

    /// Answers a pending `store.pendingUserInput` request with answers keyed by
    /// question id. Returns `false` if no request with this id is pending.
    @discardableResult
    public func respondToUserInput(id: String, answers: CodexUserInputAnswers) async -> Bool {
        await client.resolveUserInput(requestId: id, answers: answers)
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

    /// Resolves the Codex runtime executable used to launch the local app-server.
    ///
    /// Precedence is explicit SDK config, `CODEX_BINARY`, `CODEX_BIN`, `codex`
    /// from `PATH`, then a macOS Codex app bundle.
    public static func resolveCodexBinary(config: CodexConfig = CodexConfig()) throws -> URL {
        let fileManager = FileManager.default

        if let path = config.codexBinaryPath {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        for key in ["CODEX_BINARY", "CODEX_BIN"] {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { continue }
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        for appBundleURL in codexAppBundleCandidates(fileManager: fileManager) {
            let candidate = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("codex")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw CodexSDKError.runtimeNotFound
    }

    private static func codexAppBundleCandidates(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []
        var seenPaths: Set<String> = []

        func append(_ url: URL) {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { return }
            candidates.append(URL(fileURLWithPath: standardizedPath, isDirectory: true))
        }

        for key in ["CODEX_APP_BUNDLE", "CODEX_APP_BUNDLE_PATH"] {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { continue }
            append(URL(fileURLWithPath: path, isDirectory: true))
        }

        #if os(macOS)
        for directory in fileManager.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask]) {
            append(directory.appendingPathComponent("Codex.app", isDirectory: true))
        }
        #endif

        return candidates
    }

}

private final class CodexLoginHandleLifecycle: @unchecked Sendable {
    let loginId: String

    internal let client: CodexClient

    init(client: CodexClient, loginId: String) {
        self.client = client
        self.loginId = loginId
    }

    func stream() -> AsyncStream<CodexNotification> {
        client.loginNotifications(loginId: loginId)
    }

    func wait() async throws -> AccountLoginCompletedNotification {
        for await notification in stream() {
            if case .accountLoginCompleted(let payload) = notification.payload {
                return payload
            }
        }
        throw CodexSDKError.loginStreamEnded(loginId: loginId)
    }

    @discardableResult
    func cancel() async throws -> CancelLoginAccountResponse {
        try await client.accountLoginCancel(loginId: loginId)
    }
}

public final class ChatGPTLoginHandle: Identifiable, @unchecked Sendable {
    public var id: String { loginId }
    public var loginId: String { lifecycle.loginId }
    public let authUrl: String

    private let lifecycle: CodexLoginHandleLifecycle

    fileprivate init(client: CodexClient, loginId: String, authUrl: String) {
        self.lifecycle = CodexLoginHandleLifecycle(client: client, loginId: loginId)
        self.authUrl = authUrl
    }

    public func stream() -> AsyncStream<CodexNotification> {
        lifecycle.stream()
    }

    public func wait() async throws -> AccountLoginCompletedNotification {
        try await lifecycle.wait()
    }

    @discardableResult
    public func cancel() async throws -> CancelLoginAccountResponse {
        try await lifecycle.cancel()
    }
}

public final class DeviceCodeLoginHandle: Identifiable, @unchecked Sendable {
    public var id: String { loginId }
    public var loginId: String { lifecycle.loginId }
    public let verificationUrl: String
    public let userCode: String

    private let lifecycle: CodexLoginHandleLifecycle

    fileprivate init(client: CodexClient, loginId: String, verificationUrl: String, userCode: String) {
        self.lifecycle = CodexLoginHandleLifecycle(client: client, loginId: loginId)
        self.verificationUrl = verificationUrl
        self.userCode = userCode
    }

    public func stream() -> AsyncStream<CodexNotification> {
        lifecycle.stream()
    }

    public func wait() async throws -> AccountLoginCompletedNotification {
        try await lifecycle.wait()
    }

    @discardableResult
    public func cancel() async throws -> CancelLoginAccountResponse {
        try await lifecycle.cancel()
    }
}

public final class CodexThread: Identifiable, @unchecked Sendable {
    public let id: String

    internal let client: CodexClient
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
        let turnId = try await client.turnStart(
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
        let turnId = try await client.turnStart(
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

    public func setGoal(
        objective: String,
        status: ThreadGoalStatus = .active,
        tokenBudget: Int? = nil
    ) async throws -> ThreadGoalSetResponse {
        try await client.threadGoalSet(
            threadId: id,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        )
    }

    public func updateGoal(
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int? = nil
    ) async throws -> ThreadGoalSetResponse {
        try await client.threadGoalSet(
            threadId: id,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        )
    }

    public func goal() async throws -> ThreadGoalGetResponse {
        try await client.threadGoalGet(threadId: id)
    }

    public func clearGoal() async throws -> ThreadGoalClearResponse {
        try await client.threadGoalClear(threadId: id)
    }

    public func compact() async throws -> ThreadCompactStartResponse {
        try await client.threadCompact(threadId: id)
    }

    public func interrupt(turnId: String) async throws -> CodexJSONValue {
        let response = try await client.turnInterrupt(threadId: id, turnId: turnId)
        return try CodexJSONValue(encoding: response)
    }
}

public final class CodexTurnHandle: Identifiable, @unchecked Sendable {
    public let threadId: String
    public let id: String

    internal let client: CodexClient
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
        let response = try await client.turnSteer(
            threadId: threadId,
            expectedTurnId: id,
            input: input.map { CodexInput.raw($0.jsonValue) }
        )
        return try CodexJSONValue(encoding: response)
    }

    public func interrupt() async throws -> CodexJSONValue {
        let response = try await client.turnInterrupt(threadId: threadId, turnId: id)
        return try CodexJSONValue(encoding: response)
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

    public func snapshots() -> AsyncThrowingStream<CodexTurnSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastSnapshot: CodexTurnSnapshot?

                func emitLatest() async -> CodexTurnSnapshot? {
                    guard let snapshot = await self.currentSnapshot() else { return nil }
                    if snapshot != lastSnapshot {
                        continuation.yield(snapshot)
                        lastSnapshot = snapshot
                    }
                    return snapshot
                }

                if let snapshot = await emitLatest(), snapshot.status != .running {
                    continuation.finish()
                    return
                }

                for await _ in self.stream() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if let snapshot = await emitLatest(), snapshot.status != .running {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run(timeout: TimeInterval = 300) async throws -> CodexTurnResult {
        if Task.isCancelled {
            throw CancellationError()
        }

        return try await withThrowingTaskGroup(of: CodexTurnResult.self) { group in
            group.addTask {
                _ = try await self.client.waitForTurnCompleted(turnId: self.id)
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard let snapshot = await self.currentSnapshot() else {
                    throw CodexSDKError.turnStreamEnded(turnId: self.id)
                }
                let result = self.makeResult(from: snapshot)
                if snapshot.status == .failed {
                    throw CodexSDKError.turnFailed(result)
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CodexSDKError.turnTimedOut(turnId: self.id)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodexSDKError.turnTimedOut(turnId: self.id)
            }
            return result
        }
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
            items: snapshot.items,
            usage: snapshot.usage
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

private extension LoginAccountResponse {
    var jsonValue: CodexJSONValue {
        switch self {
        case .apiKey:
            return .dictionary(["type": .string("apiKey")])
        case .chatgpt(let loginId, let authUrl):
            return .dictionary(["type": .string("chatgpt"), "loginId": .string(loginId), "authUrl": .string(authUrl)])
        case .chatgptDeviceCode(let loginId, let verificationUrl, let userCode):
            return .dictionary([
                "type": .string("chatgptDeviceCode"),
                "loginId": .string(loginId),
                "verificationUrl": .string(verificationUrl),
                "userCode": .string(userCode)
            ])
        case .chatgptAuthTokens:
            return .dictionary(["type": .string("chatgptAuthTokens")])
        case .unknown(let object):
            return .dictionary(object)
        }
    }
}
