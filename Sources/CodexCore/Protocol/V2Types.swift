import Foundation

// Hand-maintained conveniences layered on the generated app-server protocol.
//
// Wire models belong in Sources/CodexCore/Generated. In particular, the v1
// initialize types are generated from their standalone schemas so handshake
// required fields participate in the pinned drift gate.

public struct EmptyResponse: Codable, Sendable, Equatable {
    public init() {}
}

public typealias InitializeResponse = CodexSchemaInitializeResponse
public typealias InitializeCapabilities = CodexSchemaInitializeCapabilities

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

public enum ReasoningEffort: String, Codable, Sendable, Equatable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
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
