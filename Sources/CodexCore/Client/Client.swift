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

// MARK: - CodexClient

public actor CodexClient {
    private let connection: CodexConnection
    private let store: CodexCoreStore
    private let serverRequestHandler: CodexServerRequestHandler?
    public nonisolated let notificationRouter: CodexNotificationRouter

    // Track active PTY process sessions by process handle
    private var activeSessions: [String: CodexProcessSession] = [:]
    private var activeCommandSessions: [String: CodexCommandExecSession] = [:]

    public init(
        transport: any CodexTransport,
        store: CodexCoreStore,
        notificationRouter: CodexNotificationRouter = CodexNotificationRouter(),
        serverRequestHandler: CodexServerRequestHandler? = nil
    ) {
        self.connection = CodexConnection(transport: transport)
        self.store = store
        self.serverRequestHandler = serverRequestHandler
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
        experimentalApi: Bool = true
    ) async throws -> InitializeResponse {
        try await connection.start(
            clientName: clientName,
            clientTitle: clientTitle,
            clientVersion: clientVersion,
            experimentalApi: experimentalApi,
            onNotification: { [weak self] notification in
                guard let self else { return }
                Task {
                    await self.handleNotification(notification)
                }
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

    public func notify(method: String, params: [String: CodexJSONValue] = [:]) async throws {
        try await connection.notify(method: method, params: params)
    }

    public func waitForTurnCompleted(turnId: String) async throws -> TurnCompletedNotification {
        await notificationRouter.registerTurn(turnId)
        defer { Task { await self.notificationRouter.unregisterTurn(turnId) } }

        for await notification in turnNotifications(turnId: turnId) {
            if case .turnCompleted(let payload) = notification.payload, payload.turn.id == turnId {
                return payload
            }
        }

        throw CodexSDKError.turnStreamEnded(turnId: turnId)
    }

    public func waitForLoginCompleted(loginId: String) async throws -> AccountLoginCompletedNotification {
        await notificationRouter.registerLogin(loginId)
        defer { Task { await self.notificationRouter.unregisterLogin(loginId) } }

        for await notification in loginNotifications(loginId: loginId) {
            if case .accountLoginCompleted(let payload) = notification.payload, payload.loginId == loginId {
                return payload
            }
        }

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

    public func threadFork(threadId: String, params: ThreadForkParams = ThreadForkParams()) async throws -> ThreadForkResponse {
        var payload = params
        payload.threadId = threadId
        return try await connection.request(
            method: CodexAppServerClientMethod.threadFork.rawValue,
            params: payload,
            response: ThreadForkResponse.self
        )
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
        try await connection.request(
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
                    let turnId = try await self.startTurn(
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

    public func modelList(includeHidden: Bool = false) async throws -> ModelListResponse {
        try await connection.request(
            method: CodexAppServerClientMethod.modelList.rawValue,
            params: ["includeHidden": CodexJSONValue.bool(includeHidden)],
            response: ModelListResponse.self
        )
    }

    /// Closes the client connection.
    public func disconnect() async {
        await connection.stop()
    }

    // MARK: - Thread & Turn APIs

    /// Creates a new conversation thread on the app-server using `thread/start`.
    /// Returns the thread ID.
    @discardableResult
    public func createThread(cwd: String, model: String? = nil) async throws -> String {
        let response = try await threadStart(ThreadStartParams(cwd: cwd, model: model))
        return response.thread.id
    }

    /// Creates or starts a thread with raw app-server `thread/start` params.
    @discardableResult
    public func startThread(params: [String: CodexJSONValue] = [:]) async throws -> String {

        // thread/start returns {thread: {id: "..."}, model: "...", cwd: "...", ...}
        let result = try await connection.request(method: "thread/start", params: params)

        guard case .dictionary(let dict) = result,
              let threadVal = dict["thread"],
              case .dictionary(let threadDict) = threadVal,
              let idVal = threadDict["id"],
              case .string(let threadId) = idVal else {
            throw JSONRPCError(code: -32603, message: "Invalid thread/start response: \(result)", data: nil)
        }

        await MainActor.run {
            store.dispatch(.threadStarted(threadId: threadId, name: nil, status: "idle"))
        }

        return threadId
    }

    /// Starts a turn on the thread using `turn/start` with a text `input` array.
    /// Returns the turn ID.
    @discardableResult
    public func startTurn(threadId: String, userPrompt: String) async throws -> String {
        let inputItem: CodexJSONValue = .dictionary([
            "type": .string("text"),
            "text": .string(userPrompt)
        ])

        return try await startTurn(threadId: threadId, input: [inputItem])
    }

    /// Starts a turn with pre-normalized Codex wire input items.
    @discardableResult
    public func startTurn(
        threadId: String,
        input: [CodexJSONValue],
        additionalParams: [String: CodexJSONValue] = [:]
    ) async throws -> String {
        // turn/start takes: {threadId, input: [{type: "text", text: "..."}]}
        var params = additionalParams
        params["threadId"] = .string(threadId)
        params["input"] = .array(input)

        // turn/start returns {turn: {id: "...", ...}}
        let result = try await connection.request(method: "turn/start", params: params)

        guard case .dictionary(let dict) = result,
              let turnVal = dict["turn"],
              case .dictionary(let turnDict) = turnVal,
              let idVal = turnDict["id"],
              case .string(let turnId) = idVal else {
            throw JSONRPCError(code: -32603, message: "Invalid turn/start response: \(result)", data: nil)
        }

        await MainActor.run {
            store.dispatch(.turnStarted(threadId: threadId, turnId: turnId))
        }
        await notificationRouter.registerTurn(turnId)

        return turnId
    }

    @discardableResult
    public func interruptTurn(threadId: String, turnId: String) async throws -> CodexJSONValue {
        try await connection.request(
            method: "turn/interrupt",
            params: ["threadId": .string(threadId), "turnId": .string(turnId)]
        )
    }

    @discardableResult
    public func steerTurn(threadId: String, expectedTurnId: String, input: [CodexJSONValue]) async throws -> CodexJSONValue {
        try await connection.request(
            method: "turn/steer",
            params: [
                "threadId": .string(threadId),
                "expectedTurnId": .string(expectedTurnId),
                "input": .array(input)
            ]
        )
    }

    // MARK: - Process & Interactive Terminal APIs

    /// Spawns a host process attached to a PTY terminal session.
    public func spawnProcess(
        command: [String],
        cwd: String,
        environment: [String: String]? = nil,
        initialSize: PTYSize? = nil
    ) async throws -> CodexProcessSession {
        let handle = UUID().uuidString

        let session = CodexProcessSession(processHandle: handle, connection: connection)
        activeSessions[handle] = session

        var params: [String: CodexJSONValue] = [
            "command": .array(command.map { .string($0) }),
            "processHandle": .string(handle),
            "cwd": .string(cwd),
            "tty": .bool(true),
            "streamStdin": .bool(true),
            "streamStdoutStderr": .bool(true)
        ]

        if let env = environment {
            let envDict = env.mapValues { CodexJSONValue.string($0) }
            params["env"] = .dictionary(envDict)
        }

        if let size = initialSize {
            params["size"] = .dictionary([
                "rows": .int(size.rows),
                "cols": .int(size.cols)
            ])
        }

        _ = try await connection.request(method: "process/spawn", params: params)

        return session
    }

    // MARK: - Official command/exec APIs

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

        let result = try await connection.request(method: "command/exec", params: params)
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
                let value = try await connection.request(method: "command/exec", params: params)
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

            await MainActor.run {
                store.dispatchRequest(req)
            }

            return .dictionary(["decision": .string("accept")])

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

            await MainActor.run {
                store.dispatchRequest(req)
            }

            return .dictionary(["decision": .string("accept")])

        case .itemToolRequestUserInput:
            let questions = parseUserInputQuestions(params["questions"])
            let req = CodexUserInputRequest(
                requestId: requestId,
                threadId: str("threadId"),
                turnId: str("turnId"),
                itemId: str("itemId"),
                questions: questions
            )
            await MainActor.run {
                store.dispatchRequest(req)
            }
            return .dictionary(["answers": .dictionary([:])])

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
            await MainActor.run {
                store.dispatchRequest(req)
            }
            return .dictionary([
                "permissions": .dictionary([:]),
                "scope": .string("turn")
            ])

        case .itemToolCall:
            return .dictionary([
                "contentItems": .array([]),
                "success": .bool(false)
            ])

        case .accountChatgptAuthTokensRefresh, .attestationGenerate:
            return .dictionary([:])

        case .applyPatchApproval, .execCommandApproval:
            return .dictionary(["decision": .string("approved")])
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
        await notificationRouter.route(notification)

        // Route 1: PTY standard output chunks
        if method == "process/outputDelta" {
            guard let handleVal = params["processHandle"],
                  case .string(let handle) = handleVal,
                  let streamVal = params["stream"],
                  case .string(let stream) = streamVal,
                  let base64Val = params["deltaBase64"],
                  case .string(let base64) = base64Val else { return }
            let capReached = params["capReached"]?.description == "true"

            activeSessions[handle]?.receiveOutput(streamName: stream, base64Data: base64, capReached: capReached)
            return
        }

        // Route 2: PTY process exited
        if method == "process/exited" {
            guard let handleVal = params["processHandle"],
                  case .string(let handle) = handleVal,
                  let codeStr = params["exitCode"],
                  let code = Int32(codeStr.description) else { return }

            activeSessions[handle]?.handleExit(exitCode: code)
            activeSessions.removeValue(forKey: handle)
            return
        }

        // Route 3: Official command/exec output chunks
        if method == "command/exec/outputDelta" {
            guard let idVal = params["processId"],
                  case .string(let processId) = idVal,
                  let streamVal = params["stream"],
                  case .string(let stream) = streamVal,
                  let base64Val = params["deltaBase64"],
                  case .string(let base64) = base64Val else { return }
            let capReached: Bool
            if case .bool(let value) = params["capReached"] {
                capReached = value
            } else {
                capReached = params["capReached"]?.description == "true"
            }

            activeCommandSessions[processId]?.receiveOutput(streamName: stream, base64Data: base64, capReached: capReached)
            return
        }

        // Route 4: Standard timeline notifications (Thread/Turn events)
        // Skip lifecycle noise that carries no timeline state
        switch method {
        case "remoteControl/status/changed", "mcpServer/startupStatus/updated", "account/rateLimits/updated", "account/login/completed":
            return
        default:
            break
        }

        let event = mapNotificationToEvent(method: method, params: params)
        await MainActor.run {
            store.dispatch(event)
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

    private func completeCommandSession(processId: String, result: CodexCommandExecResult) {
        activeCommandSessions[processId]?.complete(result)
        activeCommandSessions.removeValue(forKey: processId)
    }

    private func failCommandSession(processId: String, error: Error) {
        activeCommandSessions[processId]?.fail(error)
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
