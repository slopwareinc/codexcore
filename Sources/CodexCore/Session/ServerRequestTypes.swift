import Foundation

/// The JSON-RPC identifier of a server-originated request.
///
/// JSON-RPC permits string and integer identifiers. They are deliberately
/// represented as different enum cases: the wire identifiers `7` and `"7"`
/// name different requests and must never collide in the pending inbox.
public enum CodexServerRequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    case integer(Int64)
    case string(String)

    public init(jsonValue: CodexJSONValue) throws {
        switch jsonValue {
        case .int(let value):
            self = .integer(Int64(value))
        case .string(let value):
            self = .string(value)
        default:
            throw CodexServerRequestIDError.invalidJSONRPCIdentifier(jsonValue)
        }
    }

    public var jsonValue: CodexJSONValue {
        switch self {
        case .integer(let value):
            // CodexCore currently supports 64-bit Apple platforms, where
            // Swift.Int can losslessly represent the JSON-RPC integer range.
            return .int(Int(value))
        case .string(let value):
            return .string(value)
        }
    }

    public var description: String {
        switch self {
        case .integer(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSON-RPC request id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

public enum CodexServerRequestIDError: Error, Sendable, Equatable {
    case invalidJSONRPCIdentifier(CodexJSONValue)
}

/// A request identifier is scoped to a transport connection. Including the
/// epoch permits a newly connected server to reuse an id without colliding
/// with a terminal request retained from the previous connection.
public struct CodexServerRequestKey: Hashable, Sendable, Codable {
    public let connectionEpoch: UInt64
    public let requestID: CodexServerRequestID

    public init(connectionEpoch: UInt64, requestID: CodexServerRequestID) {
        self.connectionEpoch = connectionEpoch
        self.requestID = requestID
    }
}

/// Protocol coordinates used to cancel requests with their owning turn and to
/// place a sanitized request in the correct presentation projection.
public struct CodexServerRequestScope: Hashable, Sendable, Codable {
    public let threadID: String?
    public let turnID: String?
    public let itemID: String?

    public init(threadID: String? = nil, turnID: String? = nil, itemID: String? = nil) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }
}

/// Stable logical identity for command approval callbacks. `approvalId` is not
/// a JSON-RPC request id; retaining both identities allows a host to correlate
/// repeated callbacks without accidentally replying to the wrong wire request.
public struct CodexApprovalCorrelation: Hashable, Sendable, Codable {
    public let threadID: String
    public let approvalID: String

    public init(threadID: String, approvalID: String) {
        self.threadID = threadID
        self.approvalID = approvalID
    }
}

/// Typed classification of every server-originated request in the pinned
/// app-server protocol. Unknown methods remain representable so protocol
/// evolution never forces presentation code to inspect raw method strings.
public enum CodexServerRequestKind: Sendable, Codable, Equatable {
    case commandApproval
    case fileChangeApproval
    case permissionsApproval
    case userInput
    case mcpElicitation
    case dynamicToolCall
    case tokenRefresh
    case attestation
    case currentTime
    case legacyApplyPatchApproval
    case legacyExecCommandApproval
    case unknown(String)

    public static let knownMethods: Set<String> = [
        commandApproval.method,
        fileChangeApproval.method,
        permissionsApproval.method,
        userInput.method,
        mcpElicitation.method,
        dynamicToolCall.method,
        tokenRefresh.method,
        attestation.method,
        currentTime.method,
        legacyApplyPatchApproval.method,
        legacyExecCommandApproval.method
    ]

    public init(method: String) {
        switch method {
        case "item/commandExecution/requestApproval": self = .commandApproval
        case "item/fileChange/requestApproval": self = .fileChangeApproval
        case "item/permissions/requestApproval": self = .permissionsApproval
        case "item/tool/requestUserInput": self = .userInput
        case "mcpServer/elicitation/request": self = .mcpElicitation
        case "item/tool/call": self = .dynamicToolCall
        case "account/chatgptAuthTokens/refresh": self = .tokenRefresh
        case "attestation/generate": self = .attestation
        case "currentTime/read": self = .currentTime
        case "applyPatchApproval": self = .legacyApplyPatchApproval
        case "execCommandApproval": self = .legacyExecCommandApproval
        default: self = .unknown(method)
        }
    }

    public var method: String {
        switch self {
        case .commandApproval: "item/commandExecution/requestApproval"
        case .fileChangeApproval: "item/fileChange/requestApproval"
        case .permissionsApproval: "item/permissions/requestApproval"
        case .userInput: "item/tool/requestUserInput"
        case .mcpElicitation: "mcpServer/elicitation/request"
        case .dynamicToolCall: "item/tool/call"
        case .tokenRefresh: "account/chatgptAuthTokens/refresh"
        case .attestation: "attestation/generate"
        case .currentTime: "currentTime/read"
        case .legacyApplyPatchApproval: "applyPatchApproval"
        case .legacyExecCommandApproval: "execCommandApproval"
        case .unknown(let method): method
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(method: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(method)
    }
}

extension CodexServerRequestKind {
    var requiresUnreadAttention: Bool {
        switch self {
        case .commandApproval,
             .fileChangeApproval,
             .permissionsApproval,
             .userInput,
             .mcpElicitation,
             .legacyApplyPatchApproval,
             .legacyExecCommandApproval:
            true
        case .dynamicToolCall,
             .tokenRefresh,
             .attestation,
             .currentTime,
             .unknown:
            false
        }
    }
}

/// The non-secret information retained for an incoming server request.
/// Request payloads and handler capabilities intentionally live elsewhere.
public struct CodexServerRequestRegistration: Sendable, Equatable {
    public let key: CodexServerRequestKey
    public let method: String
    public let kind: CodexServerRequestKind
    public let scope: CodexServerRequestScope
    public let approvalCorrelation: CodexApprovalCorrelation?

    public init(
        key: CodexServerRequestKey,
        method: String,
        scope: CodexServerRequestScope = .init(),
        approvalCorrelation: CodexApprovalCorrelation? = nil
    ) {
        self.key = key
        self.method = method
        self.kind = .init(method: method)
        self.scope = scope
        self.approvalCorrelation = approvalCorrelation
    }
}

/// A JSON-RPC error that should be sent in the response error member.
public struct CodexServerRequestResponseError: Sendable, Codable, Equatable {
    public let code: Int
    public let message: String
    public let data: CodexJSONValue?

    public init(code: Int, message: String, data: CodexJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// The only decisions a host handler may make for a server-originated request.
/// Coordinator-only abandonment is deliberately not representable here.
public enum CodexServerRequestHandlerDecision: Sendable, Codable, Equatable {
    /// Decline custom handling and apply the session's protocol-safe default.
    /// Interactive requests remain pending in the observable inbox.
    case pending
    /// Send a JSON-RPC success response containing this result.
    case result(CodexJSONValue)
    /// Send a JSON-RPC error response containing this error.
    case error(CodexServerRequestResponseError)
}
