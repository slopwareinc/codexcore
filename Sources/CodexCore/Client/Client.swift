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

// MARK: - CodexClient

public actor CodexClient {
    private let connection: CodexConnection
    private let store: CodexCoreStore

    // Track active PTY process sessions by process handle
    private var activeSessions: [String: CodexProcessSession] = [:]
    private var activeCommandSessions: [String: CodexCommandExecSession] = [:]

    public init(transport: any CodexTransport, store: CodexCoreStore) {
        self.connection = CodexConnection(transport: transport)
        self.store = store
    }

    /// Establishes the connection and performs the initialize handshake.
    public func connect(
        clientName: String = "CodexCoreSwift",
        clientTitle: String = "Codex Core Swift Native SDK",
        clientVersion: String = "1.0.0"
    ) async throws {
        try await connection.start(
            clientName: clientName,
            clientTitle: clientTitle,
            clientVersion: clientVersion,
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

    /// Closes the client connection.
    public func disconnect() async {
        await connection.stop()
    }

    // MARK: - Thread & Turn APIs

    /// Creates a new conversation thread on the app-server using `thread/start`.
    /// Returns the thread ID.
    @discardableResult
    public func createThread(cwd: String, model: String? = nil) async throws -> String {
        var params: [String: CodexJSONValue] = ["cwd": .string(cwd)]
        if let model {
            params["model"] = .string(model)
        }

        return try await startThread(params: params)
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
        let method = serverRequest.method
        let params = serverRequest.params

        switch method {
        case "item/commandExecution/requestApproval":
            // Auto-approve with "acceptForSession" decision — store will surface this to UI
            let threadId = params["threadId"]?.description ?? ""
            let turnId = params["turnId"]?.description ?? ""
            let itemId = params["itemId"]?.description ?? ""
            let command = params["command"]?.description
            let cwd = params["cwd"]?.description
            let reason = params["reason"]?.description

            let req = CodexApprovalRequest(
                requestId: .int(Int(serverRequest.id)),
                kind: .command,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                command: command,
                cwd: cwd,
                reason: reason
            )

            await MainActor.run {
                store.dispatchRequest(req)
            }

            // Auto-approve: respond with {decision: "acceptForSession"}
            return .dictionary(["decision": .string("acceptForSession")])

        case "item/fileChange/requestApproval":
            let threadId = params["threadId"]?.description ?? ""
            let turnId = params["turnId"]?.description ?? ""
            let itemId = params["itemId"]?.description ?? ""
            let command = params["command"]?.description
            let path = params["path"]?.description
            let grantRoot = params["grantRoot"]?.description
            let cwd = params["cwd"]?.description
            let reason = params["reason"]?.description

            let req = CodexApprovalRequest(
                requestId: .int(Int(serverRequest.id)),
                kind: .fileChange,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                command: command,
                path: path,
                grantRoot: grantRoot,
                cwd: cwd,
                reason: reason
            )

            await MainActor.run {
                store.dispatchRequest(req)
            }

            // Auto-approve file changes
            return .dictionary(["decision": .string("acceptForSession")])

        case "item/permissions/requestApproval":
            // Auto-approve permissions
            return .dictionary(["decision": .string("accept")])

        default:
            print("[CodexClient] Unhandled server request: \(method)")
            // Default: return empty object
            return .dictionary([:])
        }
    }

    // MARK: - Server Notification Handling

    private func handleNotification(_ notification: JSONRPCNotification) async {
        let method = notification.method
        let params = notification.params ?? [:]

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
        case "remoteControl/status/changed", "mcpServer/startupStatus/updated", "account/rateLimits/updated":
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
            return extractTokenUsage(params, threadId: threadId)

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

    private func extractTokenUsage(_ params: [String: CodexJSONValue], threadId: String) -> CodexServerEvent {
        if case .int(let used) = params["used"], case .int(let limit) = params["limit"] {
            return .tokenUsageUpdated(threadId: threadId, used: used, limit: limit)
        }
        if case .dictionary(let tu) = params["tokenUsage"],
           case .dictionary(let total) = tu["total"],
           case .int(let used) = total["inputTokens"] ?? total["outputTokens"] ?? total["totalTokens"],
           case .int(let limit) = tu["maxTokens"] ?? tu["contextLimit"] ?? .int(128_000) {
            return .tokenUsageUpdated(threadId: threadId, used: used, limit: limit)
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
