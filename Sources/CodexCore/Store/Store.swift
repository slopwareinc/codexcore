import Foundation
import Observation

// MARK: - Reducer States & Models

public enum CodexThreadStatus: String, Codable, Sendable {
    case idle
    case active
    case waiting
    case completed
    case failed
}

public enum CodexTurnStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
}

public struct CodexTurnSnapshot: Identifiable, Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case error
        case startedAt
        case completedAt
        case items
        case usage
        case plan
        case planExplanation
        case diff
        case itemDetails
    }

    public var id: String
    public var status: CodexTurnStatus
    public var error: String?
    public var startedAt: Date
    public var completedAt: Date?
    public var items: [CodexTimelineItem]
    /// Rich item details keyed by item ID. `items` stays lean for SDK callers;
    /// UI projections use this sidecar when they need command/file/tool
    /// transcript fields that do not belong in the public timeline enum.
    public var itemDetails: [String: CodexTimelineItemDetail]
    public var usage: ThreadTokenUsage?
    /// Latest agent plan for this turn (`turn/plan/updated`).
    public var plan: [TurnPlanStep]?
    public var planExplanation: String?
    /// Latest aggregated unified diff for this turn (`turn/diff/updated`).
    public var diff: String?

    public init(
        id: String,
        status: CodexTurnStatus = .running,
        error: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        items: [CodexTimelineItem] = [],
        itemDetails: [String: CodexTimelineItemDetail] = [:],
        usage: ThreadTokenUsage? = nil,
        plan: [TurnPlanStep]? = nil,
        planExplanation: String? = nil,
        diff: String? = nil
    ) {
        self.id = id
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.items = items
        self.itemDetails = itemDetails
        self.usage = usage
        self.plan = plan
        self.planExplanation = planExplanation
        self.diff = diff
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.status = try container.decode(CodexTurnStatus.self, forKey: .status)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        self.items = try container.decode([CodexTimelineItem].self, forKey: .items)
        self.itemDetails = try container.decodeIfPresent([String: CodexTimelineItemDetail].self, forKey: .itemDetails) ?? [:]
        self.usage = try container.decodeIfPresent(ThreadTokenUsage.self, forKey: .usage)
        self.plan = try container.decodeIfPresent([TurnPlanStep].self, forKey: .plan)
        self.planExplanation = try container.decodeIfPresent(String.self, forKey: .planExplanation)
        self.diff = try container.decodeIfPresent(String.self, forKey: .diff)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(items, forKey: .items)
        if !itemDetails.isEmpty {
            try container.encode(itemDetails, forKey: .itemDetails)
        }
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encodeIfPresent(planExplanation, forKey: .planExplanation)
        try container.encodeIfPresent(diff, forKey: .diff)
    }
}

public struct CodexThreadSnapshot: Identifiable, Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case status
        case cwd
        case model
        case turns
        case childThreads
        case pendingApprovals
        case goal
        case updatedAt
    }

    public var id: String
    public var sessionID: String?
    public var status: CodexThreadStatus
    public var cwd: String
    public var model: String
    public var turns: [CodexTurnSnapshot]
    public var childThreads: [CodexChildThreadReference]
    public var pendingApprovals: [CodexApprovalRequest]
    public var goal: ThreadGoal?
    public var updatedAt: Date

    public init(
        id: String,
        sessionID: String? = nil,
        status: CodexThreadStatus = .idle,
        cwd: String = "",
        model: String = "",
        turns: [CodexTurnSnapshot] = [],
        childThreads: [CodexChildThreadReference] = [],
        pendingApprovals: [CodexApprovalRequest] = [],
        goal: ThreadGoal? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.status = status
        self.cwd = cwd
        self.model = model
        self.turns = turns
        self.childThreads = childThreads
        self.pendingApprovals = pendingApprovals
        self.goal = goal
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        self.status = try container.decode(CodexThreadStatus.self, forKey: .status)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.model = try container.decode(String.self, forKey: .model)
        self.turns = try container.decode([CodexTurnSnapshot].self, forKey: .turns)
        self.childThreads = try container.decodeIfPresent([CodexChildThreadReference].self, forKey: .childThreads) ?? []
        self.pendingApprovals = try container.decode([CodexApprovalRequest].self, forKey: .pendingApprovals)
        self.goal = try container.decodeIfPresent(ThreadGoal.self, forKey: .goal)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encode(status, forKey: .status)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(model, forKey: .model)
        try container.encode(turns, forKey: .turns)
        if !childThreads.isEmpty {
            try container.encode(childThreads, forKey: .childThreads)
        }
        try container.encode(pendingApprovals, forKey: .pendingApprovals)
        try container.encodeIfPresent(goal, forKey: .goal)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct CodexChildThreadReference: Identifiable, Codable, Sendable, Equatable {
    public var id: String { threadID }
    public var threadID: String
    public var itemID: String?
    public var name: String?
    public var title: String?
    public var prompt: String?
    public var status: String?

    public init(
        threadID: String,
        itemID: String? = nil,
        name: String? = nil,
        title: String? = nil,
        prompt: String? = nil,
        status: String? = nil
    ) {
        self.threadID = threadID
        self.itemID = itemID
        self.name = name
        self.title = title
        self.prompt = prompt
        self.status = status
    }
}

// MARK: - Timeline Item Enum

public enum CodexTimelineItem: Identifiable, Codable, Sendable, Equatable {
    case userMessage(id: String, text: String, timestamp: Date)
    case assistantMessage(id: String, text: String, timestamp: Date, isStreaming: Bool)
    case reasoning(id: String, text: String, timestamp: Date, isStreaming: Bool)
    case toolCall(id: String, name: String, arguments: String, status: String, timestamp: Date)
    case commandExecution(id: String, command: String, output: String, status: String, timestamp: Date)
    case fileChange(id: String, path: String, patch: String, status: String, timestamp: Date)
    case mcpToolCall(id: String, server: String, tool: String, status: String, timestamp: Date, progress: [String])
    case warning(id: String, text: String, timestamp: Date)

    public var id: String {
        switch self {
        case .userMessage(let id, _, _),
             .assistantMessage(let id, _, _, _),
             .reasoning(let id, _, _, _),
             .toolCall(let id, _, _, _, _),
             .commandExecution(let id, _, _, _, _),
             .fileChange(let id, _, _, _, _),
             .mcpToolCall(let id, _, _, _, _, _),
             .warning(let id, _, _):
            return id
        }
    }

    public var timestamp: Date {
        switch self {
        case .userMessage(_, _, let t),
             .assistantMessage(_, _, let t, _),
             .reasoning(_, _, let t, _),
             .toolCall(_, _, _, _, let t),
             .commandExecution(_, _, _, _, let t),
             .fileChange(_, _, _, _, let t),
             .mcpToolCall(_, _, _, _, let t, _),
             .warning(_, _, let t):
            return t
        }
    }
}

public enum CodexTimelineItemDetail: Codable, Sendable, Equatable {
    case assistantMessage(CodexAssistantMessageDetail)
    case commandExecution(CodexCommandExecutionDetail)
    case fileChange(CodexFileChangeDetail)
    case toolCall(CodexToolCallDetail)
}

public struct CodexAssistantMessageDetail: Codable, Sendable, Equatable {
    public var phase: String?

    public init(phase: String? = nil) {
        self.phase = phase
    }
}

public struct CodexCommandExecutionDetail: Codable, Sendable, Equatable {
    public var command: String
    public var cwd: String?
    public var output: String
    public var status: String
    public var exitCode: Int?

    public init(command: String, cwd: String? = nil, output: String = "", status: String, exitCode: Int? = nil) {
        self.command = command
        self.cwd = cwd
        self.output = output
        self.status = status
        self.exitCode = exitCode
    }
}

public struct CodexFileChangeDetail: Codable, Sendable, Equatable {
    public var path: String?
    public var kind: String
    public var diff: String
    public var output: String
    public var status: String

    public init(path: String? = nil, kind: String = "update", diff: String = "", output: String = "", status: String) {
        self.path = path
        self.kind = kind
        self.diff = diff
        self.output = output
        self.status = status
    }
}

public struct CodexToolCallDetail: Codable, Sendable, Equatable {
    public var server: String?
    public var tool: String
    public var arguments: String
    public var status: String
    public var progress: [String]
    public var result: String
    public var error: String?
    public var durationMilliseconds: Int?

    public init(
        server: String? = nil,
        tool: String,
        arguments: String = "",
        status: String,
        progress: [String] = [],
        result: String = "",
        error: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.status = status
        self.progress = progress
        self.result = result
        self.error = error
        self.durationMilliseconds = durationMilliseconds
    }
}

// MARK: - CodexCoreStore (Main State Reducer)

@Observable
@MainActor
public final class CodexCoreStore {
    public private(set) var activeThread: CodexThreadSnapshot?
    public private(set) var threadSnapshotsByID: [String: CodexThreadSnapshot]
    public private(set) var accountAuthMode: CodexSchemaAuthMode?
    public private(set) var accountPlanType: CodexSchemaPlanType?
    public private(set) var accountRateLimits: CodexSchemaRateLimitSnapshot?
    public private(set) var accountRateLimitsByLimitID: [String: CodexSchemaRateLimitSnapshot]?
    public private(set) var isThinking = false
    /// User-input requests awaiting answers, in arrival order. Request IDs are
    /// unique and are used to resolve one prompt without disturbing others.
    public private(set) var pendingUserInputs: [CodexUserInputRequest] = []
    /// The oldest pending user-input request.
    @available(*, deprecated, message: "Use pendingUserInputs to support concurrent requests.")
    public var pendingUserInput: CodexUserInputRequest? { pendingUserInputs.first }
    /// Escalated approval requests awaiting a decision, store-wide. Requests
    /// whose `threadId` matches `activeThread` are mirrored into
    /// `activeThread.pendingApprovals` as well.
    public private(set) var pendingApprovals: [CodexApprovalRequest] = []

    // Active streaming text buffers by item ID
    private var streamingBuffers: [String: String] = [:]

    public init(activeThread: CodexThreadSnapshot? = nil, threadSnapshotsByID: [String: CodexThreadSnapshot] = [:]) {
        self.activeThread = activeThread
        self.threadSnapshotsByID = threadSnapshotsByID
        if let activeThread {
            self.threadSnapshotsByID[activeThread.id] = activeThread
        }
    }

    public func threadSnapshot(id: String) -> CodexThreadSnapshot? {
        threadSnapshotsByID[id] ?? (activeThread?.id == id ? activeThread : nil)
    }

    public func turnSnapshot(threadID: String, turnID: String?) -> CodexTurnSnapshot? {
        guard let thread = threadSnapshot(id: threadID) else { return nil }
        if let turnID {
            return thread.turns.first(where: { $0.id == turnID })
        }
        return thread.turns.last
    }

    public func activateThread(id: String) {
        if let thread = threadSnapshotsByID[id] {
            activeThread = thread
        }
    }

    public func hydrate(_ result: CodexThreadHistoryHydrationResult, activateParent: Bool = true) {
        storeThread(result.parent.snapshot, activate: activateParent)
        for child in result.childThreads {
            storeThread(child.snapshot)
        }
    }

    private func storeThread(_ thread: CodexThreadSnapshot, activate: Bool = false) {
        threadSnapshotsByID[thread.id] = thread
        if activate || activeThread?.id == thread.id {
            activeThread = thread
        }
    }

    private func snapshotForMutation(threadID: String, status: CodexThreadStatus = .active) -> CodexThreadSnapshot {
        threadSnapshotsByID[threadID]
            ?? (activeThread?.id == threadID ? activeThread : nil)
            ?? CodexThreadSnapshot(id: threadID, status: status, updatedAt: Date())
    }

    private func turnIndex(_ turnID: String, in thread: inout CodexThreadSnapshot) -> Int? {
        guard !turnID.isEmpty else { return nil }
        if let index = thread.turns.firstIndex(where: { $0.id == turnID }) {
            return index
        }
        thread.turns.append(CodexTurnSnapshot(id: turnID))
        return thread.turns.count - 1
    }

    // MARK: - Reducer Action Handler

    public func dispatch(_ event: CodexServerEvent) {
        switch event {
        case .threadStarted(let threadId, _, let status):
            var thread = snapshotForMutation(threadID: threadId)
            thread.status = CodexThreadStatus(rawValue: status) ?? thread.status
            thread.updatedAt = Date()
            storeThread(thread, activate: activeThread == nil)

        case .accountUpdated(let payload):
            accountAuthMode = payload.authMode
            accountPlanType = payload.planType

        case .accountRateLimitsUpdated(let payload):
            accountRateLimits = payload.rateLimits
            accountRateLimitsByLimitID = nil

        case .threadStatusChanged(let threadId, let status):
            var thread = snapshotForMutation(threadID: threadId)
            thread.status = CodexThreadStatus(rawValue: status) ?? .idle
            thread.updatedAt = Date()
            storeThread(thread)

        case .threadGoalUpdated(let threadId, let goal):
            var thread = snapshotForMutation(threadID: threadId)
            thread.goal = goal
            thread.updatedAt = Date()
            storeThread(thread)

        case .threadGoalCleared(let threadId):
            var thread = snapshotForMutation(threadID: threadId)
            thread.goal = nil
            thread.updatedAt = Date()
            storeThread(thread)

        case .turnStarted(let threadId, let turnId):
            var thread = snapshotForMutation(threadID: threadId)
            if let idx = thread.turns.firstIndex(where: { $0.id == turnId }) {
                thread.turns[idx].status = .running
            } else {
                let turn = CodexTurnSnapshot(id: turnId, status: .running, startedAt: Date())
                thread.turns.append(turn)
            }
            thread.status = .active
            if activeThread?.id == threadId {
                isThinking = true
            }
            storeThread(thread)

        case .turnCompleted(let threadId, let turnId, let error):
            var thread = snapshotForMutation(threadID: threadId)
            let idx: Int
            if let existing = thread.turns.firstIndex(where: { $0.id == turnId }) {
                idx = existing
            } else {
                thread.turns.append(CodexTurnSnapshot(id: turnId))
                idx = thread.turns.count - 1
            }
            thread.turns[idx].status = error == nil ? .completed : .failed
            thread.turns[idx].error = error
            thread.turns[idx].completedAt = Date()
            thread.status = .idle
            if activeThread?.id == threadId {
                isThinking = false
            }
            storeThread(thread)

        case .itemStarted(let threadId, let turnId, let item):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }

            let timelineItem = CodexTimelineItemMapper.timelineItem(for: item)
            if thread.turns[idx].items.contains(where: { $0.id == item.id }) {
                upsertDetail(for: item, in: &thread.turns[idx])
                storeThread(thread)
                return
            }
            thread.turns[idx].items.append(timelineItem)
            upsertDetail(for: item, in: &thread.turns[idx])
            storeThread(thread)

        case .itemCompleted(let threadId, let turnId, let item):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }

            let timelineItem = CodexTimelineItemMapper.timelineItem(for: item)
            if let itemIdx = thread.turns[idx].items.firstIndex(where: { $0.id == item.id }) {
                thread.turns[idx].items[itemIdx] = timelineItem
            } else {
                thread.turns[idx].items.append(timelineItem)
            }
            upsertDetail(for: item, in: &thread.turns[idx])
            streamingBuffers.removeValue(forKey: item.id)
            storeThread(thread)

        case .messageDelta(let threadId, let turnId, let itemId, let delta):
            appendDelta(delta, threadId: threadId, itemId: itemId, turnId: turnId) { text in
                .assistantMessage(id: itemId, text: text, timestamp: Date(), isStreaming: true)
            }

        case .reasoningDelta(let threadId, let turnId, let itemId, let delta):
            appendDelta(delta, threadId: threadId, itemId: itemId, turnId: turnId) { text in
                .reasoning(id: itemId, text: text, timestamp: Date(), isStreaming: true)
            }

        case .planDelta(let threadId, let turnId, let itemId, let delta):
            appendDelta(delta, threadId: threadId, itemId: itemId, turnId: turnId) { text in
                .reasoning(id: itemId, text: "Plan update: \(text)", timestamp: Date(), isStreaming: true)
            }

        case .commandOutputDelta(let threadId, let turnId, let itemId, let delta):
            appendDelta(delta, threadId: threadId, itemId: itemId, turnId: turnId) { text in
                .commandExecution(id: itemId, command: "Running...", output: text, status: "active", timestamp: Date())
            }

        case .fileChangeOutputDelta(let threadId, let turnId, let itemId, let delta):
            appendDelta(delta, threadId: threadId, itemId: itemId, turnId: turnId) { text in
                .fileChange(id: itemId, path: "File changes", patch: text, status: "active", timestamp: Date())
            }

        case .fileChangePatchUpdated(let threadId, let turnId, let itemId, let path, let patch):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }
            let item = CodexTimelineItem.fileChange(
                id: itemId,
                path: path ?? "File changes",
                patch: patch,
                status: "active",
                timestamp: Date()
            )
            if let itemIdx = thread.turns[idx].items.firstIndex(where: { $0.id == itemId }) {
                thread.turns[idx].items[itemIdx] = item
            } else {
                thread.turns[idx].items.append(item)
            }
            thread.turns[idx].itemDetails[itemId] = .fileChange(CodexFileChangeDetail(
                path: path,
                kind: "update",
                diff: patch,
                output: "",
                status: "active"
            ))
            storeThread(thread)

        case .mcpToolCallProgress(let threadId, let turnId, let itemId, let message):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }
            if let itemIdx = thread.turns[idx].items.firstIndex(where: { $0.id == itemId }) {
                if case .mcpToolCall(let id, let server, let tool, _, let timestamp, let progress) = thread.turns[idx].items[itemIdx] {
                    thread.turns[idx].items[itemIdx] = .mcpToolCall(
                        id: id,
                        server: server,
                        tool: tool,
                        status: "inProgress",
                        timestamp: timestamp,
                        progress: progress + [message]
                    )
                }
            } else {
                thread.turns[idx].items.append(.mcpToolCall(
                    id: itemId,
                    server: "MCP",
                    tool: "Tool",
                    status: "inProgress",
                    timestamp: Date(),
                    progress: [message]
                ))
            }
            if let updated = thread.turns[idx].items.first(where: { $0.id == itemId }) {
                updateStreamingDetail(for: updated, in: &thread.turns[idx])
            }
            storeThread(thread)

        case .turnPlanUpdated(let threadId, let turnId, let plan, let explanation):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }
            thread.turns[idx].plan = plan
            thread.turns[idx].planExplanation = explanation
            storeThread(thread)

        case .turnDiffUpdated(let threadId, let turnId, let diff):
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }
            thread.turns[idx].diff = diff
            storeThread(thread)

        case .tokenUsageUpdated(let threadId, let turnId, let usage):
            guard let turnId else { return }
            var thread = snapshotForMutation(threadID: threadId)
            guard let idx = turnIndex(turnId, in: &thread) else { return }
            thread.turns[idx].usage = usage
            storeThread(thread)

        case .serverError(_, _):
            break

        case .unknown(let method, let params):
            print("[CodexCoreStore] Unhandled protocol event: \(method), params: \(params.keys)")
        }
    }

    public func dispatchRequest(_ request: CodexApprovalRequest) {
        if !pendingApprovals.contains(where: { $0.id == request.id }) {
            pendingApprovals.append(request)
        }
        var thread = snapshotForMutation(threadID: request.threadId, status: .waiting)
        guard !thread.pendingApprovals.contains(where: { $0.id == request.id }) else {
            storeThread(thread)
            return
        }
        thread.pendingApprovals.append(request)
        thread.status = .waiting
        storeThread(thread)
    }

    public func dispatchRequest(_ request: CodexUserInputRequest) {
        if let index = pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
            pendingUserInputs[index] = request
        } else {
            pendingUserInputs.append(request)
        }
    }

    public func resolveApproval(_ requestId: String) {
        pendingApprovals.removeAll(where: { $0.id == requestId })
        for threadID in Array(threadSnapshotsByID.keys) {
            guard var thread = threadSnapshotsByID[threadID] else { continue }
            thread.pendingApprovals.removeAll(where: { $0.id == requestId })
            if thread.pendingApprovals.isEmpty, thread.status == .waiting {
                thread.status = .active
            }
            storeThread(thread)
        }
    }

    public func resolveUserInput(_ requestId: String) {
        pendingUserInputs.removeAll(where: { $0.id == requestId })
    }

    @available(*, deprecated, message: "Resolve user input by request ID.")
    public func resolveUserInput() {
        guard let requestId = pendingUserInputs.first?.id else { return }
        resolveUserInput(requestId)
    }

    // MARK: - Delta Appender Helper

    private func appendDelta(
        _ delta: String,
        threadId: String,
        itemId: String,
        turnId: String,
        itemCreator: (String) -> CodexTimelineItem
    ) {
        var thread = snapshotForMutation(threadID: threadId)
        guard let turnIdx = turnIndex(turnId, in: &thread) else { return }

        streamingBuffers[itemId, default: ""].append(delta)
        let currentText = streamingBuffers[itemId, default: ""]

        let updatedItem = itemCreator(currentText)
        if let itemIdx = thread.turns[turnIdx].items.firstIndex(where: { $0.id == itemId }) {
            thread.turns[turnIdx].items[itemIdx] = updatedItem
        } else {
            thread.turns[turnIdx].items.append(updatedItem)
        }
        updateStreamingDetail(for: updatedItem, in: &thread.turns[turnIdx])

        storeThread(thread)
    }

    private func upsertDetail(for item: CodexServerItem, in turn: inout CodexTurnSnapshot) {
        guard let detail = CodexTimelineItemMapper.detail(for: item) else {
            turn.itemDetails.removeValue(forKey: item.id)
            return
        }
        turn.itemDetails[item.id] = detail
    }

    private func updateStreamingDetail(for item: CodexTimelineItem, in turn: inout CodexTurnSnapshot) {
        switch item {
        case .commandExecution(let id, let command, let output, let status, _):
            let existing: CodexCommandExecutionDetail?
            if case .commandExecution(let detail)? = turn.itemDetails[id] {
                existing = detail
            } else {
                existing = nil
            }
            turn.itemDetails[id] = .commandExecution(CodexCommandExecutionDetail(
                command: existing?.command ?? command,
                cwd: existing?.cwd,
                output: output,
                status: status,
                exitCode: existing?.exitCode
            ))
        case .fileChange(let id, let path, let patch, let status, _):
            let existing: CodexFileChangeDetail?
            if case .fileChange(let detail)? = turn.itemDetails[id] {
                existing = detail
            } else {
                existing = nil
            }
            turn.itemDetails[id] = .fileChange(CodexFileChangeDetail(
                path: existing?.path ?? (path.isEmpty ? nil : path),
                kind: existing?.kind ?? "update",
                diff: existing?.diff ?? "",
                output: patch,
                status: status
            ))
        case .mcpToolCall(let id, let server, let tool, let status, _, let progress):
            let existing: CodexToolCallDetail?
            if case .toolCall(let detail)? = turn.itemDetails[id] {
                existing = detail
            } else {
                existing = nil
            }
            turn.itemDetails[id] = .toolCall(CodexToolCallDetail(
                server: existing?.server ?? (server.isEmpty ? nil : server),
                tool: existing?.tool ?? (tool.isEmpty ? nil : tool) ?? "Tool",
                arguments: existing?.arguments ?? "",
                status: status,
                progress: progress,
                result: existing?.result ?? "",
                error: existing?.error,
                durationMilliseconds: existing?.durationMilliseconds
            ))
        default:
            break
        }
    }
}
