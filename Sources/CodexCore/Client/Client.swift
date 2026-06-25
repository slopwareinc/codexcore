import Foundation

// MARK: - Process Protocols

public struct PTYSize: Codable, Sendable {
    public let rows: Int
    public let cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}

public typealias CodexServerRequestHandler = @Sendable (JSONRPCServerRequest) async -> CodexJSONValue?

private struct CodexOutputDeltaRoute {
    var targetID: String
    var stream: String
    var base64Data: String
    var capReached: Bool
}

// MARK: - CodexClient

public actor CodexClient {
    private let connection: CodexConnection
    private let store: CodexCoreStore
    private let serverRequestHandler: CodexServerRequestHandler?
    private let approvalPolicy: CodexApprovalPolicy
    public nonisolated let notificationRouter: CodexNotificationRouter

    private var activeCommandSessions: [String: CodexCommandExecSession] = [:]

    private var notificationStreamContinuation: AsyncStream<JSONRPCNotification>.Continuation?
    private var notificationConsumerTask: Task<Void, Never>?

    // Escalated server requests awaiting a host decision (policy `.ask`).
    private var pendingApprovalContinuations: [String: CheckedContinuation<CodexApprovalDecision, Never>] = [:]
    private var pendingApprovalTurnIds: [String: String] = [:]
    private var pendingUserInputContinuations: [String: CheckedContinuation<CodexUserInputAnswers, Never>] = [:]

    public init(
        transport: any CodexTransport,
        store: CodexCoreStore,
        notificationRouter: CodexNotificationRouter = CodexNotificationRouter(),
        serverRequestHandler: CodexServerRequestHandler? = nil,
        approvalPolicy: CodexApprovalPolicy = .autoApprove
    ) {
        self.connection = CodexConnection(transport: transport)
        self.store = store
        self.serverRequestHandler = serverRequestHandler
        self.approvalPolicy = approvalPolicy
        self.notificationRouter = notificationRouter
    }

    public nonisolated func notifications() -> AsyncStream<CodexNotification> {
        notificationRouter.globalNotifications()
    }

    public nonisolated func turnNotifications(turnId: String) -> AsyncStream<CodexNotification> {
        notificationRouter.turnNotifications(turnId: turnId)
    }

    public nonisolated func loginNotifications(loginId: String) -> AsyncStream<CodexNotification> {
        notificationRouter.loginNotifications(loginId: loginId)
    }

    /// Establishes the connection and performs the initialize handshake.
    @discardableResult
    public func connect(
        clientName: String = "CodexCoreSwift",
        clientTitle: String = "Codex Core Swift Native SDK",
        clientVersion: String = "1.0.0",
        experimentalAPI: Bool = true
    ) async throws -> InitializeResponse {
        stopNotificationConsumer()

        let (stream, continuation) = AsyncStream.makeStream(of: JSONRPCNotification.self)
        notificationStreamContinuation = continuation
        notificationConsumerTask = Task {
            for await notification in stream {
                await self.handleNotification(notification)
            }
        }

        return try await connection.start(
            clientName: clientName,
            clientTitle: clientTitle,
            clientVersion: clientVersion,
            experimentalAPI: experimentalAPI,
            onNotification: { notification in
                continuation.yield(notification)
            },
            onServerRequest: { [weak self] serverRequest in
                guard let self else { return .null }
                return await self.handleServerRequest(serverRequest)
            }
        )
    }

    /// Sends an arbitrary app-server request. This keeps the SDK usable while
    /// typed wrappers are added for the full generated schema surface.
    @discardableResult
    public func request(method: String, params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await connection.request(method: method, params: params)
    }

    public func request<Response: Decodable>(
        method: String,
        params: [String: CodexJSONValue] = [:],
        response: Response.Type
    ) async throws -> Response {
        let value = try await request(method: method, params: params)
        return try value.decode(Response.self)
    }

    public func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        response: Response.Type
    ) async throws -> Response {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await request(method: method, params: object, response: Response.self)
    }

    public func notify(method: String, params: [String: CodexJSONValue] = [:]) async throws {
        try await connection.notify(method: method, params: params)
    }

    public func waitForTurnCompleted(turnId: String) async throws -> TurnCompletedNotification {
        await notificationRouter.registerTurn(turnId)

        for await notification in turnNotifications(turnId: turnId) {
            if case .turnCompleted(let payload) = notification.payload, payload.turn.id == turnId {
                await notificationRouter.unregisterTurn(turnId)
                return payload
            }
        }

        await notificationRouter.unregisterTurn(turnId)
        throw CodexSDKError.turnStreamEnded(turnId: turnId)
    }

    public func waitForLoginCompleted(loginId: String) async throws -> AccountLoginCompletedNotification {
        await notificationRouter.registerLogin(loginId)

        for await notification in loginNotifications(loginId: loginId) {
            if case .accountLoginCompleted(let payload) = notification.payload, payload.loginId == loginId {
                await notificationRouter.unregisterLogin(loginId)
                return payload
            }
        }

        await notificationRouter.unregisterLogin(loginId)
        throw CodexSDKError.loginStreamEnded(loginId: loginId)
    }

    // MARK: - Python SDK typed request APIs

    public func accountLoginStart(_ params: LoginAccountParams) async throws -> LoginAccountResponse {
        let response: LoginAccountResponse = try await connection.request(
            method: CodexAppServerClientMethod.accountLoginStart.rawValue,
            params: params,
            response: LoginAccountResponse.self
        )
        switch response {
        case .chatgpt(let loginId, _), .chatgptDeviceCode(let loginId, _, _):
            await notificationRouter.registerLogin(loginId)
        default:
            break
        }
        return response
    }

    public func accountLoginCancel(loginId: String) async throws -> CancelLoginAccountResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.accountLoginCancel.rawValue,
            params: ["loginId": CodexJSONValue.string(loginId)],
            response: CancelLoginAccountResponse.self
        )
    }

    public func accountRead(_ params: GetAccountParams = GetAccountParams()) async throws -> GetAccountResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.accountRead.rawValue,
            params: params,
            response: GetAccountResponse.self
        )
    }

    public func accountRateLimitsRead() async throws -> CodexSchemaGetAccountRateLimitsResponse {
        let params: [String: CodexJSONValue] = [:]
        return try await connection.request(
            method: CodexAppServerClientMethod.accountRateLimitsRead.rawValue,
            params: params,
            response: CodexSchemaGetAccountRateLimitsResponse.self
        )
    }

    public func accountLogout() async throws -> LogoutAccountResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.accountLogout.rawValue,
            response: LogoutAccountResponse.self
        )
    }

    public func threadStart(_ params: ThreadStartParams = ThreadStartParams()) async throws -> ThreadStartResponse {
        let response: ThreadStartResponse = try await connection.request(
            method: CodexAppServerClientMethod.threadStart.rawValue,
            params: params,
            response: ThreadStartResponse.self
        )
        await MainActor.run {
            store.dispatch(.threadStarted(threadId: response.thread.id, name: nil, status: "idle"))
            store.activateThread(id: response.thread.id)
        }
        return response
    }

    public func threadResume(threadId: String, params: ThreadResumeParams = ThreadResumeParams()) async throws -> ThreadResumeResponse {
        var payload = params
        payload.threadId = threadId
        let response: ThreadResumeResponse = try await connection.request(
            method: CodexAppServerClientMethod.threadResume.rawValue,
            params: payload,
            response: ThreadResumeResponse.self
        )
        await MainActor.run {
            store.dispatch(.threadStarted(threadId: response.thread.id, name: nil, status: "idle"))
            store.activateThread(id: response.thread.id)
        }
        return response
    }

    public func threadList(_ params: ThreadListParams = ThreadListParams()) async throws -> ThreadListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadList.rawValue,
            params: params,
            response: ThreadListResponse.self
        )
    }

    public func threadRead(threadId: String, includeTurns: Bool = false) async throws -> ThreadReadResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadRead.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId), "includeTurns": .bool(includeTurns)],
            response: ThreadReadResponse.self
        )
    }

    public func threadListSchema(_ params: CodexSchemaThreadListParams = CodexSchemaThreadListParams()) async throws -> CodexSchemaThreadListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadList.rawValue,
            params: params,
            response: CodexSchemaThreadListResponse.self
        )
    }

    public func threadReadSchema(threadId: String, includeTurns: Bool = false) async throws -> CodexSchemaThreadReadResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadRead.rawValue,
            params: CodexSchemaThreadReadParams(includeTurns: includeTurns, threadID: threadId),
            response: CodexSchemaThreadReadResponse.self
        )
    }

    public func threadSearch(_ params: CodexSchemaThreadSearchParams) async throws -> CodexSchemaThreadSearchResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadSearch.rawValue,
            params: params,
            response: CodexSchemaThreadSearchResponse.self
        )
    }

    public func threadFork(threadId: String, params: ThreadForkParams = ThreadForkParams()) async throws -> ThreadForkResponse {
        var payload = params
        payload.threadId = threadId
        let response: ThreadForkResponse = try await connection.request(
            method: CodexAppServerClientMethod.threadFork.rawValue,
            params: payload,
            response: ThreadForkResponse.self
        )
        await MainActor.run {
            store.dispatch(.threadStarted(threadId: response.thread.id, name: nil, status: "idle"))
            store.activateThread(id: response.thread.id)
        }
        return response
    }

    public func threadArchive(threadId: String) async throws -> ThreadArchiveResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadArchive.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId)],
            response: ThreadArchiveResponse.self
        )
    }

    public func threadUnarchive(threadId: String) async throws -> ThreadUnarchiveResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadUnarchive.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId)],
            response: ThreadUnarchiveResponse.self
        )
    }

    public func threadSetName(threadId: String, name: String) async throws -> ThreadSetNameResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadNameSet.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId), "name": .string(name)],
            response: ThreadSetNameResponse.self
        )
    }

    public func threadGoalSet(
        threadId: String,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int? = nil
    ) async throws -> ThreadGoalSetResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadGoalSet.rawValue,
            params: ThreadGoalSetParams(
                threadId: threadId,
                objective: objective,
                status: status,
                tokenBudget: tokenBudget
            ),
            response: ThreadGoalSetResponse.self
        )
    }

    public func threadGoalGet(threadId: String) async throws -> ThreadGoalGetResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadGoalGet.rawValue,
            params: ThreadGoalGetParams(threadId: threadId),
            response: ThreadGoalGetResponse.self
        )
    }

    public func threadGoalClear(threadId: String) async throws -> ThreadGoalClearResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadGoalClear.rawValue,
            params: ThreadGoalClearParams(threadId: threadId),
            response: ThreadGoalClearResponse.self
        )
    }

    public func threadCompact(threadId: String) async throws -> ThreadCompactStartResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.threadCompactStart.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId)],
            response: ThreadCompactStartResponse.self
        )
    }

    public func turnStart(_ params: TurnStartParams) async throws -> TurnStartResponse {
        let response: TurnStartResponse = try await connection.request(
            method: CodexAppServerClientMethod.turnStart.rawValue,
            params: params,
            response: TurnStartResponse.self
        )
        await notificationRouter.registerTurn(response.turn.id)
        await MainActor.run {
            store.dispatch(.turnStarted(threadId: params.threadId, turnId: response.turn.id))
        }
        return response
    }

    public func turnInterrupt(threadId: String, turnId: String) async throws -> TurnInterruptResponse {
        cancelPendingServerRequests(turnId: turnId)
        return try await connection.request(
            method: CodexAppServerClientMethod.turnInterrupt.rawValue,
            params: ["threadId": CodexJSONValue.string(threadId), "turnId": .string(turnId)],
            response: TurnInterruptResponse.self
        )
    }

    public func turnSteer(threadId: String, expectedTurnId: String, input: [CodexInput]) async throws -> TurnSteerResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.turnSteer.rawValue,
            params: [
                "threadId": CodexJSONValue.string(threadId),
                "expectedTurnId": .string(expectedTurnId),
                "input": .array(input.map(\.jsonValue))
            ],
            response: TurnSteerResponse.self
        )
    }

    public nonisolated func streamText(
        threadId: String,
        text: String,
        params additionalParams: [String: CodexJSONValue] = [:]
    ) -> AsyncThrowingStream<AgentMessageDeltaNotification, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let turnId = try await self.turnStart(
                        threadId: threadId,
                        input: [CodexInput.text(text).jsonValue],
                        additionalParams: additionalParams
                    )

                    for await notification in self.turnNotifications(turnId: turnId) {
                        switch notification.payload {
                        case .agentMessageDelta(let payload) where payload.turnId == turnId:
                            continuation.yield(payload)
                        case .turnCompleted(let payload) where payload.turn.id == turnId:
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fuzzyFileSearch(
        query: String,
        roots: [String],
        cancellationToken: String? = nil
    ) async throws -> FuzzyFileSearchResponse {
        var params: [String: CodexJSONValue] = [
            "query": .string(query),
            "roots": .array(roots.map { .string($0) })
        ]
        if let cancellationToken {
            params["cancellationToken"] = .string(cancellationToken)
        }
        return try await connection.request(
            method: CodexAppServerClientMethod.fuzzyFileSearch.rawValue,
            params: params,
            response: FuzzyFileSearchResponse.self
        )
    }

    public func modelList(includeHidden: Bool = false) async throws -> ModelListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.modelList.rawValue,
            params: ["includeHidden": CodexJSONValue.bool(includeHidden)],
            response: ModelListResponse.self
        )
    }

    public func reviewStart(_ params: CodexSchemaReviewStartParams) async throws -> CodexSchemaReviewStartResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.reviewStart.rawValue,
            params: params,
            response: CodexSchemaReviewStartResponse.self
        )
    }

    public func reviewStart(
        threadID: String,
        target: CodexSchemaReviewTarget,
        delivery: CodexSchemaReviewDelivery? = nil
    ) async throws -> CodexSchemaReviewStartResponse {
        try await reviewStart(CodexSchemaReviewStartParams(
            delivery: delivery,
            target: target,
            threadID: threadID
        ))
    }

    public func skillsList(_ params: CodexSchemaSkillsListParams = CodexSchemaSkillsListParams()) async throws -> CodexSchemaSkillsListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.skillsList.rawValue,
            params: params,
            response: CodexSchemaSkillsListResponse.self
        )
    }

    public func permissionProfileList(_ params: CodexSchemaPermissionProfileListParams = CodexSchemaPermissionProfileListParams()) async throws -> CodexSchemaPermissionProfileListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.permissionProfileList.rawValue,
            params: params,
            response: CodexSchemaPermissionProfileListResponse.self
        )
    }

    public func collaborationModeList() async throws -> CodexSchemaCollaborationModeListResponse {
        let value = try await connection.request(method: CodexAppServerClientMethod.collaborationModeList.rawValue, params: [:])
        return try value.decode(CodexSchemaCollaborationModeListResponse.self)
    }

    public func mcpServerStatusList(_ params: CodexSchemaListMCPServerStatusParams = CodexSchemaListMCPServerStatusParams()) async throws -> CodexSchemaListMCPServerStatusResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.mcpServerStatusList.rawValue,
            params: params,
            response: CodexSchemaListMCPServerStatusResponse.self
        )
    }

    public func mcpServerToolCall(_ params: CodexSchemaMCPServerToolCallParams) async throws -> CodexSchemaMCPServerToolCallResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.mcpServerToolCall.rawValue,
            params: params,
            response: CodexSchemaMCPServerToolCallResponse.self
        )
    }

    public func mcpServerResourceRead(_ params: CodexSchemaMCPResourceReadParams) async throws -> CodexSchemaMCPResourceReadResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.mcpServerResourceRead.rawValue,
            params: params,
            response: CodexSchemaMCPResourceReadResponse.self
        )
    }

    public func pluginList(_ params: CodexSchemaPluginListParams = CodexSchemaPluginListParams()) async throws -> CodexSchemaPluginListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.pluginList.rawValue,
            params: params,
            response: CodexSchemaPluginListResponse.self
        )
    }

    public func remoteControlStatusRead() async throws -> CodexSchemaRemoteControlStatusReadResponse {
        let value = try await connection.request(method: CodexAppServerClientMethod.remoteControlStatusRead.rawValue, params: [:])
        return try value.decode(CodexSchemaRemoteControlStatusReadResponse.self)
    }

    public func remoteControlEnable(_ params: CodexSchemaRemoteControlEnableParams = CodexSchemaRemoteControlEnableParams()) async throws -> CodexSchemaRemoteControlEnableResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlEnable.rawValue,
            params: params,
            response: CodexSchemaRemoteControlEnableResponse.self
        )
    }

    public func remoteControlDisable(_ params: CodexSchemaRemoteControlDisableParams = CodexSchemaRemoteControlDisableParams()) async throws -> CodexSchemaRemoteControlDisableResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlDisable.rawValue,
            params: params,
            response: CodexSchemaRemoteControlDisableResponse.self
        )
    }

    public func remoteControlPairingStart(_ params: CodexSchemaRemoteControlPairingStartParams = CodexSchemaRemoteControlPairingStartParams()) async throws -> CodexSchemaRemoteControlPairingStartResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlPairingStart.rawValue,
            params: params,
            response: CodexSchemaRemoteControlPairingStartResponse.self
        )
    }

    public func remoteControlPairingStatus(_ params: CodexSchemaRemoteControlPairingStatusParams = CodexSchemaRemoteControlPairingStatusParams()) async throws -> CodexSchemaRemoteControlPairingStatusResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlPairingStatus.rawValue,
            params: params,
            response: CodexSchemaRemoteControlPairingStatusResponse.self
        )
    }

    public func remoteControlClientList(_ params: CodexSchemaRemoteControlClientsListParams) async throws -> CodexSchemaRemoteControlClientsListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlClientList.rawValue,
            params: params,
            response: CodexSchemaRemoteControlClientsListResponse.self
        )
    }

    public func remoteControlClientRevoke(_ params: CodexSchemaRemoteControlClientsRevokeParams) async throws -> CodexSchemaRemoteControlClientsRevokeResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.remoteControlClientRevoke.rawValue,
            params: params,
            response: CodexSchemaRemoteControlClientsRevokeResponse.self
        )
    }

    /// Closes the client connection.
    public func disconnect() async {
        cancelPendingServerRequests()
        stopNotificationConsumer()
        await connection.stop()
    }

    private func stopNotificationConsumer() {
        notificationStreamContinuation?.finish()
        notificationStreamContinuation = nil
        notificationConsumerTask?.cancel()
        notificationConsumerTask = nil
    }

    // MARK: - Approval Resolution (policy `.ask`)

    /// Resolves a pending approval request (`store.pendingApprovals`) with the
    /// user's decision. The suspended JSON-RPC reply is then sent to the server.
    /// Returns `false` if no request with that id is awaiting a decision.
    @discardableResult
    public func resolveApproval(requestId: String, decision: CodexApprovalDecision) -> Bool {
        guard let continuation = pendingApprovalContinuations.removeValue(forKey: requestId) else {
            return false
        }
        pendingApprovalTurnIds.removeValue(forKey: requestId)
        continuation.resume(returning: decision)
        return true
    }

    /// Resolves a pending `item/tool/requestUserInput` request with the user's
    /// answers (question id → answer strings).
    @discardableResult
    public func resolveUserInput(requestId: String, answers: CodexUserInputAnswers) -> Bool {
        guard let continuation = pendingUserInputContinuations.removeValue(forKey: requestId) else {
            return false
        }
        continuation.resume(returning: answers)
        return true
    }

    /// Cancels every pending escalated request: approvals resolve `.cancel`,
    /// user-input requests resolve with no answers. Called automatically on
    /// disconnect so suspended server replies never leak.
    public func cancelPendingServerRequests() {
        let approvals = pendingApprovalContinuations
        pendingApprovalContinuations = [:]
        pendingApprovalTurnIds = [:]
        for continuation in approvals.values {
            continuation.resume(returning: .cancel)
        }

        let inputs = pendingUserInputContinuations
        pendingUserInputContinuations = [:]
        for continuation in inputs.values {
            continuation.resume(returning: [:])
        }
    }

    /// Cancels pending escalated requests that belong to a specific turn.
    public func cancelPendingServerRequests(turnId: String) {
        let requestIds = pendingApprovalTurnIds.filter { $0.value == turnId }.map(\.key)
        for requestId in requestIds {
            resolveApproval(requestId: requestId, decision: .cancel)
        }
    }

    // MARK: - Turn Helpers

    @discardableResult
    func turnStart(
        threadId: String,
        input: [CodexJSONValue],
        additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> String {
        var params = additionalParams
        params["threadId"] = .string(threadId)
        params["input"] = .array(input)

        let result = try await connection.request(method: CodexAppServerClientMethod.turnStart.rawValue, params: params)

        guard case .dictionary(let dict) = result,
              let turnVal = dict["turn"],
              case .dictionary(let turnDict) = turnVal,
              let idVal = turnDict["id"],
              case .string(let turnId) = idVal else {
            throw CodexSDKError.invalidResponse(method: CodexAppServerClientMethod.turnStart.rawValue, value: result)
        }

        await MainActor.run {
            store.dispatch(.turnStarted(threadId: threadId, turnId: turnId))
        }
        await notificationRouter.registerTurn(turnId)

        return turnId
    }

    // MARK: - command/exec APIs

    public func execCommand(
        command: [String],
        cwd: String? = nil,
        environment: [String: String?]? = nil,
        timeoutMilliseconds: Int64? = nil,
        outputBytesCap: Int? = nil,
        disableTimeout: Bool = false,
        disableOutputCap: Bool = false
    ) async throws -> CodexCommandExecResult {
        var params = commandExecParams(
            command: command,
            cwd: cwd,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds,
            outputBytesCap: outputBytesCap,
            disableTimeout: disableTimeout,
            disableOutputCap: disableOutputCap
        )
        params["streamStdin"] = nil
        params["streamStdoutStderr"] = nil
        params["tty"] = nil

        let result = try await connection.request(method: CodexAppServerClientMethod.commandExec.rawValue, params: params)
        return try CodexCommandExecResult(jsonValue: result)
    }

    public func startCommandSession(
        command: [String],
        cwd: String? = nil,
        environment: [String: String?]? = nil,
        initialSize: PTYSize? = nil,
        tty: Bool = true,
        timeoutMilliseconds: Int64? = nil,
        outputBytesCap: Int? = nil,
        disableTimeout: Bool = false,
        disableOutputCap: Bool = false
    ) async throws -> CodexCommandExecSession {
        let processId = UUID().uuidString
        let session = CodexCommandExecSession(processId: processId, connection: connection)
        activeCommandSessions[processId] = session

        var params = commandExecParams(
            command: command,
            cwd: cwd,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds,
            outputBytesCap: outputBytesCap,
            disableTimeout: disableTimeout,
            disableOutputCap: disableOutputCap
        )
        params["processId"] = .string(processId)
        params["tty"] = .bool(tty)
        params["streamStdin"] = .bool(true)
        params["streamStdoutStderr"] = .bool(true)
        if let initialSize {
            params["size"] = .dictionary([
                "rows": .int(initialSize.rows),
                "cols": .int(initialSize.cols)
            ])
        }

        let connection = self.connection
        Task { [weak self] in
            do {
                let value = try await connection.request(method: CodexAppServerClientMethod.commandExec.rawValue, params: params)
                let result = try CodexCommandExecResult(jsonValue: value)
                await self?.completeCommandSession(processId: processId, result: result)
            } catch {
                await self?.failCommandSession(processId: processId, error: error)
            }
        }

        return session
    }

    private func commandExecParams(
        command: [String],
        cwd: String?,
        environment: [String: String?]?,
        timeoutMilliseconds: Int64?,
        outputBytesCap: Int?,
        disableTimeout: Bool,
        disableOutputCap: Bool
    ) -> [String: CodexJSONValue] {
        var params: [String: CodexJSONValue] = [
            "command": .array(command.map { .string($0) })
        ]

        if let cwd { params["cwd"] = .string(cwd) }
        if let timeoutMilliseconds { params["timeoutMs"] = .int(Int(timeoutMilliseconds)) }
        if let outputBytesCap { params["outputBytesCap"] = .int(outputBytesCap) }
        if disableTimeout { params["disableTimeout"] = .bool(true) }
        if disableOutputCap { params["disableOutputCap"] = .bool(true) }
        if let environment {
            params["env"] = .dictionary(environment.mapValues { value in
                if let value { return .string(value) }
                return .null
            })
        }

        return params
    }

    // MARK: - Server Request Handling (approval requests from server)

    /// Handles incoming server→client requests (approvals, user inputs).
    /// The return value is sent back as the JSON-RPC response.
    private func handleServerRequest(_ serverRequest: JSONRPCServerRequest) async -> CodexJSONValue {
        if let response = await serverRequestHandler?(serverRequest) {
            return response
        }

        let method = serverRequest.method
        let params = serverRequest.params
        let requestId = serverRequest.id

        func str(_ key: String) -> String {
            if case .string(let value)? = params[key] { return value }
            return params[key]?.description ?? ""
        }

        guard let knownMethod = CodexAppServerServerRequestMethod(rawValue: method) else {
            print("[CodexClient] Unhandled server request: \(method)")
            return .dictionary([:])
        }

        switch knownMethod {
        case .itemCommandExecutionRequestApproval:
            let approvalId = str("approvalId")
            let itemId = str("itemId")

            let req = CodexApprovalRequest(
                requestId: requestId,
                kind: .command,
                threadId: str("threadId"),
                turnId: str("turnId"),
                itemId: approvalId.isEmpty ? itemId : approvalId,
                command: optionalString(params["command"]),
                cwd: optionalString(params["cwd"]),
                reason: optionalString(params["reason"])
            )

            let decision = await decideApproval(req)
            return .dictionary(["decision": .string(decision.rawValue)])

        case .itemFileChangeRequestApproval:
            let req = CodexApprovalRequest(
                requestId: requestId,
                kind: .fileChange,
                threadId: str("threadId"),
                turnId: str("turnId"),
                itemId: str("itemId"),
                command: optionalString(params["command"]),
                path: optionalString(params["path"]),
                grantRoot: optionalString(params["grantRoot"]),
                cwd: optionalString(params["cwd"]),
                reason: optionalString(params["reason"])
            )

            let decision = await decideApproval(req)
            return .dictionary(["decision": .string(decision.rawValue)])

        case .itemToolRequestUserInput:
            let questions = parseUserInputQuestions(params["questions"])
            let req = CodexUserInputRequest(
                requestId: requestId,
                threadId: str("threadId"),
                turnId: str("turnId"),
                itemId: str("itemId"),
                questions: questions
            )
            let answers = await decideUserInput(req)
            let encoded = answers.mapValues { answerStrings in
                CodexJSONValue.dictionary(["answers": .array(answerStrings.map { .string($0) })])
            }
            return .dictionary(["answers": .dictionary(encoded)])

        case .mcpServerElicitationRequest:
            return .dictionary([
                "action": .string("decline"),
                "content": .null,
                "_meta": .null
            ])

        case .itemPermissionsRequestApproval:
            let req = CodexApprovalRequest(
                requestId: requestId,
                kind: .permissions,
                threadId: str("threadId"),
                turnId: str("turnId"),
                itemId: str("itemId"),
                cwd: optionalString(params["cwd"]),
                reason: optionalString(params["reason"])
            )
            let decision = await decideApproval(req)
            // Granting echoes the requested profile back; denying grants nothing.
            let granted = decision.isApproval ? (params["permissions"] ?? .dictionary([:])) : .dictionary([:])
            return .dictionary([
                "permissions": granted,
                "scope": .string(decision == .acceptForSession ? "session" : "turn")
            ])

        case .itemToolCall:
            return .dictionary([
                "contentItems": .array([]),
                "success": .bool(false)
            ])

        case .currentTimeRead:
            return .dictionary([
                "currentTimeAt": .int(Int(Date().timeIntervalSince1970))
            ])

        case .accountChatGPTAuthTokensRefresh, .attestationGenerate, .execCommandApproval, .applyPatchApproval:
            return .dictionary([:])
        }
    }

    /// Applies the configured `CodexApprovalPolicy` to an escalated approval
    /// request. Under `.ask` the request is published to the store and the
    /// reply suspends until the host calls `resolveApproval(requestId:decision:)`.
    private func decideApproval(_ request: CodexApprovalRequest) async -> CodexApprovalDecision {
        switch approvalPolicy {
        case .autoApprove:
            return .accept
        case .autoDecline:
            return .decline
        case .ask:
            let requestKey = request.id
            let decision = await withCheckedContinuation { (continuation: CheckedContinuation<CodexApprovalDecision, Never>) in
                pendingApprovalContinuations[requestKey] = continuation
                pendingApprovalTurnIds[requestKey] = request.turnId
                Task { @MainActor [store] in
                    store.dispatchRequest(request)
                }
            }
            await MainActor.run {
                store.resolveApproval(requestKey)
            }
            return decision
        }
    }

    /// Applies the configured `CodexApprovalPolicy` to a user-input request.
    /// Auto policies answer with no input; `.ask` suspends until the host
    /// calls `resolveUserInput(requestId:answers:)`.
    private func decideUserInput(_ request: CodexUserInputRequest) async -> CodexUserInputAnswers {
        switch approvalPolicy {
        case .autoApprove, .autoDecline:
            return [:]
        case .ask:
            let requestKey = request.id
            let answers = await withCheckedContinuation { (continuation: CheckedContinuation<CodexUserInputAnswers, Never>) in
                pendingUserInputContinuations[requestKey] = continuation
                Task { @MainActor [store] in
                    store.dispatchRequest(request)
                }
            }
            await MainActor.run {
                store.resolveUserInput()
            }
            return answers
        }
    }

    private func parseUserInputQuestions(_ value: CodexJSONValue?) -> [CodexUserInputQuestion] {
        guard case .array(let rawQuestions)? = value else { return [] }
        return rawQuestions.compactMap { rawQuestion in
            guard case .dictionary(let question) = rawQuestion else { return nil }
            let id = stringValue(question["id"])
            let text = stringValue(question["question"])
            guard !id.isEmpty, !text.isEmpty else { return nil }

            let options: [CodexUserInputOption]
            if case .array(let rawOptions)? = question["options"] {
                options = rawOptions.compactMap { rawOption in
                    guard case .dictionary(let option) = rawOption else { return nil }
                    let label = stringValue(option["label"])
                    guard !label.isEmpty else { return nil }
                    return CodexUserInputOption(label: label, description: optionalString(option["description"]))
                }
            } else {
                options = []
            }

            return CodexUserInputQuestion(
                id: id,
                question: text,
                header: optionalString(question["header"]),
                isSecret: boolValue(question["isSecret"]),
                isOtherAllowed: boolValue(question["isOther"]),
                options: options
            )
        }
    }

    private func stringValue(_ value: CodexJSONValue?) -> String {
        if case .string(let string)? = value { return string }
        return value?.description ?? ""
    }

    private func boolValue(_ value: CodexJSONValue?) -> Bool {
        if case .bool(let bool)? = value { return bool }
        return false
    }

    // MARK: - Server Notification Handling

    private func handleNotification(_ notification: JSONRPCNotification) async {
        let method = notification.method
        let params = notification.params ?? [:]
        let storeEvent = storeEventBeforeRouting(method: method, params: params)
        if let storeEvent {
            await MainActor.run {
                store.dispatch(storeEvent)
            }
        }

        await notificationRouter.route(notification)

        // The server resolved a pending approval itself (e.g. the turn was
        // interrupted). Release any suspended reply and clear the store entry.
        if method == CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
           let requestIdValue = params["requestId"] {
            let requestKey = requestIdValue.description
            if !resolveApproval(requestId: requestKey, decision: .cancel) {
                resolveUserInput(requestId: requestKey, answers: [:])
            }
        }

        if method == CodexAppServerNotificationMethod.commandExecOutputDelta.rawValue {
            guard let route = outputDeltaRoute(params: params, targetIDKey: "processId"),
                  let session = activeCommandSessions[route.targetID] else { return }
            await session.receiveOutput(
                streamName: route.stream,
                base64Data: route.base64Data,
                capReached: route.capReached
            )
            return
        }

        if storeEvent != nil {
            return
        }
    }

    private func outputDeltaRoute(
        params: [String: CodexJSONValue],
        targetIDKey: String
    ) -> CodexOutputDeltaRoute? {
        guard case .string(let targetID)? = params[targetIDKey],
              case .string(let stream)? = params["stream"],
              case .string(let base64Data)? = params["deltaBase64"] else {
            return nil
        }

        return CodexOutputDeltaRoute(
            targetID: targetID,
            stream: stream,
            base64Data: base64Data,
            capReached: boolParam(params["capReached"])
        )
    }

    private func storeEventBeforeRouting(method: String, params: [String: CodexJSONValue]) -> CodexServerEvent? {
        switch method {
        case CodexAppServerNotificationMethod.commandExecOutputDelta.rawValue,
             CodexAppServerNotificationMethod.serverRequestResolved.rawValue,
             "remoteControl/status/changed",
             "mcpServer/startupStatus/updated",
             "account/login/completed",
             "skills/changed":
            return nil
        default:
            return mapNotificationToEvent(method: method, params: params)
        }
    }

    private func mapNotificationToEvent(method: String, params: [String: CodexJSONValue]) -> CodexServerEvent {
        func str(_ key: String) -> String { params[key]?.description ?? "" }
        func nestedStr(_ outer: String, _ inner: String) -> String {
            if case .dictionary(let d) = params[outer] { return d[inner]?.description ?? "" }
            return ""
        }
        func nestedValue(_ outer: String, _ inner: String) -> CodexJSONValue? {
            if case .dictionary(let d) = params[outer] { return d[inner] }
            return nil
        }
        func stringValue(_ value: CodexJSONValue?) -> String? {
            switch value {
            case .string(let string): return nilIfEmpty(string)
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array(let values):
                let parts = values.compactMap(stringValue)
                return nilIfEmpty(parts.joined(separator: " "))
            case .dictionary(let object):
                return stringValue(object["type"])
                    ?? stringValue(object["message"])
                    ?? stringValue(object["text"])
            case .null, nil:
                return nil
            }
        }
        func fileChangePatch() -> (path: String?, patch: String) {
            guard case .array(let changes)? = params["changes"] else {
                return (stringValue(params["path"]), stringValue(params["patch"]) ?? stringValue(params["diff"]) ?? "")
            }
            var path: String?
            var diffs: [String] = []
            for changeValue in changes {
                guard case .dictionary(let change) = changeValue else { continue }
                path = path ?? stringValue(change["path"])
                if let diff = stringValue(change["diff"]), !diff.isEmpty {
                    diffs.append(diff)
                }
            }
            return (path, diffs.joined(separator: "\n"))
        }
        func extractThreadId() -> String {
            let direct = str("threadId")
            if !direct.isEmpty { return direct }
            return nestedStr("thread", "id")
        }
        func extractTurnId() -> String {
            let direct = str("turnId")
            if !direct.isEmpty { return direct }
            return nestedStr("turn", "id")
        }
        func extractThreadStatus() -> String {
            if case .string(let direct) = params["status"], !direct.isEmpty { return direct }
            if case .dictionary(let thread) = params["thread"],
               case .dictionary(let s) = thread["status"],
               case .string(let t) = s["type"] { return t }
            if case .dictionary(let s) = params["status"],
               case .string(let t) = s["type"] { return t }
            return "active"
        }

        let threadId = extractThreadId()
        let turnId = extractTurnId()
        let itemId = str("itemId")

        switch method {
        case "thread/started":
            return .threadStarted(threadId: threadId, name: nilIfEmpty(nestedStr("thread", "name")) ?? params["name"]?.description, status: extractThreadStatus())

        case "thread/status/changed":
            return .threadStatusChanged(threadId: threadId, status: extractThreadStatus())

        case CodexAppServerNotificationMethod.accountUpdated.rawValue:
            if let payload = try? params.decode(CodexSchemaAccountUpdatedNotification.self) {
                return .accountUpdated(payload)
            }
            return .unknown(method: method, params: params)

        case CodexAppServerNotificationMethod.accountRateLimitsUpdated.rawValue:
            if let payload = try? params.decode(CodexSchemaAccountRateLimitsUpdatedNotification.self) {
                return .accountRateLimitsUpdated(payload)
            }
            return .unknown(method: method, params: params)

        case "thread/goal/updated":
            if let payload = try? params.decode(ThreadGoalUpdatedNotification.self) {
                return .threadGoalUpdated(threadId: payload.threadId, goal: payload.goal)
            }
            return .unknown(method: method, params: params)

        case "thread/goal/cleared":
            return .threadGoalCleared(threadId: threadId)

        case "turn/started":
            return .turnStarted(threadId: threadId, turnId: turnId)

        case "turn/completed":
            let error = optionalString(params["error"]) ?? optionalString(nestedValue("turn", "error"))
            return .turnCompleted(threadId: threadId, turnId: turnId, error: error)

        case "item/started":
            return decodeItem(params).map { .itemStarted(threadId: threadId, turnId: turnId, item: $0) } ?? .unknown(method: method, params: params)

        case "item/completed":
            return decodeItem(params).map { .itemCompleted(threadId: threadId, turnId: turnId, item: $0) } ?? .unknown(method: method, params: params)

        case "item/agentMessage/delta", "item/message/delta":
            return .messageDelta(threadId: threadId, turnId: turnId, itemId: itemId, delta: str("delta"))

        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            return .reasoningDelta(threadId: threadId, turnId: turnId, itemId: itemId, delta: str("delta"))

        case "item/plan/delta":
            return .planDelta(threadId: threadId, turnId: turnId, itemId: itemId, delta: str("delta"))

        case "item/commandExecution/outputDelta":
            return .commandOutputDelta(threadId: threadId, turnId: turnId, itemId: itemId, delta: str("delta"))

        case "item/commandExecution/terminalInteraction":
            let stdin = str("stdin")
            guard !stdin.isEmpty else { return .unknown(method: method, params: params) }
            return .commandOutputDelta(
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                delta: "\n$ \(stdin)"
            )

        case "item/fileChange/outputDelta":
            return .fileChangeOutputDelta(threadId: threadId, turnId: turnId, itemId: itemId, delta: str("delta"))

        case "item/fileChange/patchUpdated":
            let patch = fileChangePatch()
            return .fileChangePatchUpdated(threadId: threadId, turnId: turnId, itemId: itemId, path: patch.path, patch: patch.patch)

        case "item/mcpToolCall/progress":
            return .mcpToolCallProgress(threadId: threadId, turnId: turnId, itemId: itemId, message: str("message"))

        case CodexAppServerNotificationMethod.turnPlanUpdated.rawValue:
            if let payload = try? params.decode(TurnPlanUpdatedNotification.self) {
                return .turnPlanUpdated(threadId: payload.threadId, turnId: payload.turnId, plan: payload.plan, explanation: payload.explanation)
            }
            return .unknown(method: method, params: params)

        case CodexAppServerNotificationMethod.turnDiffUpdated.rawValue:
            if let payload = try? params.decode(TurnDiffUpdatedNotification.self) {
                return .turnDiffUpdated(threadId: payload.threadId, turnId: payload.turnId, diff: payload.diff)
            }
            return .unknown(method: method, params: params)

        case "thread/tokenUsage/updated":
            return extractTokenUsage(params, threadId: threadId, turnId: turnId.isEmpty ? nil : turnId)

        case "error":
            return .serverError(message: str("message"), threadId: threadId.isEmpty ? nil : threadId)

        default:
            break
        }

        return .unknown(method: method, params: params)
    }

    private func decodeItem(_ params: [String: CodexJSONValue]) -> CodexServerItem? {
        guard let itemVal = params["item"],
              let data = try? JSONEncoder().encode(itemVal) else { return nil }
        // Try with explicit fields first, fall back to raw passthrough
        if let item = try? JSONDecoder().decode(CodexServerItem.self, from: data) { return item }
        // If that fails, wrap in a minimal item with raw passthrough
        guard let raw = try? JSONDecoder().decode([String: CodexJSONValue].self, from: data) else { return nil }
        let id = (raw["id"]?.description) ?? UUID().uuidString
        let type = raw["type"]?.description ?? "unknown"
        return CodexServerItem(id: id, type: type, raw: raw)
    }

    private func extractTokenUsage(_ params: [String: CodexJSONValue], threadId: String, turnId: String?) -> CodexServerEvent {
        if let tokenUsage = params["tokenUsage"], let usage = try? tokenUsage.decode(ThreadTokenUsage.self) {
            return .tokenUsageUpdated(threadId: threadId, turnId: turnId, usage: usage)
        }
        if case .int(let used) = params["used"], case .int(let limit) = params["limit"] {
            return .tokenUsageUpdated(threadId: threadId, turnId: turnId, usage: ThreadTokenUsage(raw: ["used": .int(used), "limit": .int(limit)]))
        }
        return .unknown(method: "thread/tokenUsage/updated", params: params)
    }

    private func nilIfEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private func boolParam(_ value: CodexJSONValue?) -> Bool {
        if case .bool(let flag)? = value { return flag }
        return false
    }

    private func intParam(_ value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int)?: return int
        case .double(let double)?: return Int(double)
        case .string(let string)?: return Int(string)
        default: return nil
        }
    }

    private func completeCommandSession(processId: String, result: CodexCommandExecResult) async {
        await activeCommandSessions[processId]?.complete(result)
        activeCommandSessions.removeValue(forKey: processId)
    }

    private func failCommandSession(processId: String, error: Error) async {
        await activeCommandSessions[processId]?.fail(error)
        activeCommandSessions.removeValue(forKey: processId)
    }

    private func optionalString(_ value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let s):
            return nilIfEmpty(s)
        default:
            return nilIfEmpty(value.description)
        }
    }
}
