import Foundation

// MARK: - Exact protocol lifecycle

public enum ThreadActiveFlag: Sendable, Hashable, Codable, Comparable {
    case waitingOnApproval
    case waitingOnUserInput
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "waitingOnApproval": self = .waitingOnApproval
        case "waitingOnUserInput": self = .waitingOnUserInput
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .waitingOnApproval: "waitingOnApproval"
        case .waitingOnUserInput: "waitingOnUserInput"
        case .unknown(let value): value
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Exact thread status union from app-server. Unknown variants remain lossless.
public enum CanonicalThreadStatus: Sendable, Equatable {
    case notLoaded
    case idle
    case active(flags: Set<ThreadActiveFlag>)
    case systemError(CodexJSONValue)
    case unknown(type: String?, raw: CodexJSONValue)

    public var isActive: Bool {
        if case .active = self { true } else { false }
    }
}

public enum CanonicalTurnStatus: Sendable, Equatable, Codable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inProgress: "inProgress"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed: true
        case .inProgress, .unknown: false
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

public struct CanonicalTurnError: Sendable, Equatable {
    public var message: String
    public var additionalDetails: String?
    public var codexErrorInfo: CodexJSONValue?

    public init(
        message: String,
        additionalDetails: String? = nil,
        codexErrorInfo: CodexJSONValue? = nil
    ) {
        self.message = message
        self.additionalDetails = additionalDetails
        self.codexErrorInfo = codexErrorInfo
    }
}

// MARK: - Thread metadata and history

public enum CanonicalHistoryMode: Sendable, Equatable, Codable {
    case legacy
    case paginated
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "legacy": self = .legacy
        case "paginated": self = .paginated
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .legacy: "legacy"
        case .paginated: "paginated"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Durable history visible at one successful paginated resume. Both cursor keys
/// must be present in the response; `nil` is a meaningful "empty at this cut" value.
public struct CanonicalResumeCut: Sendable, Equatable {
    public let connectionEpoch: UInt64
    public let resumeGeneration: UInt64
    public let turnsBackwardsCursor: String?
    public let itemsBackwardsCursor: String?

    public init(
        connectionEpoch: UInt64,
        resumeGeneration: UInt64,
        turnsBackwardsCursor: String?,
        itemsBackwardsCursor: String?
    ) {
        self.connectionEpoch = connectionEpoch
        self.resumeGeneration = resumeGeneration
        self.turnsBackwardsCursor = turnsBackwardsCursor
        self.itemsBackwardsCursor = itemsBackwardsCursor
    }
}

/// Progress for one pagination chain. Exhaustion is explicit because a nil cursor
/// can also mean that a page/cut has not been installed yet.
public struct CanonicalPageCursorState: Sendable, Equatable {
    public var backwardsCursor: String?
    public var nextCursor: String?
    public var isExhausted: Bool

    public init(
        backwardsCursor: String? = nil,
        nextCursor: String? = nil,
        isExhausted: Bool = false
    ) {
        self.backwardsCursor = backwardsCursor
        self.nextCursor = nextCursor
        self.isExhausted = isExhausted
    }
}

/// Canonical pagination facts. Fetch tasks and leases stay in the history
/// coordinator; durable cursors and coverage live with canonical thread state.
public struct CanonicalHistoryState: Sendable, Equatable {
    public var mode: CanonicalHistoryMode?
    public var turnsCoverage: StateCoverage
    public var resumeCut: CanonicalResumeCut?
    public var turnsPage: CanonicalPageCursorState
    public var itemPagesByTurn: [TurnID: CanonicalPageCursorState]
    public var protocolMetadata: [String: CodexJSONValue]
    public var isStaleAfterReconnect: Bool

    public init(
        mode: CanonicalHistoryMode? = nil,
        turnsCoverage: StateCoverage = .notLoaded,
        resumeCut: CanonicalResumeCut? = nil,
        turnsPage: CanonicalPageCursorState = .init(),
        itemPagesByTurn: [TurnID: CanonicalPageCursorState] = [:],
        protocolMetadata: [String: CodexJSONValue] = [:],
        isStaleAfterReconnect: Bool = false
    ) {
        self.mode = mode
        self.turnsCoverage = turnsCoverage
        self.resumeCut = resumeCut
        self.turnsPage = turnsPage
        self.itemPagesByTurn = itemPagesByTurn
        self.protocolMetadata = protocolMetadata
        self.isStaleAfterReconnect = isStaleAfterReconnect
    }
}

/// Known thread metadata plus lossless protocol objects for fields whose schema is
/// still open in alpha releases.
public struct CanonicalThreadMetadata: Sendable, Equatable {
    public var agentNickname: String?
    public var agentRole: String?
    public var cliVersion: String?
    public var createdAt: ProtocolSeconds?
    public var cwd: CodexJSONValue?
    public var ephemeral: Bool?
    public var extra: CodexJSONValue?
    public var forkedFromID: ThreadID?
    public var gitInfo: CodexJSONValue?
    public var modelProvider: String?
    public var name: String?
    public var parentThreadID: ThreadID?
    public var path: String?
    public var preview: String?
    public var recencyAt: ProtocolSeconds?
    public var sessionID: String?
    public var source: CodexJSONValue?
    public var threadSource: CodexJSONValue?
    public var updatedAt: ProtocolSeconds?
    public var extensions: [String: CodexJSONValue]

    public init(
        agentNickname: String? = nil,
        agentRole: String? = nil,
        cliVersion: String? = nil,
        createdAt: ProtocolSeconds? = nil,
        cwd: CodexJSONValue? = nil,
        ephemeral: Bool? = nil,
        extra: CodexJSONValue? = nil,
        forkedFromID: ThreadID? = nil,
        gitInfo: CodexJSONValue? = nil,
        modelProvider: String? = nil,
        name: String? = nil,
        parentThreadID: ThreadID? = nil,
        path: String? = nil,
        preview: String? = nil,
        recencyAt: ProtocolSeconds? = nil,
        sessionID: String? = nil,
        source: CodexJSONValue? = nil,
        threadSource: CodexJSONValue? = nil,
        updatedAt: ProtocolSeconds? = nil,
        extensions: [String: CodexJSONValue] = [:]
    ) {
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.cliVersion = cliVersion
        self.createdAt = createdAt
        self.cwd = cwd
        self.ephemeral = ephemeral
        self.extra = extra
        self.forkedFromID = forkedFromID
        self.gitInfo = gitInfo
        self.modelProvider = modelProvider
        self.name = name
        self.parentThreadID = parentThreadID
        self.path = path
        self.preview = preview
        self.recencyAt = recencyAt
        self.sessionID = sessionID
        self.source = source
        self.threadSource = threadSource
        self.updatedAt = updatedAt
        self.extensions = extensions
    }
}

public enum CanonicalThreadGoalStatus: Sendable, Equatable, Codable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "paused": self = .paused
        case "blocked": self = .blocked
        case "usageLimited": self = .usageLimited
        case "budgetLimited": self = .budgetLimited
        case "complete": self = .complete
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .paused: "paused"
        case .blocked: "blocked"
        case .usageLimited: "usageLimited"
        case .budgetLimited: "budgetLimited"
        case .complete: "complete"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

public struct CanonicalThreadGoal: Sendable, Equatable {
    public let threadID: ThreadID
    public var objective: String
    public var status: CanonicalThreadGoalStatus
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public var createdAt: ProtocolSeconds
    public var updatedAt: ProtocolSeconds
    public var extensions: [String: CodexJSONValue]

    public init(
        threadID: ThreadID,
        objective: String,
        status: CanonicalThreadGoalStatus,
        tokenBudget: Int64? = nil,
        tokensUsed: Int64,
        timeUsedSeconds: Int64,
        createdAt: ProtocolSeconds,
        updatedAt: ProtocolSeconds,
        extensions: [String: CodexJSONValue] = [:]
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.extensions = extensions
    }
}

/// Global account materialized state. Authentication secrets never enter this model.
public struct CanonicalAccountState: Sendable, Equatable {
    public internal(set) var authMode: String?
    public internal(set) var planType: String?
    public internal(set) var rateLimits: [String: CodexJSONValue]
    public internal(set) var extensions: [String: CodexJSONValue]
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        authMode: String? = nil,
        planType: String? = nil,
        rateLimits: [String: CodexJSONValue] = [:],
        extensions: [String: CodexJSONValue] = [:],
        lastChangedRevision: StateRevision = .zero
    ) {
        self.authMode = authMode
        self.planType = planType
        self.rateLimits = rateLimits
        self.extensions = extensions
        self.lastChangedRevision = lastChangedRevision
    }
}

/// Sparse account updates distinguish absence from explicit clearing. Rolling
/// rate-limit updates merge non-null root fields; full reads replace the snapshot.
public struct CanonicalAccountPatch: Sendable, Equatable {
    public var authMode: CanonicalFieldUpdate<String>
    public var planType: CanonicalFieldUpdate<String>
    public var rateLimits: CanonicalFieldUpdate<[String: CodexJSONValue]>
    public var rateLimitsAreSparse: Bool
    public var extensions: [String: CodexJSONValue]

    public init(
        authMode: CanonicalFieldUpdate<String> = .unchanged,
        planType: CanonicalFieldUpdate<String> = .unchanged,
        rateLimits: CanonicalFieldUpdate<[String: CodexJSONValue]> = .unchanged,
        rateLimitsAreSparse: Bool = true,
        extensions: [String: CodexJSONValue] = [:]
    ) {
        self.authMode = authMode
        self.planType = planType
        self.rateLimits = rateLimits
        self.rateLimitsAreSparse = rateLimitsAreSparse
        self.extensions = extensions
    }
}

// MARK: - Global MCP startup state

/// Exact identity of one app-server MCP startup sequence.
///
/// A server can start globally or for one thread, so the optional thread is
/// part of the protocol identity rather than an observation entity. The whole
/// bounded collection is a global canonical-state facet.
public struct CanonicalMCPServerStartupKey: Sendable, Hashable {
    public let threadID: ThreadID?
    public let serverName: String

    public init(threadID: ThreadID? = nil, serverName: String) {
        self.threadID = threadID
        self.serverName = serverName
    }
}

/// Latest generated app-server startup status for one exact MCP identity.
public struct CanonicalMCPServerStartupStatus: Sendable, Equatable {
    public let status: CodexSchemaMCPServerStartupState
    public let error: String?
    public let failureReason: CodexSchemaMCPServerStartupFailureReason?
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        status: CodexSchemaMCPServerStartupState,
        error: String? = nil,
        failureReason: CodexSchemaMCPServerStartupFailureReason? = nil,
        lastChangedRevision: StateRevision = .zero
    ) {
        self.status = status
        self.error = error
        self.failureReason = failureReason
        self.lastChangedRevision = lastChangedRevision
    }
}

// MARK: - Item payload and streaming overlays

public enum ThreadItemKind: Sendable, Hashable, Codable {
    case userMessage
    case hookPrompt
    case agentMessage
    case plan
    case reasoning
    case commandExecution
    case fileChange
    case mcpToolCall
    case dynamicToolCall
    case collabAgentToolCall
    case subAgentActivity
    case webSearch
    case imageView
    case sleep
    case imageGeneration
    case enteredReviewMode
    case exitedReviewMode
    case contextCompaction
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "userMessage": self = .userMessage
        case "hookPrompt": self = .hookPrompt
        case "agentMessage": self = .agentMessage
        case "plan": self = .plan
        case "reasoning": self = .reasoning
        case "commandExecution": self = .commandExecution
        case "fileChange": self = .fileChange
        case "mcpToolCall": self = .mcpToolCall
        case "dynamicToolCall": self = .dynamicToolCall
        case "collabAgentToolCall": self = .collabAgentToolCall
        case "subAgentActivity": self = .subAgentActivity
        case "webSearch": self = .webSearch
        case "imageView": self = .imageView
        case "sleep": self = .sleep
        case "imageGeneration": self = .imageGeneration
        case "enteredReviewMode": self = .enteredReviewMode
        case "exitedReviewMode": self = .exitedReviewMode
        case "contextCompaction": self = .contextCompaction
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .userMessage: "userMessage"
        case .hookPrompt: "hookPrompt"
        case .agentMessage: "agentMessage"
        case .plan: "plan"
        case .reasoning: "reasoning"
        case .commandExecution: "commandExecution"
        case .fileChange: "fileChange"
        case .mcpToolCall: "mcpToolCall"
        case .dynamicToolCall: "dynamicToolCall"
        case .collabAgentToolCall: "collabAgentToolCall"
        case .subAgentActivity: "subAgentActivity"
        case .webSearch: "webSearch"
        case .imageView: "imageView"
        case .sleep: "sleep"
        case .imageGeneration: "imageGeneration"
        case .enteredReviewMode: "enteredReviewMode"
        case .exitedReviewMode: "exitedReviewMode"
        case .contextCompaction: "contextCompaction"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Authority only advances. A completed item replaces its speculative stream state.
public enum ItemAuthority: Int, Codable, Sendable, Hashable, Comparable {
    case placeholder
    case started
    case completed

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Chunk storage avoids rebuilding a cumulative String for every streaming delta.
public struct TextChunkBuffer: Sendable, Equatable {
    public private(set) var chunks: [String]
    public private(set) var utf8ByteCount: Int

    public init(chunks: [String] = []) {
        self.chunks = chunks
        self.utf8ByteCount = chunks.reduce(into: 0) { $0 += $1.utf8.count }
    }

    public var isEmpty: Bool { chunks.isEmpty }

    public mutating func append(_ delta: String) {
        chunks.append(delta)
        utf8ByteCount += delta.utf8.count
    }

    public func joined() -> String {
        chunks.joined()
    }
}

public enum ItemDelta: Sendable, Equatable {
    case agentMessage(String)
    case plan(String)
    case reasoningSummary(index: Int, delta: String)
    case reasoningContent(index: Int, delta: String)
    case commandOutput(String)
    case fileChangeOutput(String)
    case mcpProgress(String)
    case terminalInteraction(processID: String, stdin: String)
}

public struct CanonicalTerminalInteraction: Sendable, Equatable {
    public let processID: String
    public let stdin: String

    public init(processID: String, stdin: String) {
        self.processID = processID
        self.stdin = stdin
    }
}

/// Typed live-only fields. This overlay is discarded when an authoritative
/// `item/completed` object supplies the final payload.
public struct ItemLiveOverlay: Sendable, Equatable {
    public var agentMessage: TextChunkBuffer
    public var plan: TextChunkBuffer
    public var reasoningSummary: [Int: TextChunkBuffer]
    public var reasoningContent: [Int: TextChunkBuffer]
    public var commandOutput: TextChunkBuffer
    public var fileChangeOutput: TextChunkBuffer
    public var mcpProgress: TextChunkBuffer
    public var terminalInteractions: [CanonicalTerminalInteraction]

    public init(
        agentMessage: TextChunkBuffer = .init(),
        plan: TextChunkBuffer = .init(),
        reasoningSummary: [Int: TextChunkBuffer] = [:],
        reasoningContent: [Int: TextChunkBuffer] = [:],
        commandOutput: TextChunkBuffer = .init(),
        fileChangeOutput: TextChunkBuffer = .init(),
        mcpProgress: TextChunkBuffer = .init(),
        terminalInteractions: [CanonicalTerminalInteraction] = []
    ) {
        self.agentMessage = agentMessage
        self.plan = plan
        self.reasoningSummary = reasoningSummary
        self.reasoningContent = reasoningContent
        self.commandOutput = commandOutput
        self.fileChangeOutput = fileChangeOutput
        self.mcpProgress = mcpProgress
        self.terminalInteractions = terminalInteractions
    }

    public var isEmpty: Bool {
        agentMessage.isEmpty
            && plan.isEmpty
            && reasoningSummary.values.allSatisfy(\.isEmpty)
            && reasoningContent.values.allSatisfy(\.isEmpty)
            && commandOutput.isEmpty
            && fileChangeOutput.isEmpty
            && mcpProgress.isEmpty
            && terminalInteractions.isEmpty
    }

    public mutating func append(_ delta: ItemDelta) {
        switch delta {
        case .agentMessage(let text):
            agentMessage.append(text)
        case .plan(let text):
            plan.append(text)
        case .reasoningSummary(let index, let text):
            reasoningSummary[index, default: TextChunkBuffer()].append(text)
        case .reasoningContent(let index, let text):
            reasoningContent[index, default: TextChunkBuffer()].append(text)
        case .commandOutput(let text):
            commandOutput.append(text)
        case .fileChangeOutput(let text):
            fileChangeOutput.append(text)
        case .mcpProgress(let text):
            mcpProgress.append(text)
        case .terminalInteraction(let processID, let stdin):
            terminalInteractions.append(.init(processID: processID, stdin: stdin))
        }
    }
}

// MARK: - Normalized records

/// Whether the materialized entity is known to equal a server-authoritative view.
/// A resumed active turn can be uncertain until its terminal full-item resync.
public enum StateConsistency: String, Codable, Sendable, Hashable {
    case authoritative
    case partial
    case uncertain

    public var requiresResync: Bool { self == .uncertain }
}

public enum CanonicalPlanStepStatus: Sendable, Equatable, Codable {
    case pending
    case inProgress
    case completed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .inProgress: "inProgress"
        case .completed: "completed"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

public struct CanonicalPlanStep: Sendable, Equatable {
    public var step: String
    public var status: CanonicalPlanStepStatus

    public init(step: String, status: CanonicalPlanStepStatus) {
        self.step = step
        self.status = status
    }
}

public struct CanonicalTokenUsageBreakdown: Sendable, Equatable {
    public var inputTokens: Int
    public var cacheWriteInputTokens: Int?
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int,
        cacheWriteInputTokens: Int? = nil,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct CanonicalTokenUsage: Sendable, Equatable {
    public var last: CanonicalTokenUsageBreakdown
    public var total: CanonicalTokenUsageBreakdown
    public var modelContextWindow: Int?

    public init(
        last: CanonicalTokenUsageBreakdown,
        total: CanonicalTokenUsageBreakdown,
        modelContextWindow: Int? = nil
    ) {
        self.last = last
        self.total = total
        self.modelContextWindow = modelContextWindow
    }
}

/// The small piece of turn state kept after a thread's transcript detail is
/// evicted. Sidebar/status projections must not need to retain an entire turn
/// (including plans, diffs, token usage, and item order) just to preserve the
/// most recent terminal state.
public struct CanonicalLatestTurnSummary: Sendable, Equatable {
    public let id: TurnID
    public let status: CanonicalTurnStatus

    public init(id: TurnID, status: CanonicalTurnStatus) {
        self.id = id
        self.status = status
    }
}

public struct CanonicalThread: Sendable, Equatable, Identifiable {
    public let id: ThreadID
    public internal(set) var metadata: CanonicalThreadMetadata
    public internal(set) var status: CanonicalThreadStatus
    public internal(set) var turnOrder: [TurnID]
    public internal(set) var retainedLatestTurn: CanonicalLatestTurnSummary?
    public internal(set) var history: CanonicalHistoryState
    public internal(set) var isArchived: Bool?
    public internal(set) var isLoaded: Bool
    public internal(set) var connectedEnvironmentIDs: Set<String>
    public internal(set) var goal: CanonicalThreadGoal?
    public internal(set) var settings: [String: CodexJSONValue]?
    public internal(set) var consistency: StateConsistency
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        id: ThreadID,
        metadata: CanonicalThreadMetadata = .init(),
        status: CanonicalThreadStatus = .notLoaded,
        turnOrder: [TurnID] = [],
        retainedLatestTurn: CanonicalLatestTurnSummary? = nil,
        history: CanonicalHistoryState = .init(),
        isArchived: Bool? = nil,
        isLoaded: Bool = false,
        connectedEnvironmentIDs: Set<String> = [],
        goal: CanonicalThreadGoal? = nil,
        settings: [String: CodexJSONValue]? = nil,
        consistency: StateConsistency = .partial,
        lastChangedRevision: StateRevision = .zero
    ) {
        self.id = id
        self.metadata = metadata
        self.status = status
        self.turnOrder = turnOrder.removingDuplicateIDs()
        self.retainedLatestTurn = retainedLatestTurn
        self.history = history
        self.isArchived = isArchived
        self.isLoaded = isLoaded
        self.connectedEnvironmentIDs = connectedEnvironmentIDs
        self.goal = goal
        self.settings = settings
        self.consistency = consistency
        self.lastChangedRevision = lastChangedRevision
    }
}

public struct CanonicalTurn: Sendable, Equatable, Identifiable {
    public var id: TurnKey { key }
    public let key: TurnKey
    public internal(set) var status: CanonicalTurnStatus
    public internal(set) var error: CanonicalTurnError?
    public internal(set) var startedAt: ProtocolSeconds?
    public internal(set) var completedAt: ProtocolSeconds?
    public internal(set) var duration: DurationMilliseconds?
    public internal(set) var itemOrder: [ItemID]
    public internal(set) var itemsCoverage: StateCoverage
    public internal(set) var itemsConsistency: StateConsistency
    public internal(set) var plan: [CanonicalPlanStep]?
    public internal(set) var planExplanation: String?
    public internal(set) var diff: String?
    public internal(set) var tokenUsage: CanonicalTokenUsage?
    public internal(set) var moderationMetadata: CodexJSONValue?
    public internal(set) var extensions: [String: CodexJSONValue]
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        key: TurnKey,
        status: CanonicalTurnStatus = .inProgress,
        error: CanonicalTurnError? = nil,
        startedAt: ProtocolSeconds? = nil,
        completedAt: ProtocolSeconds? = nil,
        duration: DurationMilliseconds? = nil,
        itemOrder: [ItemID] = [],
        itemsCoverage: StateCoverage = .notLoaded,
        itemsConsistency: StateConsistency = .partial,
        plan: [CanonicalPlanStep]? = nil,
        planExplanation: String? = nil,
        diff: String? = nil,
        tokenUsage: CanonicalTokenUsage? = nil,
        moderationMetadata: CodexJSONValue? = nil,
        extensions: [String: CodexJSONValue] = [:],
        lastChangedRevision: StateRevision = .zero
    ) {
        self.key = key
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
        self.itemOrder = itemOrder.removingDuplicateIDs()
        self.itemsCoverage = itemsCoverage
        self.itemsConsistency = itemsConsistency
        self.plan = plan
        self.planExplanation = planExplanation
        self.diff = diff
        self.tokenUsage = tokenUsage
        self.moderationMetadata = moderationMetadata
        self.extensions = extensions
        self.lastChangedRevision = lastChangedRevision
    }
}

public struct CanonicalItem: Sendable, Equatable, Identifiable {
    public var id: ItemKey { key }
    public let key: ItemKey
    public internal(set) var kind: ThreadItemKind
    /// Lossless app-server item object. Known variants are identified by `kind`;
    /// alpha-only and unknown fields remain available without a parallel sidecar.
    public internal(set) var payload: [String: CodexJSONValue]
    public internal(set) var authority: ItemAuthority
    public internal(set) var startedAt: ProtocolMilliseconds?
    public internal(set) var completedAt: ProtocolMilliseconds?
    public internal(set) var liveOverlay: ItemLiveOverlay
    /// Replacement-style live protocol values such as file patches and terminal
    /// interaction metadata. Completed payload authority clears these fields.
    public internal(set) var liveFields: [String: CodexJSONValue]
    public internal(set) var clientUserMessageID: SubmissionIntentID?
    public internal(set) var consistency: StateConsistency
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        key: ItemKey,
        kind: ThreadItemKind = .unknown("unknown"),
        payload: [String: CodexJSONValue] = [:],
        authority: ItemAuthority = .placeholder,
        startedAt: ProtocolMilliseconds? = nil,
        completedAt: ProtocolMilliseconds? = nil,
        liveOverlay: ItemLiveOverlay = .init(),
        liveFields: [String: CodexJSONValue] = [:],
        clientUserMessageID: SubmissionIntentID? = nil,
        consistency: StateConsistency = .partial,
        lastChangedRevision: StateRevision = .zero
    ) {
        self.key = key
        self.kind = kind
        self.payload = payload
        self.authority = authority
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.liveOverlay = liveOverlay
        self.liveFields = liveFields
        self.clientUserMessageID = clientUserMessageID
        self.consistency = consistency
        self.lastChangedRevision = lastChangedRevision
    }
}

// MARK: - Explicit local intent overlay

public enum SubmissionIntentState: Sendable, Equatable {
    case pending
    case reconciled(item: ItemKey)
    case failed(message: String)
    /// The request may have reached app-server before the connection was lost.
    case indeterminate(message: String?)
}

public struct SubmissionIntent: Sendable, Equatable, Identifiable {
    public let id: SubmissionIntentID
    public let threadID: ThreadID
    public let expectedTurnID: TurnID?
    public let input: [CodexJSONValue]
    public let localOrdinal: UInt64
    public internal(set) var state: SubmissionIntentState
    public internal(set) var lastChangedRevision: StateRevision

    public init(
        id: SubmissionIntentID,
        threadID: ThreadID,
        expectedTurnID: TurnID? = nil,
        input: [CodexJSONValue],
        localOrdinal: UInt64,
        state: SubmissionIntentState = .pending,
        lastChangedRevision: StateRevision = .zero
    ) {
        self.id = id
        self.threadID = threadID
        self.expectedTurnID = expectedTurnID
        self.input = input
        self.localOrdinal = localOrdinal
        self.state = state
        self.lastChangedRevision = lastChangedRevision
    }
}

// MARK: - Snapshot and actor-isolated storage

/// Immutable Sendable view returned to projections and other callers.
public struct CanonicalStateSnapshot: Sendable, Equatable {
    public let revision: StateRevision
    public let account: CanonicalAccountState
    public let mcpServerStartupStatuses: [
        CanonicalMCPServerStartupKey: CanonicalMCPServerStartupStatus
    ]
    public let threadOrder: [ThreadID]
    public let threads: [ThreadID: CanonicalThread]
    public let turns: [TurnKey: CanonicalTurn]
    public let items: [ItemKey: CanonicalItem]
    public let submissionIntents: [SubmissionIntentID: SubmissionIntent]

    public init(
        revision: StateRevision = .zero,
        account: CanonicalAccountState = .init(),
        mcpServerStartupStatuses: [
            CanonicalMCPServerStartupKey: CanonicalMCPServerStartupStatus
        ] = [:],
        threadOrder: [ThreadID] = [],
        threads: [ThreadID: CanonicalThread] = [:],
        turns: [TurnKey: CanonicalTurn] = [:],
        items: [ItemKey: CanonicalItem] = [:],
        submissionIntents: [SubmissionIntentID: SubmissionIntent] = [:]
    ) {
        self.revision = revision
        self.account = account
        self.mcpServerStartupStatuses = mcpServerStartupStatuses
        self.threadOrder = threadOrder.removingDuplicateIDs()
        self.threads = threads
        self.turns = turns
        self.items = items
        self.submissionIntents = submissionIntents
    }

    public func turns(in threadID: ThreadID) -> [CanonicalTurn] {
        guard let thread = threads[threadID] else { return [] }
        return thread.turnOrder.compactMap { turns[TurnKey(threadID: threadID, turnID: $0)] }
    }

    public func items(in turnKey: TurnKey) -> [CanonicalItem] {
        guard let turn = turns[turnKey] else { return [] }
        return turn.itemOrder.compactMap {
            items[ItemKey(threadID: turnKey.threadID, turnID: turnKey.turnID, itemID: $0)]
        }
    }
}

/// Synchronous normalized graph. The sole CodexSession actor owns this value, so
/// state reduction introduces no second executor or ordering seam.
internal struct CanonicalStateGraph: Sendable {
    var revision: StateRevision = .zero
    var account = CanonicalAccountState()
    var mcpServerStartupStatuses: [
        CanonicalMCPServerStartupKey: CanonicalMCPServerStartupStatus
    ] = [:]
    var mcpServerStartupStatusLRU: [CanonicalMCPServerStartupKey] = []
    var threadOrder: [ThreadID] = []
    var threads: [ThreadID: CanonicalThread] = [:]
    var turns: [TurnKey: CanonicalTurn] = [:]
    var items: [ItemKey: CanonicalItem] = [:]
    var submissionIntents: [SubmissionIntentID: SubmissionIntent] = [:]

    func snapshot() -> CanonicalStateSnapshot {
        CanonicalStateSnapshot(
            revision: revision,
            account: account,
            mcpServerStartupStatuses: mcpServerStartupStatuses,
            threadOrder: threadOrder,
            threads: threads,
            turns: turns,
            items: items,
            submissionIntents: submissionIntents
        )
    }
}

private extension Array where Element: Hashable {
    func removingDuplicateIDs() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
