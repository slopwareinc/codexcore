import Foundation

// Hand-maintained app-server v2 protocol types.
//
// NOTE: This file is intentionally NOT under Sources/CodexCore/Generated. It is
// authored by hand — it is not produced by Tools/regenerate.sh and not verified
// by Tools/check_drift.sh (which only cover AppServerProtocolMethods.swift and
// AppServerSchemaTypes.swift). Keeping it out of Generated/ avoids the false
// impression that `regenerate.sh` rebuilds it or that `check_drift.sh` guards it.

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
    public var codexHome: String?

    public init(serverInfo: ServerInfo? = nil, userAgent: String? = nil, platformFamily: String? = nil, platformOs: String? = nil, codexHome: String? = nil) {
        self.serverInfo = serverInfo
        self.userAgent = userAgent
        self.platformFamily = platformFamily
        self.platformOs = platformOs
        self.codexHome = codexHome
    }
}

public struct InitializeCapabilities: Codable, Sendable, Equatable {
    public var experimentalAPI: Bool?
    public var mcpServerOpenAIFormElicitation: Bool?
    public var optOutNotificationMethods: [String]?
    public var requestAttestation: Bool?

    private enum CodingKeys: String, CodingKey {
        case experimentalAPI = "experimentalApi"
        case mcpServerOpenAIFormElicitation = "mcpServerOpenaiFormElicitation"
        case optOutNotificationMethods
        case requestAttestation
    }

    public init(
        experimentalAPI: Bool? = nil,
        mcpServerOpenAIFormElicitation: Bool? = nil,
        optOutNotificationMethods: [String]? = nil,
        requestAttestation: Bool? = nil
    ) {
        self.experimentalAPI = experimentalAPI
        self.mcpServerOpenAIFormElicitation = mcpServerOpenAIFormElicitation
        self.optOutNotificationMethods = optOutNotificationMethods
        self.requestAttestation = requestAttestation
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
    case ultra
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

public typealias ThreadSortKey = CodexSchemaThreadSortKey

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

public enum ThreadHistoryMode: String, Codable, Sendable, Equatable {
    case legacy
    case paginated
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
    public var allowProviderModelFallback: Bool?
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var baseInstructions: String?
    public var config: [String: CodexJSONValue]?
    public var cwd: String?
    public var developerInstructions: String?
    public var dynamicTools: [CodexDynamicToolSpec]?
    public var environments: [CodexSchemaTurnEnvironmentParams]?
    public var ephemeral: Bool?
    public var experimentalRawEvents: Bool?
    public var historyMode: ThreadHistoryMode?
    public var model: String?
    public var modelProvider: String?
    public var multiAgentMode: CodexSchemaMultiAgentMode?
    public var permissions: String?
    public var personality: Personality?
    public var runtimeWorkspaceRoots: [String]?
    public var sandbox: SandboxMode?
    public var selectedCapabilityRoots: [CodexSchemaSelectedCapabilityRoot]?
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
        dynamicTools: [CodexDynamicToolSpec]? = nil,
        ephemeral: Bool? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        personality: Personality? = nil,
        sandbox: SandboxMode? = nil,
        serviceName: String? = nil,
        serviceTier: String? = nil,
        sessionStartSource: ThreadStartSource? = nil,
        threadSource: ThreadSource? = nil,
        allowProviderModelFallback: Bool? = nil,
        environments: [CodexSchemaTurnEnvironmentParams]? = nil,
        experimentalRawEvents: Bool? = nil,
        historyMode: ThreadHistoryMode? = nil,
        multiAgentMode: CodexSchemaMultiAgentMode? = nil,
        permissions: String? = nil,
        runtimeWorkspaceRoots: [String]? = nil,
        selectedCapabilityRoots: [CodexSchemaSelectedCapabilityRoot]? = nil
    ) {
        self.allowProviderModelFallback = allowProviderModelFallback
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.baseInstructions = baseInstructions
        self.config = config
        self.cwd = cwd
        self.developerInstructions = developerInstructions
        self.dynamicTools = dynamicTools
        self.environments = environments
        self.ephemeral = ephemeral
        self.experimentalRawEvents = experimentalRawEvents
        self.historyMode = historyMode
        self.model = model
        self.modelProvider = modelProvider
        self.multiAgentMode = multiAgentMode
        self.permissions = permissions
        self.personality = personality
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.sandbox = sandbox
        self.selectedCapabilityRoots = selectedCapabilityRoots
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
    public var excludeTurns: Bool?
    public var history: [CodexJSONValue]?
    public var initialTurnsPage: CodexSchemaThreadResumeInitialTurnsPageParams?
    public var model: String?
    public var modelProvider: String?
    public var path: String?
    public var permissions: String?
    public var personality: Personality?
    public var runtimeWorkspaceRoots: [String]?
    public var sandbox: SandboxMode?
    public var serviceTier: String?

    public init(
        threadId: String? = nil,
        excludeTurns: Bool? = nil,
        history: [CodexJSONValue]? = nil,
        initialTurnsPage: CodexSchemaThreadResumeInitialTurnsPageParams? = nil,
        path: String? = nil,
        permissions: String? = nil,
        runtimeWorkspaceRoots: [String]? = nil
    ) {
        self.threadId = threadId
        self.excludeTurns = excludeTurns
        self.history = history
        self.initialTurnsPage = initialTurnsPage
        self.path = path
        self.permissions = permissions
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
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
    public var excludeTurns: Bool?
    public var lastTurnId: String?
    public var model: String?
    public var modelProvider: String?
    public var path: String?
    public var permissions: String?
    public var runtimeWorkspaceRoots: [String]?
    public var sandbox: SandboxMode?
    public var serviceTier: String?
    public var threadSource: ThreadSource?

    public init(
        threadId: String? = nil,
        excludeTurns: Bool? = nil,
        lastTurnId: String? = nil,
        path: String? = nil,
        permissions: String? = nil,
        runtimeWorkspaceRoots: [String]? = nil
    ) {
        self.threadId = threadId
        self.excludeTurns = excludeTurns
        self.lastTurnId = lastTurnId
        self.path = path
        self.permissions = permissions
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
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
    public var ancestorThreadId: String?
    public var archived: Bool?
    public var cursor: String?
    public var cwd: ThreadListCwdFilter?
    public var limit: Int?
    public var modelProviders: [String]?
    public var parentThreadId: String?
    public var searchTerm: String?
    public var sortDirection: SortDirection?
    public var sortKey: ThreadSortKey?
    public var sourceKinds: [ThreadSourceKind]?
    public var useStateDBOnly: Bool?

    private enum CodingKeys: String, CodingKey {
        case archived
        case ancestorThreadId
        case cursor
        case cwd
        case limit
        case modelProviders
        case parentThreadId
        case searchTerm
        case sortDirection
        case sortKey
        case sourceKinds
        case useStateDBOnly = "useStateDbOnly"
    }

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
        useStateDBOnly: Bool? = nil,
        ancestorThreadId: String? = nil,
        parentThreadId: String? = nil
    ) {
        self.ancestorThreadId = ancestorThreadId
        self.archived = archived
        self.cursor = cursor
        self.cwd = cwd
        self.limit = limit
        self.modelProviders = modelProviders
        self.parentThreadId = parentThreadId
        self.searchTerm = searchTerm
        self.sortDirection = sortDirection
        self.sortKey = sortKey
        self.sourceKinds = sourceKinds
        self.useStateDBOnly = useStateDBOnly
    }
}

public struct TurnStartParams: Codable, Sendable, Equatable {
    public var additionalContext: [String: CodexSchemaAdditionalContextEntry]?
    public var threadId: String
    public var input: [CodexJSONValue]
    public var approvalPolicy: AskForApproval?
    public var approvalsReviewer: ApprovalsReviewer?
    public var clientUserMessageId: String?
    public var collaborationMode: CodexSchemaCollaborationMode?
    public var cwd: String?
    public var effort: ReasoningEffort?
    public var environments: [CodexSchemaTurnEnvironmentParams]?
    public var model: String?
    public var multiAgentMode: CodexSchemaMultiAgentMode?
    public var outputSchema: CodexJSONValue?
    public var permissions: String?
    public var personality: Personality?
    public var responsesapiClientMetadata: [String: String]?
    public var runtimeWorkspaceRoots: [String]?
    public var sandboxPolicy: CodexJSONValue?
    public var serviceTier: String?
    public var summary: ReasoningSummary?

    public init(
        threadId: String,
        input: [CodexInput],
        additionalContext: [String: CodexSchemaAdditionalContextEntry]? = nil,
        clientUserMessageId: String? = nil,
        collaborationMode: CodexSchemaCollaborationMode? = nil,
        environments: [CodexSchemaTurnEnvironmentParams]? = nil,
        multiAgentMode: CodexSchemaMultiAgentMode? = nil,
        permissions: String? = nil,
        responsesapiClientMetadata: [String: String]? = nil,
        runtimeWorkspaceRoots: [String]? = nil
    ) {
        self.threadId = threadId
        self.input = input.map(\.jsonValue)
        self.additionalContext = additionalContext
        self.clientUserMessageId = clientUserMessageId
        self.collaborationMode = collaborationMode
        self.environments = environments
        self.multiAgentMode = multiAgentMode
        self.permissions = permissions
        self.responsesapiClientMetadata = responsesapiClientMetadata
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
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

public struct AppServerTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: TurnStatus?
    public var error: CodexSchemaTurnError?
    public var startedAt: Int?
    public var completedAt: Int?
    public var durationMs: Int?

    public init(id: String, status: TurnStatus? = nil, error: CodexSchemaTurnError? = nil, startedAt: Int? = nil, completedAt: Int? = nil, durationMs: Int? = nil) {
        self.id = id
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
    }

    public init(_ wire: CodexSchemaTurn) {
        self.init(
            id: wire.id,
            status: TurnStatus(rawValue: wire.status.rawValue),
            error: wire.error,
            startedAt: wire.startedAt,
            completedAt: wire.completedAt,
            durationMs: wire.durationMs
        )
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

public enum ThreadGoalStatus: String, Codable, Sendable, Equatable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete
}

public struct ThreadGoal: Codable, Sendable, Equatable {
    public var threadId: String
    public var objective: String
    public var status: ThreadGoalStatus
    public var tokenBudget: Int?
    public var tokensUsed: Int
    public var timeUsedSeconds: Int
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        threadId: String,
        objective: String,
        status: ThreadGoalStatus,
        tokenBudget: Int? = nil,
        tokensUsed: Int,
        timeUsedSeconds: Int,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.threadId = threadId
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ThreadGoalSetParams: Encodable, Sendable, Equatable {
    public var threadId: String
    public var objective: String?
    public var status: ThreadGoalStatus?
    public var tokenBudget: Int?

    public init(threadId: String, objective: String? = nil, status: ThreadGoalStatus? = nil, tokenBudget: Int? = nil) {
        self.threadId = threadId
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
    }
}

public struct ThreadGoalGetParams: Encodable, Sendable, Equatable {
    public var threadId: String

    public init(threadId: String) {
        self.threadId = threadId
    }
}

public typealias ThreadGoalClearParams = ThreadGoalGetParams

public struct ThreadGoalSetResponse: Codable, Sendable, Equatable {
    public var goal: ThreadGoal
}

public struct ThreadGoalGetResponse: Codable, Sendable, Equatable {
    public var goal: ThreadGoal?
}

public struct ThreadGoalClearResponse: Codable, Sendable, Equatable {
    public var cleared: Bool
}

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
    public var requiresOpenAIAuth: Bool

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }
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

    public init(raw: [String: CodexJSONValue]) {
        self.raw = raw
    }

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

public struct ThreadGoalUpdatedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String?
    public var goal: ThreadGoal
}

public struct ThreadGoalClearedNotification: Codable, Sendable, Equatable {
    public var threadId: String
}

public enum TurnPlanStepStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress
    case completed
}

public struct TurnPlanStep: Codable, Sendable, Equatable {
    public var step: String
    public var status: TurnPlanStepStatus

    public init(step: String, status: TurnPlanStepStatus) {
        self.step = step
        self.status = status
    }
}

public struct TurnPlanUpdatedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String
    public var plan: [TurnPlanStep]
    public var explanation: String?

    public init(threadId: String, turnId: String, plan: [TurnPlanStep], explanation: String? = nil) {
        self.threadId = threadId
        self.turnId = turnId
        self.plan = plan
        self.explanation = explanation
    }
}

public enum FuzzyFileSearchMatchType: String, Codable, Sendable, Equatable {
    case file
    case directory
}

public struct FuzzyFileSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var fileName: String
    public var matchType: FuzzyFileSearchMatchType
    public var path: String
    public var root: String
    public var score: Double
    public var indices: [Int]?

    public var id: String { root + "/" + path }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case matchType = "match_type"
        case path
        case root
        case score
        case indices
    }

    public init(fileName: String, matchType: FuzzyFileSearchMatchType, path: String, root: String, score: Double, indices: [Int]? = nil) {
        self.fileName = fileName
        self.matchType = matchType
        self.path = path
        self.root = root
        self.score = score
        self.indices = indices
    }

    /// Absolute path combining the search root and relative match path.
    public var absolutePath: String {
        if path.hasPrefix("/") { return path }
        return root.hasSuffix("/") ? root + path : root + "/" + path
    }
}

public struct FuzzyFileSearchResponse: Codable, Sendable, Equatable {
    public var files: [FuzzyFileSearchResult]
}

/// Latest aggregated unified diff across all file changes in the turn.
public struct TurnDiffUpdatedNotification: Codable, Sendable, Equatable {
    public var threadId: String
    public var turnId: String
    public var diff: String

    public init(threadId: String, turnId: String, diff: String) {
        self.threadId = threadId
        self.turnId = turnId
        self.diff = diff
    }
}

public struct AccountLoginCompletedNotification: Sendable, Equatable {
    public var loginId: String?
    public var success: Bool
    public var error: String?
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
