import Foundation

// MARK: - JSON-RPC Wire Models

public struct JSONRPCRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public let id: Int64?
    public let method: String
    public let params: CodexJSONValue?

    public init(id: Int64?, method: String, params: CodexJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String?
    public let id: Int64?
    public let result: CodexJSONValue?
    public let error: JSONRPCError?
}

public struct JSONRPCError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: CodexJSONValue?
}

public struct JSONRPCNotification: Codable, Sendable {
    public let jsonrpc: String?
    public let method: String
    public let params: [String: CodexJSONValue]?
}

public enum CodexConnectionError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case closed
    case transportFailed(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .closed:
            return "Codex connection closed"
        case .transportFailed(let message):
            return "Codex transport failed: \(message)"
        case .decodeFailed(let message):
            return "Codex connection decode failed: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

private final class CodexIncomingMessageSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: Int64 = 0

    func claimSequence() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        return sequence
    }
}

private struct CodexPendingRequest {
    let continuation: CheckedContinuation<CodexJSONValue, Error>
    let isHandshake: Bool
}

// A server→client request (server sends id + method, client must reply with a result/error)
public struct JSONRPCServerRequest: Sendable {
    public let id: CodexJSONValue
    public let method: String
    public let params: [String: CodexJSONValue]

    public init(id: CodexJSONValue, method: String, params: [String: CodexJSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

// MARK: - CodexConnection Actor

public actor CodexConnection {
    private let transport: any CodexTransport
    private let reconnectionManager: CodexReconnectionManager
    private let incomingSequencer = CodexIncomingMessageSequencer()

    private var isInitialized = false
    private var pendingNotifications: [JSONRPCNotification] = []
    private var pendingIncomingMessages: [Int64: String] = [:]
    private var nextIncomingMessageSequence: Int64 = 0
    private var pendingRequests: [Int64: CodexPendingRequest] = [:]
    private var requestIdCounter: Int64 = 0

    // Callbacks for notification and server-request dispatching
    private var onNotification: (@Sendable (JSONRPCNotification) -> Void)?
    private var onServerRequest: (@Sendable (JSONRPCServerRequest) async -> CodexJSONValue)?

    public init(transport: any CodexTransport) {
        self.transport = transport
        self.reconnectionManager = CodexReconnectionManager(transport: transport)
    }

    init(
        transport: any CodexTransport,
        reconnectSleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.transport = transport
        self.reconnectionManager = CodexReconnectionManager(
            transport: transport,
            sleep: reconnectSleep
        )
    }

    /// Starts the connection and performs the initialize handshake, buffering notifications.
    @discardableResult
    public func start(
        clientName: String = "CodexCoreSwift",
        clientTitle: String = "Codex Core Swift Native SDK",
        clientVersion: String = "1.0.0",
        experimentalAPI: Bool = true,
        capabilities: InitializeCapabilities? = nil,
        onNotification: @escaping @Sendable (JSONRPCNotification) -> Void,
        onServerRequest: @escaping @Sendable (JSONRPCServerRequest) async -> CodexJSONValue
    ) async throws -> InitializeResponse {
        self.onNotification = onNotification
        self.onServerRequest = onServerRequest

        await reconnectionManager.configure(
            onMessage: { [weak self] msg in
                guard let self else { return }
                let sequence = self.incomingSequencer.claimSequence()
                Task {
                    await self.enqueueIncomingMessage(msg, sequence: sequence)
                }
            },
            onError: { err in
                print("[CodexConnection] Connection error: \(err)")
            },
            onDisconnect: { [weak self] err in
                await self?.handleTransportError(err)
            },
            beforeReplay: { [weak self] in
                guard let self else { return }
                _ = try await self.performInitializeHandshake(
                    clientName: clientName,
                    clientTitle: clientTitle,
                    clientVersion: clientVersion,
                    experimentalAPI: experimentalAPI,
                    capabilities: capabilities
                )
            },
            onReconnected: {}
        )

        try await reconnectionManager.startAwaitingHandshake()

        do {
            let response = try await performInitializeHandshake(
                clientName: clientName,
                clientTitle: clientTitle,
                clientVersion: clientVersion,
                experimentalAPI: experimentalAPI,
                capabilities: capabilities
            )
            try await reconnectionManager.completeInitialHandshake()
            return response
        } catch {
            await failPendingRequests(error)
            await transport.stop()
            throw error
        }
    }

    private func enqueueIncomingMessage(_ message: String, sequence: Int64) {
        pendingIncomingMessages[sequence] = message
        while let next = pendingIncomingMessages.removeValue(forKey: nextIncomingMessageSequence) {
            nextIncomingMessageSequence += 1
            handleIncomingMessage(next)
        }
    }

    /// Stop the transport connection.
    public func stop() async {
        await failPendingRequests(CodexConnectionError.closed)
        await transport.stop()
    }

    /// Send a strongly-typed JSON-RPC request and wait for the response.
    public func request(method: String) async throws -> CodexJSONValue {
        try await sendRequest(method: method, params: nil)
    }

    /// Send a strongly-typed JSON-RPC request and wait for the response.
    public func request(method: String, params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        try await sendRequest(method: method, params: .dictionary(params))
    }

    private func sendRequest(method: String, params: CodexJSONValue?) async throws -> CodexJSONValue {
        try await sendRequest(method: method, params: params, isHandshake: false)
    }

    private func sendRequest(
        method: String,
        params: CodexJSONValue?,
        isHandshake: Bool
    ) async throws -> CodexJSONValue {
        requestIdCounter += 1
        let requestId = requestIdCounter

        let req = JSONRPCRequest(id: requestId, method: method, params: params)
        let payload = try encodeRequest(req)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = CodexPendingRequest(
                continuation: continuation,
                isHandshake: isHandshake
            )

            Task {
                guard pendingRequests[requestId] != nil else { return }
                do {
                    if isHandshake {
                        try await reconnectionManager.sendHandshake(payload)
                    } else {
                        try await reconnectionManager.sendOrBuffer(payload)
                    }
                    if pendingRequests[requestId] == nil {
                        await reconnectionManager.discardBufferedRequests(ids: [requestId])
                    }
                } catch {
                    failPendingRequest(id: requestId, error: error)
                }
            }
        }
    }

    /// Send a raw notification frame to the daemon (no id → no response expected).
    public func notify(method: String, params: [String: CodexJSONValue] = [:]) async throws {
        let req = JSONRPCRequest(id: nil, method: method, params: params.isEmpty ? nil : .dictionary(params))
        let payload = try encodeRequest(req)
        try await reconnectionManager.sendOrBuffer(payload)
    }

    /// Reply to a server-originated request (with result).
    public func reply(id: CodexJSONValue, result: CodexJSONValue) async throws {
        let payload: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]
        // Encode directly; no need for JSONRPCRequest
        try await reconnectionManager.sendOrBuffer(payload)
    }

    // MARK: - Internal Handshake & Message Router

    private func performInitializeHandshake(
        clientName: String,
        clientTitle: String,
        clientVersion: String,
        experimentalAPI: Bool,
        capabilities: InitializeCapabilities?
    ) async throws -> InitializeResponse {
        isInitialized = false

        // Build nested params as CodexJSONValue.dictionary — NOT double-encoded
        var negotiatedCapabilities = capabilities ?? InitializeCapabilities()
        if negotiatedCapabilities.experimentalAPI == nil {
            negotiatedCapabilities.experimentalAPI = experimentalAPI
        }
        if negotiatedCapabilities.requestAttestation == nil {
            negotiatedCapabilities.requestAttestation = false
        }
        let params: [String: CodexJSONValue] = [
            "clientInfo": .dictionary([
                "name": .string(clientName),
                "version": .string(clientVersion),
                "title": .string(clientTitle)
            ]),
            "capabilities": try CodexJSONValue(encoding: negotiatedCapabilities)
        ]

        let result = try await sendRequest(
            method: "initialize",
            params: .dictionary(params),
            isHandshake: true
        )
        let response = try result.decode(InitializeResponse.self)

        let initialized = try encodeRequest(JSONRPCRequest(id: nil, method: "initialized"))
        try await reconnectionManager.sendHandshake(initialized)

        isInitialized = true
        flushPendingNotifications()
        return response
    }

    private func handleIncomingMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        let decoder = JSONDecoder()

        guard let payload = try? decoder.decode([String: CodexJSONValue].self, from: data) else {
            print("[CodexConnection] Failed to parse payload: \(message.prefix(200))")
            return
        }

        let hasMethod = payload["method"] != nil
        let hasId = payload["id"] != nil

        // Server→client request: has both "method" and "id"
        if hasMethod && hasId {
            guard let methodVal = payload["method"],
                  case .string(let method) = methodVal,
                  let idVal = payload["id"] else { return }

            var params: [String: CodexJSONValue] = [:]
            if let paramsVal = payload["params"], case .dictionary(let d) = paramsVal {
                params = d
            }

            let serverRequest = JSONRPCServerRequest(id: idVal, method: method, params: params)
            let handler = self.onServerRequest

            Task {
                let result = await handler?(serverRequest) ?? .null
                try? await self.reply(id: idVal, result: result)
            }
            return
        }

        // Notification: has "method" but no "id"
        if hasMethod && !hasId {
            if let notification = try? decoder.decode(JSONRPCNotification.self, from: data) {
                if !isInitialized {
                    pendingNotifications.append(notification)
                } else {
                    onNotification?(notification)
                }
            } else {
                print("[CodexConnection] Failed to decode notification: \(message.prefix(200))")
            }
            return
        }

        // Response: has "id" and either "result" or "error"
        if hasId {
            if let response = try? decoder.decode(JSONRPCResponse.self, from: data) {
                if let requestId = response.id, let pending = pendingRequests.removeValue(forKey: requestId) {
                    if let error = response.error {
                        pending.continuation.resume(throwing: error.mappedError)
                    } else {
                        pending.continuation.resume(returning: response.result ?? .null)
                    }
                }
            } else if let requestId = payload["id"].flatMap(requestId(from:)) {
                failPendingRequest(
                    id: requestId,
                    error: CodexConnectionError.decodeFailed(String(message.prefix(200)))
                )
            }
            return
        }

        print("[CodexConnection] Unrecognized packet: \(message.prefix(200))")
    }

    private func flushPendingNotifications() {
        let notifications = pendingNotifications
        pendingNotifications.removeAll()

        for notification in notifications {
            onNotification?(notification)
        }
    }

    private func failPendingRequests(
        _ error: Error,
        excluding preservedRequestIDs: Set<Int64> = []
    ) async {
        let requests = pendingRequests.filter { !preservedRequestIDs.contains($0.key) }
        for requestID in requests.keys {
            pendingRequests.removeValue(forKey: requestID)
        }
        for pending in requests.values {
            pending.continuation.resume(throwing: error)
        }
        await reconnectionManager.discardBufferedRequests(ids: Set(requests.keys))
    }

    private func handleTransportError(_ error: Error) async {
        let mapped = CodexConnectionError.transportFailed(String(describing: error))
        if isInitialized {
            isInitialized = false
            let bufferedRequestIDs = await reconnectionManager.bufferedRequestIDs()
            await failPendingRequests(mapped, excluding: bufferedRequestIDs)
            return
        }

        let handshakeRequestIDs = pendingRequests.compactMap { id, pending in
            pending.isHandshake ? id : nil
        }
        for requestID in handshakeRequestIDs {
            failPendingRequest(id: requestID, error: mapped)
        }
    }

    private func failPendingRequest(id: Int64, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: error)
    }

    private func requestId(from value: CodexJSONValue) -> Int64? {
        switch value {
        case .int(let intValue):
            return Int64(intValue)
        case .double(let doubleValue):
            return Int64(doubleValue)
        case .string(let stringValue):
            return Int64(stringValue)
        default:
            return nil
        }
    }

    private func encodeRequest(_ req: JSONRPCRequest) throws -> [String: CodexJSONValue] {
        // Build the payload manually to avoid double-encoding
        var payload: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(req.method)
        ]
        if let id = req.id {
            payload["id"] = .int(Int(id))
        }
        if let params = req.params {
            payload["params"] = params
        }
        return payload
    }
}
