import Foundation

/// The JSON-RPC identifier of a server-originated request.
///
/// JSON-RPC permits string and integer identifiers. They are deliberately
/// represented as different enum cases: the wire identifiers `7` and `"7"`
/// name different requests and must never collide in the request ledger.
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

/// Internal terminal action chosen by the ordered session coordinator.
enum CodexServerRequestOutcome: Sendable, Codable, Equatable {
    case result(CodexJSONValue)
    case error(CodexServerRequestResponseError)
    /// Send nothing because responding is no longer valid or useful.
    case abandon(CodexServerRequestAbandonReason)
}

enum CodexServerRequestAbandonReason: String, Sendable, Codable, Equatable {
    /// The app-server announced `serverRequest/resolved` first.
    case serverResolved
    /// The connection carrying the request ended.
    case disconnected
}

/// Why a pending request became terminal. The cause is kept separately from
/// the response outcome while the ledger remains a migration bridge.
public enum CodexServerRequestTerminalCause: String, Sendable, Codable, Equatable {
    case clientResult
    case clientError
    case serverResolved
    case disconnected
}

/// Redacted response classification retained in observable state. The actual
/// result or error is carried only by the one-shot transition returned to the
/// session coordinator, preventing token refresh or attestation results from
/// leaking into UI snapshots.
public enum CodexServerRequestResponseDisposition: String, Sendable, Codable, Equatable {
    case result
    case error
    case abandoned
}

public struct CodexServerRequestTerminal: Sendable, Codable, Equatable {
    public let cause: CodexServerRequestTerminalCause
    public let responseDisposition: CodexServerRequestResponseDisposition
    public let revision: UInt64

    public init(
        cause: CodexServerRequestTerminalCause,
        responseDisposition: CodexServerRequestResponseDisposition,
        revision: UInt64
    ) {
        self.cause = cause
        self.responseDisposition = responseDisposition
        self.revision = revision
    }
}

public enum CodexServerRequestState: Sendable, Codable, Equatable {
    case pending
    case terminal(CodexServerRequestTerminal)
}

/// Immutable, continuation-free request state suitable for UI and diagnostic
/// projections. It contains neither a raw request payload nor a handler closure.
public struct CodexServerRequestSnapshot: Sendable, Codable, Equatable {
    public let key: CodexServerRequestKey
    public let method: String
    public let kind: CodexServerRequestKind
    public let scope: CodexServerRequestScope
    public let approvalCorrelation: CodexApprovalCorrelation?
    public let registrationSequence: UInt64
    public let registeredRevision: UInt64
    public let state: CodexServerRequestState

    public init(
        key: CodexServerRequestKey,
        method: String,
        kind: CodexServerRequestKind,
        scope: CodexServerRequestScope,
        approvalCorrelation: CodexApprovalCorrelation?,
        registrationSequence: UInt64,
        registeredRevision: UInt64,
        state: CodexServerRequestState
    ) {
        self.key = key
        self.method = method
        self.kind = kind
        self.scope = scope
        self.approvalCorrelation = approvalCorrelation
        self.registrationSequence = registrationSequence
        self.registeredRevision = registeredRevision
        self.state = state
    }

    public var isPending: Bool {
        if case .pending = state { return true }
        return false
    }
}

public enum CodexServerRequestRegistrationResult: Sendable, Equatable {
    case registered(CodexServerRequestSnapshot)
    /// A second request with the same `(connectionEpoch, requestID)` is a
    /// protocol violation; the original entry always wins.
    case duplicate(CodexServerRequestSnapshot)
}

struct CodexServerRequestTransition: Sendable, Equatable {
    let snapshot: CodexServerRequestSnapshot
    let terminal: CodexServerRequestTerminal
    let outcome: CodexServerRequestOutcome

    init(
        snapshot: CodexServerRequestSnapshot,
        terminal: CodexServerRequestTerminal,
        outcome: CodexServerRequestOutcome
    ) {
        self.snapshot = snapshot
        self.terminal = terminal
        self.outcome = outcome
    }
}

enum CodexServerRequestResolution: Sendable, Equatable {
    case applied(CodexServerRequestTransition)
    case alreadyTerminal(CodexServerRequestSnapshot)
    case unknown
}

/// Synchronous state machine intended to be owned by `CodexSession`'s actor.
///
/// Keeping this type synchronous makes registration, UI replies,
/// `serverRequest/resolved`, and disconnect compete in the actor's single
/// ordered transaction. The first terminal transition wins;
/// later contenders observe `.alreadyTerminal` and cannot emit a second reply.
public struct CodexServerRequestLedger: Sendable {
    private var entries: [CodexServerRequestKey: CodexServerRequestSnapshot] = [:]
    private var nextRegistrationSequence: UInt64 = 0

    public private(set) var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func register(
        _ registration: CodexServerRequestRegistration
    ) -> CodexServerRequestRegistrationResult {
        if let existing = entries[registration.key] {
            return .duplicate(existing)
        }

        revision &+= 1
        let sequence = nextRegistrationSequence
        nextRegistrationSequence &+= 1
        let snapshot = CodexServerRequestSnapshot(
            key: registration.key,
            method: registration.method,
            kind: registration.kind,
            scope: registration.scope,
            approvalCorrelation: registration.approvalCorrelation,
            registrationSequence: sequence,
            registeredRevision: revision,
            state: .pending
        )
        entries[registration.key] = snapshot
        return .registered(snapshot)
    }

    public func snapshot(for key: CodexServerRequestKey) -> CodexServerRequestSnapshot? {
        entries[key]
    }

    public func pendingSnapshots(connectionEpoch: UInt64? = nil) -> [CodexServerRequestSnapshot] {
        entries.values
            .filter { snapshot in
                snapshot.isPending && (connectionEpoch == nil || snapshot.key.connectionEpoch == connectionEpoch)
            }
            .sorted { $0.registrationSequence < $1.registrationSequence }
    }

    /// Completes a request with a JSON-RPC result chosen by the host.
    @discardableResult
    mutating func resolve(
        _ key: CodexServerRequestKey,
        result: CodexJSONValue
    ) -> CodexServerRequestResolution {
        terminalize(key, cause: .clientResult, outcome: .result(result))
    }

    /// Completes a request with a JSON-RPC error chosen by the host.
    @discardableResult
    mutating func fail(
        _ key: CodexServerRequestKey,
        error: CodexServerRequestResponseError
    ) -> CodexServerRequestResolution {
        terminalize(key, cause: .clientError, outcome: .error(error))
    }

    /// Applies `serverRequest/resolved`. No response should be sent after this
    /// transition because the server has already resolved the request.
    @discardableResult
    mutating func markServerResolved(
        _ key: CodexServerRequestKey
    ) -> CodexServerRequestResolution {
        terminalize(
            key,
            cause: .serverResolved,
            outcome: .abandon(.serverResolved)
        )
    }

    /// Terminalizes all pending requests from a disconnected transport epoch.
    /// These transitions abandon their responses because that connection can no
    /// longer carry them.
    @discardableResult
    mutating func disconnect(
        connectionEpoch: UInt64
    ) -> [CodexServerRequestTransition] {
        pendingSnapshots(connectionEpoch: connectionEpoch).compactMap { snapshot in
            appliedTransition(
                terminalize(
                    snapshot.key,
                    cause: .disconnected,
                    outcome: .abandon(.disconnected)
                )
            )
        }
    }

    /// Removes compact terminal tombstones from an epoch once no late frame
    /// from that transport can arrive. Pending entries are never removed.
    public mutating func removeTerminalEntries(connectionEpoch: UInt64) {
        let previousCount = entries.count
        entries = entries.filter { key, snapshot in
            guard key.connectionEpoch == connectionEpoch else { return true }
            return snapshot.isPending
        }
        if entries.count != previousCount {
            revision &+= 1
        }
    }

    private mutating func terminalize(
        _ key: CodexServerRequestKey,
        cause: CodexServerRequestTerminalCause,
        outcome: CodexServerRequestOutcome
    ) -> CodexServerRequestResolution {
        guard let current = entries[key] else {
            return .unknown
        }
        guard current.isPending else {
            return .alreadyTerminal(current)
        }

        revision &+= 1
        let terminal = CodexServerRequestTerminal(
            cause: cause,
            responseDisposition: responseDisposition(for: outcome),
            revision: revision
        )
        let updated = CodexServerRequestSnapshot(
            key: current.key,
            method: current.method,
            kind: current.kind,
            scope: current.scope,
            approvalCorrelation: current.approvalCorrelation,
            registrationSequence: current.registrationSequence,
            registeredRevision: current.registeredRevision,
            state: .terminal(terminal)
        )
        entries[key] = updated
        return .applied(.init(snapshot: updated, terminal: terminal, outcome: outcome))
    }

    private func appliedTransition(
        _ resolution: CodexServerRequestResolution
    ) -> CodexServerRequestTransition? {
        guard case .applied(let transition) = resolution else { return nil }
        return transition
    }

    private func responseDisposition(
        for outcome: CodexServerRequestOutcome
    ) -> CodexServerRequestResponseDisposition {
        switch outcome {
        case .result: .result
        case .error: .error
        case .abandon: .abandoned
        }
    }
}
