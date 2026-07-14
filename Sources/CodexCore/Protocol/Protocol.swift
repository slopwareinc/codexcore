import Foundation

// MARK: - JSON-RPC Message Wrapper

public enum CodexJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodexJSONValue])
    case dictionary([String: CodexJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let a = try? container.decode([CodexJSONValue].self) { self = .array(a) }
        else if let dict = try? container.decode([String: CodexJSONValue].self) { self = .dictionary(dict) }
        else if container.decodeNil() { self = .null }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .dictionary(let dict): try container.encode(dict)
        case .null: try container.encodeNil()
        }
    }

    public var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map { $0.rawValue }
        case .dictionary(let dict): return dict.mapValues { $0.rawValue }
        case .null: return NSNull()
        }
    }
}

extension CodexJSONValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .array(let a): return "[" + a.map { $0.description }.joined(separator: ", ") + "]"
        case .dictionary(let dict):
            let pairs = dict.map { "\"\($0.key)\": \($0.value.description)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        case .null: return "null"
        }
    }
}

// MARK: - Protocol Types

public struct CodexServerItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: String
    public let status: String?
    public let label: String?
    public let raw: [String: CodexJSONValue]

    public init(id: String, type: String, status: String? = nil, label: String? = nil, raw: [String: CodexJSONValue] = [:]) {
        self.id = id
        self.type = type
        self.status = status
        self.label = label
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey {
        case id, type, status, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(String.self, forKey: .type)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)

        let rawContainer = try decoder.singleValueContainer()
        self.raw = try rawContainer.decode([String: CodexJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var fullMap = raw
        fullMap["id"] = .string(id)
        fullMap["type"] = .string(type)
        if let status { fullMap["status"] = .string(status) }
        if let label { fullMap["label"] = .string(label) }
        try container.encode(fullMap)
    }
}

// MARK: - Server Notifications

public enum CodexServerEvent: Sendable {
    case threadStarted(threadId: String, name: String?, status: String)
    case threadStatusChanged(threadId: String, status: String)
    case accountUpdated(CodexSchemaAccountUpdatedNotification)
    case accountRateLimitsUpdated(CodexSchemaAccountRateLimitsUpdatedNotification)
    case threadGoalUpdated(threadId: String, goal: ThreadGoal)
    case threadGoalCleared(threadId: String)
    case turnStarted(threadId: String, turnId: String)
    case turnCompleted(threadId: String, turnId: String, status: CodexSchemaTurnStatus?, error: String?)
    case itemStarted(threadId: String, turnId: String, item: CodexServerItem)
    case itemCompleted(threadId: String, turnId: String, item: CodexServerItem)
    case messageDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case reasoningDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case planDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case commandOutputDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case fileChangeOutputDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case fileChangePatchUpdated(threadId: String, turnId: String, itemId: String, path: String?, patch: String)
    case mcpToolCallProgress(threadId: String, turnId: String, itemId: String, message: String)
    case turnPlanUpdated(threadId: String, turnId: String, plan: [TurnPlanStep], explanation: String?)
    case turnDiffUpdated(threadId: String, turnId: String, diff: String)
    case tokenUsageUpdated(threadId: String, turnId: String?, usage: ThreadTokenUsage)
    case turnError(threadId: String, turnId: String, error: CodexSchemaTurnError, willRetry: Bool)
    case serverError(message: String, threadId: String?)
    case unknown(method: String, params: [String: CodexJSONValue])
}

// MARK: - Server Requests (Approvals & Input)

public enum CodexApprovalKind: String, Codable, Sendable {
    case command
    case fileChange = "file_change"
    case permissions
}

public struct CodexCommandAction: Codable, Sendable, Equatable {
    public let type: String
    public let command: String
    public let name: String?
    public let path: String?
    public let query: String?

    public init(type: String, command: String, name: String? = nil, path: String? = nil, query: String? = nil) {
        self.type = type
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }
}

public struct CodexNetworkApprovalContext: Codable, Sendable, Equatable {
    public let host: String
    public let `protocol`: String

    public init(host: String, protocol: String) {
        self.host = host
        self.protocol = `protocol`
    }
}

public struct CodexApprovalRequest: Codable, Sendable, Identifiable, Equatable {
    public var id: String { requestId.description }
    public let requestId: CodexJSONValue
    public let kind: CodexApprovalKind
    public let threadId: String
    public let turnId: String
    public let itemId: String
    public let approvalId: String?
    public let command: String?
    public let path: String?
    public let grantRoot: String?
    public let cwd: String?
    public let reason: String?
    public let startedAtMs: Int?
    public let environmentId: String?
    public let availableDecisions: [CodexCommandApprovalDecision]?
    public let commandActions: [CodexCommandAction]?
    /// Experimental per-command sandbox access requested by the server. Kept
    /// losslessly as JSON because this upstream profile is still evolving.
    public let additionalPermissions: CodexJSONValue?
    public let networkApprovalContext: CodexNetworkApprovalContext?
    public let proposedExecpolicyAmendment: [String]?
    public let proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]?

    public init(
        requestId: CodexJSONValue,
        kind: CodexApprovalKind,
        threadId: String,
        turnId: String,
        itemId: String,
        approvalId: String? = nil,
        command: String? = nil,
        path: String? = nil,
        grantRoot: String? = nil,
        cwd: String? = nil,
        reason: String? = nil,
        startedAtMs: Int? = nil,
        environmentId: String? = nil,
        availableDecisions: [CodexCommandApprovalDecision]? = nil,
        commandActions: [CodexCommandAction]? = nil,
        additionalPermissions: CodexJSONValue? = nil,
        networkApprovalContext: CodexNetworkApprovalContext? = nil,
        proposedExecpolicyAmendment: [String]? = nil,
        proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.approvalId = approvalId
        self.command = command
        self.path = path
        self.grantRoot = grantRoot
        self.cwd = cwd
        self.reason = reason
        self.startedAtMs = startedAtMs
        self.environmentId = environmentId
        self.availableDecisions = availableDecisions
        self.commandActions = commandActions
        self.additionalPermissions = additionalPermissions
        self.networkApprovalContext = networkApprovalContext
        self.proposedExecpolicyAmendment = proposedExecpolicyAmendment
        self.proposedNetworkPolicyAmendments = proposedNetworkPolicyAmendments
    }
}

public struct CodexUserInputQuestion: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let question: String
    public let header: String?
    public let isSecret: Bool
    public let isOtherAllowed: Bool
    public let options: [CodexUserInputOption]

    public init(id: String, question: String, header: String? = nil, isSecret: Bool = false, isOtherAllowed: Bool = false, options: [CodexUserInputOption] = []) {
        self.id = id
        self.question = question
        self.header = header
        self.isSecret = isSecret
        self.isOtherAllowed = isOtherAllowed
        self.options = options
    }
}

public struct CodexUserInputOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct CodexUserInputRequest: Sendable, Identifiable, Equatable {
    public var id: String { requestId.description }
    public let requestId: CodexJSONValue
    public let threadId: String
    public let turnId: String
    public let itemId: String
    public let questions: [CodexUserInputQuestion]

    public init(requestId: CodexJSONValue, threadId: String, turnId: String, itemId: String, questions: [CodexUserInputQuestion]) {
        self.requestId = requestId
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.questions = questions
    }
}
