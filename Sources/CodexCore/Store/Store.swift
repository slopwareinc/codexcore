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
    public var id: String
    public var status: CodexTurnStatus
    public var error: String?
    public var startedAt: Date
    public var completedAt: Date?
    public var items: [CodexTimelineItem]
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
        self.usage = usage
        self.plan = plan
        self.planExplanation = planExplanation
        self.diff = diff
    }
}

public struct CodexThreadSnapshot: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String?
    public var status: CodexThreadStatus
    public var cwd: String
    public var model: String
    public var turns: [CodexTurnSnapshot]
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
        self.pendingApprovals = pendingApprovals
        self.goal = goal
        self.updatedAt = updatedAt
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

// MARK: - CodexCoreStore (Main State Reducer)

@Observable
@MainActor
public final class CodexCoreStore {
    public private(set) var activeThread: CodexThreadSnapshot?
    public private(set) var isThinking = false
    public private(set) var pendingUserInput: CodexUserInputRequest?
    /// Escalated approval requests awaiting a decision, store-wide. Requests
    /// whose `threadId` matches `activeThread` are mirrored into
    /// `activeThread.pendingApprovals` as well.
    public private(set) var pendingApprovals: [CodexApprovalRequest] = []

    // Active streaming text buffers by item ID
    private var streamingBuffers: [String: String] = [:]

    public init(activeThread: CodexThreadSnapshot? = nil) {
        self.activeThread = activeThread
    }

    // MARK: - Reducer Action Handler

    public func dispatch(_ event: CodexServerEvent) {
        switch event {
        case .threadStarted(let threadId, _, let status):
            if var thread = activeThread, thread.id == threadId {
                thread.status = CodexThreadStatus(rawValue: status) ?? thread.status
                thread.updatedAt = Date()
                self.activeThread = thread
            } else {
                self.activeThread = CodexThreadSnapshot(
                    id: threadId,
                    status: CodexThreadStatus(rawValue: status) ?? .active,
                    updatedAt: Date()
                )
            }

        case .threadStatusChanged(let threadId, let status):
            guard var thread = activeThread, thread.id == threadId else { return }
            thread.status = CodexThreadStatus(rawValue: status) ?? .idle
            thread.updatedAt = Date()
            self.activeThread = thread

        case .threadGoalUpdated(let threadId, let goal):
            guard var thread = activeThread, thread.id == threadId else { return }
            thread.goal = goal
            thread.updatedAt = Date()
            self.activeThread = thread

        case .threadGoalCleared(let threadId):
            guard var thread = activeThread, thread.id == threadId else { return }
            thread.goal = nil
            thread.updatedAt = Date()
            self.activeThread = thread

        case .turnStarted(let threadId, let turnId):
            guard var thread = activeThread, thread.id == threadId else { return }
            if let idx = thread.turns.firstIndex(where: { $0.id == turnId }) {
                thread.turns[idx].status = .running
            } else {
                let turn = CodexTurnSnapshot(id: turnId, status: .running, startedAt: Date())
                thread.turns.append(turn)
            }
            thread.status = .active
            isThinking = true
            self.activeThread = thread

        case .turnCompleted(let threadId, let turnId, let error):
            guard var thread = activeThread, thread.id == threadId else { return }
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
            isThinking = false
            self.activeThread = thread

        case .itemStarted(let threadId, let turnId, let item):
            guard var thread = activeThread, thread.id == threadId,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }

            let timelineItem = mapServerItem(item)
            if thread.turns[idx].items.contains(where: { $0.id == item.id }) {
                self.activeThread = thread
                return
            }
            thread.turns[idx].items.append(timelineItem)
            self.activeThread = thread

        case .itemCompleted(let threadId, let turnId, let item):
            guard var thread = activeThread, thread.id == threadId,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }

            let timelineItem = mapServerItem(item)
            if let itemIdx = thread.turns[idx].items.firstIndex(where: { $0.id == item.id }) {
                thread.turns[idx].items[itemIdx] = timelineItem
            } else {
                thread.turns[idx].items.append(timelineItem)
            }
            streamingBuffers.removeValue(forKey: item.id)
            self.activeThread = thread

        case .messageDelta(_, let turnId, let itemId, let delta):
            appendDelta(delta, itemId: itemId, turnId: turnId) { text in
                .assistantMessage(id: itemId, text: text, timestamp: Date(), isStreaming: true)
            }

        case .reasoningDelta(_, let turnId, let itemId, let delta):
            appendDelta(delta, itemId: itemId, turnId: turnId) { text in
                .reasoning(id: itemId, text: text, timestamp: Date(), isStreaming: true)
            }

        case .planDelta(_, let turnId, let itemId, let delta):
            appendDelta(delta, itemId: itemId, turnId: turnId) { text in
                .reasoning(id: itemId, text: "Plan update: \(text)", timestamp: Date(), isStreaming: true)
            }

        case .commandOutputDelta(_, let turnId, let itemId, let delta):
            appendDelta(delta, itemId: itemId, turnId: turnId) { text in
                .commandExecution(id: itemId, command: "Running...", output: text, status: "active", timestamp: Date())
            }

        case .fileChangeOutputDelta(_, let turnId, let itemId, let delta):
            appendDelta(delta, itemId: itemId, turnId: turnId) { text in
                .fileChange(id: itemId, path: "File changes", patch: text, status: "active", timestamp: Date())
            }

        case .fileChangePatchUpdated(_, let turnId, let itemId, let path, let patch):
            guard var thread = activeThread,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }
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
            self.activeThread = thread

        case .mcpToolCallProgress(_, let turnId, let itemId, let message):
            guard var thread = activeThread,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }
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
            self.activeThread = thread

        case .turnPlanUpdated(let threadId, let turnId, let plan, let explanation):
            guard var thread = activeThread, thread.id == threadId,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }
            thread.turns[idx].plan = plan
            thread.turns[idx].planExplanation = explanation
            self.activeThread = thread

        case .turnDiffUpdated(let threadId, let turnId, let diff):
            guard var thread = activeThread, thread.id == threadId,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }
            thread.turns[idx].diff = diff
            self.activeThread = thread

        case .tokenUsageUpdated(let threadId, let turnId, let usage):
            guard let turnId, var thread = activeThread, thread.id == threadId,
                  let idx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }
            thread.turns[idx].usage = usage
            self.activeThread = thread

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
        guard var thread = activeThread, thread.id == request.threadId else { return }
        thread.pendingApprovals.append(request)
        thread.status = .waiting
        self.activeThread = thread
    }

    public func dispatchRequest(_ request: CodexUserInputRequest) {
        self.pendingUserInput = request
    }

    public func resolveApproval(_ requestId: String) {
        pendingApprovals.removeAll(where: { $0.id == requestId })
        guard var thread = activeThread else { return }
        thread.pendingApprovals.removeAll(where: { $0.id == requestId })
        if thread.pendingApprovals.isEmpty, thread.status == .waiting {
            thread.status = .active
        }
        self.activeThread = thread
    }

    public func resolveUserInput() {
        self.pendingUserInput = nil
    }

    // MARK: - Delta Appender Helper

    private func appendDelta(_ delta: String, itemId: String, turnId: String, itemCreator: (String) -> CodexTimelineItem) {
        guard var thread = activeThread,
              let turnIdx = thread.turns.firstIndex(where: { $0.id == turnId }) else { return }

        let currentText = streamingBuffers[itemId, default: ""] + delta
        streamingBuffers[itemId] = currentText

        let updatedItem = itemCreator(currentText)
        if let itemIdx = thread.turns[turnIdx].items.firstIndex(where: { $0.id == itemId }) {
            thread.turns[turnIdx].items[itemIdx] = updatedItem
        } else {
            thread.turns[turnIdx].items.append(updatedItem)
        }

        self.activeThread = thread
    }

    // MARK: - Protocol Mapping Helper

    private func mapServerItem(_ item: CodexServerItem) -> CodexTimelineItem {
        let st = item.status ?? "completed"
        switch item.type {
        case "userMessage":
            let text = item.raw["text"]?.description ?? item.raw["content"]?.description ?? ""
            return .userMessage(id: item.id, text: text, timestamp: Date())

        case "assistantMessage", "agentMessage":
            let text = item.raw["text"]?.description ?? ""
            return .assistantMessage(id: item.id, text: text, timestamp: Date(), isStreaming: st == "active" || st == "inProgress")

        case "reasoning":
            let text = item.raw["text"]?.description ?? ""
            return .reasoning(id: item.id, text: text, timestamp: Date(), isStreaming: st == "active" || st == "inProgress")

        case "toolCall":
            let name = item.raw["name"]?.description ?? ""
            let args = item.raw["arguments"]?.description ?? ""
            return .toolCall(id: item.id, name: name, arguments: args, status: st, timestamp: Date())

        case "commandExecution":
            let cmd = item.raw["command"]?.description ?? ""
            let out = item.raw["output"]?.description ?? ""
            return .commandExecution(id: item.id, command: cmd, output: out, status: st, timestamp: Date())

        case "fileChange":
            let path = item.raw["path"]?.description ?? ""
            let patch = item.raw["patch"]?.description ?? ""
            return .fileChange(id: item.id, path: path, patch: patch, status: st, timestamp: Date())

        case "mcpToolCall":
            let server = item.raw["serverName"]?.description ?? item.raw["server"]?.description ?? ""
            let tool = item.raw["toolName"]?.description ?? item.raw["tool"]?.description ?? ""
            return .mcpToolCall(id: item.id, server: server, tool: tool, status: st, timestamp: Date(), progress: [])

        default:
            return .warning(id: item.id, text: "Notice: \(item.type) item completed with status \(st)", timestamp: Date())
        }
    }
}
