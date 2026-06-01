import Foundation

public struct EmptyResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct ServerInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var version: String?

    public init(name: String? = nil, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct InitializeResponse: Codable, Sendable, Equatable {
    public var serverInfo: ServerInfo?
    public var userAgent: String?
    public var platformFamily: String?
    public var platformOs: String?

    public init(serverInfo: ServerInfo? = nil, userAgent: String? = nil, platformFamily: String? = nil, platformOs: String? = nil) {
        self.serverInfo = serverInfo
        self.userAgent = userAgent
        self.platformFamily = platformFamily
        self.platformOs = platformOs
    }
}

public enum ApprovalMode: String, Codable, Sendable, Equatable {
    case denyAll = "deny_all"
    case autoReview = "auto_review"

    public var settings: ApprovalSettings {
        switch self {
        case .autoReview:
            return ApprovalSettings(approvalPolicy: .onRequest, approvalsReviewer: .autoReview)
        case .denyAll:
            return ApprovalSettings(approvalPolicy: .never, approvalsReviewer: nil)
        }
    }
}

public struct ApprovalSettings: Codable, Sendable, Equatable {
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?

    public init(approvalPolicy: AskForApproval? = nil, approvalsReviewer: ApprovalsReviewer? = nil) {
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
    }
}

public enum AskForApproval: String, Codable, Sendable, Equatable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never
}

public enum ApprovalsReviewer: String, Codable, Sendable, Equatable {
    case user
    case autoReview = "auto_review"
    case guardianSubagent = "guardian_subagent"
}

public enum Personality: String, Codable, Sendable, Equatable {
    case none
    case friendly
    case pragmatic
}

public enum ReasoningEffort: String, Codable, Sendable, Equatable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum ReasoningSummary: String, Codable, Sendable, Equatable {
    case auto
    case concise
    case detailed
    case none
}

public enum SandboxMode: String, Codable, Sendable, Equatable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

public enum Sandbox: Sendable, Equatable {
    case readOnly
    case workspaceWrite
    case fullAccess

    public var threadMode: SandboxMode {
        switch self {
        case .readOnly: return .readOnly
        case .workspaceWrite: return .workspaceWrite
        case .fullAccess: return .dangerFullAccess
        }
    }

    public var turnPolicy: CodexJSONValue {
        switch self {
        case .readOnly:
            return .dictionary(["type": .string("readOnly")])
        case .workspaceWrite:
            return .dictionary(["type": .string("workspaceWrite")])
        case .fullAccess:
            return .dictionary(["type": .string("dangerFullAccess")])
        }
    }
}

public enum SortDirection: String, Codable, Sendable, Equatable {
    case asc
    case desc
}

public enum ThreadSortKey: String, Codable, Sendable, Equatable {
    case createdAt = "created_at"
    case updatedAt = "updated_at"
}

public enum ThreadSource: String, Codable, Sendable, Equatable {
    case user
    case subagent
    case memoryConsolidation = "memory_consolidation"
}

public enum ThreadSourceKind: String, Codable, Sendable, Equatable {
    case cli
    case vscode
    case exec
    case appServer
    case subAgent
    case subAgentReview
    case subAgentCompact
    case subAgentThreadSpawn
    case subAgentOther
    case unknown
}

public enum ThreadStartSource: String, Codable, Sendable, Equatable {
    case startup
    case clear
}

public enum CodexInput: Sendable, Equatable {
    case text(String)
    case image(url: String)
    case localImage(path: String)
    case skill(name: String, path: String)
    case mention(name: String, path: String)
    case raw(CodexJSONValue)

    public var jsonValue: CodexJSONValue {
        switch self {
        case .text(let text):
            return .dictionary(["type": .string("text"), "text": .string(text)])
        case .image(let url):
            return .dictionary(["type": .string("image"), "url": .string(url)])
        case .localImage(let path):
            return .dictionary(["type": .string("localImage"), "path": .string(path)])
        case .skill(let name, let path):
            return .dictionary(["type": .string("skill"), "name": .string(name), "path": .string(path)])
        case .mention(let name, let path):
            return .dictionary(["type": .string("mention"), "name": .string(name), "path": .string(path)])
        case .raw(let value):
            return value
        }
    }
}

public typealias CodexRunInput = [CodexInput]

public struct ThreadStartParams: Codable, Sendable, Equatable {
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var baseInstructions: String?
    public var config: [String: CodexJSONValue]?
    public var cwd: String?
    public var developerInstructions: String?
    public var ephemeral: Bool?
    public var model: String?
    public var modelProvider: String?
    public var personality: Personality?
    public var sandbox: SandboxMode?
    public var serviceName: String?
    public var serviceTier: String?
    public var sessionStartSource: ThreadStartSource?
    public var threadSource: ThreadSource?

    public init(
        approvalPolicy: AskForApproval? = nil,
        approvalsReviewer: ApprovalsReviewer? = nil,
        baseInstructions: String? = nil,
        config: [String: CodexJSONValue]? = nil,
        cwd: String? = nil,
        developerInstructions: String? = nil,
        ephemeral: Bool? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        personality: Personality? = nil,
        sandbox: SandboxMode? = nil,
        serviceName: String? = nil,
        serviceTier: String? = nil,
        sessionStartSource: ThreadStartSource? = nil,
        threadSource: ThreadSource? = nil
    ) {
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.baseInstructions = baseInstructions
        self.config = config
        self.cwd = cwd
        self.developerInstructions = developerInstructions
        self.ephemeral = ephemeral
        self.model = model
        self.modelProvider = modelProvider
        self.personality = personality
        self.sandbox = sandbox
        self.serviceName = serviceName
        self.serviceTier = serviceTier
        self.sessionStartSource = sessionStartSource
        self.threadSource = threadSource
    }
}

public struct ThreadResumeParams: Codable, Sendable, Equatable {
    public var threadId: String?
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var baseInstructions: String?
    public var config: [String: CodexJSONValue]?
    public var cwd: String?
    public var developerInstructions: String?
    public var model: String?
    public var modelProvider: String?
    public var personality: Personality?
    public var sandbox: SandboxMode?
    public var serviceTier: String?

    public init(threadId: String? = nil) {
        self.threadId = threadId
    }
}

public struct ThreadForkParams: Codable, Sendable, Equatable {
    public var threadId: String?
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var baseInstructions: String?
    public var config: [String: CodexJSONValue]?
    public var cwd: String?
    public var developerInstructions: String?
    public var ephemeral: Bool?
    public var model: String?
    public var modelProvider: String?
    public var sandbox: SandboxMode?
    public var serviceTier: String?
    public var threadSource: ThreadSource?

    public init(threadId: String? = nil) {
        self.threadId = threadId
    }
}

public enum ThreadListCwdFilter: Codable, Sendable, Equatable {
    case cwd(String)
    case raw(CodexJSONValue)

    public init(from decoder: Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        if case .string(let cwd) = value {
            self = .cwd(cwd)
        } else {
            self = .raw(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .cwd(let cwd): try CodexJSONValue.string(cwd).encode(to: encoder)
        case .raw(let value): try value.encode(to: encoder)
        }
    }
}

public struct ThreadListParams: Codable, Sendable, Equatable {
    public var archived: Bool?
    public var cursor: String?
    public var cwd: ThreadListCwdFilter?
    public var limit: Int?
    public var modelProviders: [String]?
    public var searchTerm: String?
    public var sortDirection: SortDirection?
    public var sortKey: ThreadSortKey?
    public var sourceKinds: [ThreadSourceKind]?
    public var useStateDbOnly: Bool?

    public init(
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
    ) {
        self.archived = archived
        self.cursor = cursor
        self.cwd = cwd
        self.limit = limit
        self.modelProviders = modelProviders
        self.searchTerm = searchTerm
        self.sortDirection = sortDirection
        self.sortKey = sortKey
        self.sourceKinds = sourceKinds
        self.useStateDbOnly = useStateDbOnly
    }
}

public struct TurnStartParams: Codable, Sendable, Equatable {
    public var threadId: String
    public var input: [CodexJSONValue]
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var cwd: String?
    public var effort: ReasoningEffort?
    public var model: String?
    public var outputSchema: CodexJSONValue?
    public var personality: Personality?
    public var sandboxPolicy: CodexJSONValue?
    public var serviceTier: String?
    public var summary: ReasoningSummary?

    public init(threadId: String, input: [CodexInput]) {
        self.threadId = threadId
        self.input = input.map(\.jsonValue)
    }
}

public struct CodexAppThread: Codable, Sendable, Equatable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public enum TurnStatus: Sendable, Equatable, Codable {
    case completed
    case interrupted
    case failed
    case inProgress
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .completed: return "completed"
        case .interrupted: return "interrupted"
        case .failed: return "failed"
        case .inProgress: return "inProgress"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        case "inProgress": self = .inProgress
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        switch value {
        case .string(let raw):
            self.init(rawValue: raw)
        case .dictionary(let object):
            if case .string(let raw)? = object["type"] {
                self.init(rawValue: raw)
            } else {
                self = .unknown(value.description)
            }
        default:
            self = .unknown(value.description)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

public struct TurnError: Codable, Sendable, Equatable {
    public var message: String?
    public var raw: CodexJSONValue?

    public init(message: String? = nil, raw: CodexJSONValue? = nil) {
        self.message = message
        self.raw = raw
    }
}

public struct AppServerTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: TurnStatus?
    public var error: TurnError?
    public var startedAt: Int?
    public var completedAt: Int?
    public var durationMs: Int?

    public init(id: String, status: TurnStatus? = nil, error: TurnError? = nil, startedAt: Int? = nil, completedAt: Int? = nil, durationMs: Int? = nil) {
        self.id = id
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
    }
}

public struct ThreadStartResponse: Codable, Sendable, Equatable {
    public var thread: CodexAppThread
}

public typealias ThreadResumeResponse = ThreadStartResponse
public typealias ThreadForkResponse = ThreadStartResponse
public typealias ThreadUnarchiveResponse = ThreadStartResponse
public typealias ThreadArchiveResponse = EmptyResponse
public typealias ThreadSetNameResponse = EmptyResponse
public typealias ThreadCompactStartResponse = EmptyResponse

public struct ThreadListResponse: Codable, Sendable, Equatable {
    public var data: [CodexAppThread]?
    public var nextCursor: String?
    public var backwardsCursor: String?
}

public struct ThreadReadResponse: Codable, Sendable, Equatable {
    public var thread: CodexAppThread
}

public struct TurnStartResponse: Codable, Sendable, Equatable {
    public var turn: AppServerTurn
}

public typealias TurnInterruptResponse = EmptyResponse

public struct TurnSteerResponse: Codable, Sendable, Equatable {
    public var turnId: String?
}

public struct ModelListResponse: Codable, Sendable, Equatable {
    public var models: [CodexJSONValue]?
    public var data: [CodexJSONValue]?
}

public enum LoginAccountParams: Encodable, Sendable, Equatable {
    case apiKey(String)
    case chatgpt(codexStreamlinedLogin: Bool? = nil)
    case chatgptDeviceCode
    case chatgptAuthTokens(accessToken: String, chatgptAccountId: String, chatgptPlanType: String? = nil)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .apiKey(let apiKey):
            try container.encode("apiKey", forKey: DynamicCodingKey("type"))
            try container.encode(apiKey, forKey: DynamicCodingKey("apiKey"))
        case .chatgpt(let codexStreamlinedLogin):
            try container.encode("chatgpt", forKey: DynamicCodingKey("type"))
            try container.encodeIfPresent(codexStreamlinedLogin, forKey: DynamicCodingKey("codexStreamlinedLogin"))
        case .chatgptDeviceCode:
            try container.encode("chatgptDeviceCode", forKey: DynamicCodingKey("type"))
        case .chatgptAuthTokens(let accessToken, let chatgptAccountId, let chatgptPlanType):
            try container.encode("chatgptAuthTokens", forKey: DynamicCodingKey("type"))
            try container.encode(accessToken, forKey: DynamicCodingKey("accessToken"))
            try container.encode(chatgptAccountId, forKey: DynamicCodingKey("chatgptAccountId"))
            try container.encodeIfPresent(chatgptPlanType, forKey: DynamicCodingKey("chatgptPlanType"))
        }
    }
}

public enum LoginAccountResponse: Decodable, Sendable, Equatable {
    case apiKey
    case chatgpt(loginId: String, authUrl: String)
    case chatgptDeviceCode(loginId: String, verificationUrl: String, userCode: String)
    case chatgptAuthTokens
    case unknown([String: CodexJSONValue])

    public init(from decoder: Decoder) throws {
        let object = try [String: CodexJSONValue](from: decoder)
        guard case .string(let type)? = object["type"] else {
            self = .unknown(object)
            return
        }

        switch type {
        case "apiKey":
            self = .apiKey
        case "chatgpt":
            if case .string(let loginId)? = object["loginId"], case .string(let authUrl)? = object["authUrl"] {
                self = .chatgpt(loginId: loginId, authUrl: authUrl)
            } else {
                self = .unknown(object)
            }
        case "chatgptDeviceCode":
            if case .string(let loginId)? = object["loginId"],
               case .string(let verificationUrl)? = object["verificationUrl"],
               case .string(let userCode)? = object["userCode"] {
                self = .chatgptDeviceCode(loginId: loginId, verificationUrl: verificationUrl, userCode: userCode)
            } else {
                self = .unknown(object)
            }
        case "chatgptAuthTokens":
            self = .chatgptAuthTokens
        default:
            self = .unknown(object)
        }
    }
}

public struct CancelLoginAccountResponse: Codable, Sendable, Equatable {
    public init() {}
}

public typealias LogoutAccountResponse = EmptyResponse

public struct GetAccountParams: Codable, Sendable, Equatable {
    public var refreshToken: Bool?

    public init(refreshToken: Bool? = nil) {
        self.refreshToken = refreshToken
    }
}

public struct Account: Codable, Sendable, Equatable {
    public var type: String
    public var email: String?
    public var planType: String?
}

public struct GetAccountResponse: Codable, Sendable, Equatable {
    public var account: Account?
    public var requiresOpenaiAuth: Bool
}

public struct ThreadItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String
    public var text: String?
    public var phase: String?
    public var raw: [String: CodexJSONValue]

    public init(from decoder: Decoder) throws {
        let object = try [String: CodexJSONValue](from: decoder)
        guard case .string(let id)? = object["id"], case .string(let type)? = object["type"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "ThreadItem requires id and type"))
        }
        self.id = id
        self.type = type
        if case .string(let text)? = object["text"] { self.text = text }
        if case .string(let phase)? = object["phase"] { self.phase = phase }
        self.raw = object
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

public struct ThreadTokenUsage: Codable, Sendable, Equatable {
    public var raw: [String: CodexJSONValue]

    public init(from decoder: Decoder) throws {
        self.raw = try [String: CodexJSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

public struct ItemCompletedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String
    public var item: ThreadItem
}

public typealias ItemStartedNotification = ItemCompletedNotification

public struct AgentMessageDeltaNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String
    public var itemId: String
    public var delta: String
}

public struct TurnStartedNotification: Codable, Sendable, Equatable {
    public var threadId: String?
    public var turn: AppServerTurn
}

public struct TurnCompletedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turn: AppServerTurn
}

public struct ThreadTokenUsageUpdatedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String?
    public var tokenUsage: ThreadTokenUsage
}

public struct AccountLoginCompletedNotification: Codable, Sendable, Equatable {
    public var loginId: String
    public var raw: [String: CodexJSONValue]

    public init(from decoder: Decoder) throws {
        let object = try [String: CodexJSONValue](from: decoder)
        guard case .string(let loginId)? = object["loginId"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "loginId missing"))
        }
        self.loginId = loginId
        self.raw = object
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

public struct DynamicCodingKey: CodingKey, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(stringValue: String) {
        self.init(stringValue)
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
