import CodexCore
import Foundation

public struct CodexAgentItemUpdate: Equatable, Sendable {
    public var activityTitle: String
    public var activityDetail: String
    public init(activityTitle: String, activityDetail: String) {
        self.activityTitle = activityTitle; self.activityDetail = activityDetail
    }
}

/// V2-only agent panel state. Child transcripts are turn-native.
public struct CodexAgentStateMapper: Sendable {
    public private(set) var lifecycleEvents: [CodexAgentLifecycleEvent]
    public private(set) var sideChat: CodexSideChatState?
    public private(set) var subagents: [CodexSubagentState]
    private var childReducers: [String: CodexTranscriptReducerV2]

    public init(
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = [],
        childReducers: [String: CodexTranscriptReducerV2] = [:]
    ) {
        self.lifecycleEvents = lifecycleEvents; self.sideChat = sideChat; self.subagents = subagents; self.childReducers = childReducers
    }

    public mutating func reset() { lifecycleEvents = []; sideChat = nil; subagents = []; childReducers = [:] }
    public func isSubagentItem(_ item: ThreadItem) -> Bool { item.type == "collabAgentToolCall" }
    public mutating func itemStarted(_ item: ThreadItem) -> CodexAgentItemUpdate? { collabUpdate(item, completed: false) }
    public mutating func itemCompleted(_ item: ThreadItem) -> CodexAgentItemUpdate? { collabUpdate(item, completed: true) }
    public mutating func messageDelta(_: String, itemID _: String) -> Bool { false }
    public mutating func assistantMessageCompleted(_: String) -> Bool { false }
    public func hasSubagentThread(id: String) -> Bool { subagents.contains { $0.id == id } }

    @discardableResult
    public mutating func updateSubagentMetadata(id: String, name: String?, role _: String? = nil) -> Bool {
        guard let index = subagents.firstIndex(where: { $0.id == id }), let name, !name.isEmpty else { return false }
        subagents[index].name = name; return true
    }

    @discardableResult public mutating func applyChildThreadReferences(_ references: [CodexChildThreadReference]) -> Bool {
        var changed = false
        for reference in references {
            changed = ensureSubagent(id: reference.threadID, name: reference.name ?? shortAgentName(reference.threadID), title: reference.title ?? "Subagent", prompt: reference.prompt ?? "Subagent task", status: normalizedStatus(reference.status)) || changed
        }
        return changed
    }

    @discardableResult public mutating func applyHydratedChildThread(_ child: CodexHydratedThread, reference: CodexChildThreadReference? = nil) -> Bool {
        let reference = reference ?? CodexChildThreadReference(threadID: child.snapshot.id, name: child.agentName, title: child.agentRole)
        var changed = ensureSubagent(id: child.snapshot.id, name: reference.name ?? child.agentName ?? shortAgentName(child.snapshot.id), title: reference.title ?? child.agentRole ?? "Subagent", prompt: reference.prompt ?? "Subagent task", status: .completed)
        for turn in child.snapshot.turns {
            for item in turn.items {
                changed = applyTimelineItem(item, threadID: child.snapshot.id, completed: true) || changed
            }
        }
        if let index = subagents.firstIndex(where: { $0.id == child.snapshot.id }) { subagents[index].status = .completed; subagents[index].completedAt = Date() }
        return changed
    }

    @discardableResult public mutating func subagentTurnStarted(threadID: String) -> CodexAgentItemUpdate? {
        guard let index = subagents.firstIndex(where: { $0.id == threadID }) else { return nil }
        subagents[index].status = .running
        return CodexAgentItemUpdate(activityTitle: "Subagent working", activityDetail: threadID)
    }

    @discardableResult public mutating func subagentItemStarted(threadID: String, item: ThreadItem) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        _ = applyChildItem(item, threadID: threadID, completed: false)
        if let index = subagents.firstIndex(where: { $0.id == threadID }), subagents[index].status == .completed { subagents[index].status = .running; subagents[index].completedAt = nil }
        return CodexAgentItemUpdate(activityTitle: "Subagent working", activityDetail: threadID)
    }

    @discardableResult public mutating func subagentItemCompleted(threadID: String, item: ThreadItem) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        _ = applyChildItem(item, threadID: threadID, completed: true)
        return CodexAgentItemUpdate(activityTitle: "Subagent updated", activityDetail: threadID)
    }

    @discardableResult public mutating func subagentTurnCompleted(threadID: String, error: String? = nil) -> CodexAgentItemUpdate? {
        guard let index = subagents.firstIndex(where: { $0.id == threadID }) else { return nil }
        subagents[index].status = error == nil ? .completed : .failed
        subagents[index].completedAt = Date()
        if let reducer = childReducers[threadID], let turn = reducer.transcript.turns.last {
            if let turnIndex = reducer.transcript.turns.firstIndex(where: { $0.id == turn.id }) {
                // The child reducer owns turn status; leave its content intact and expose it through the state.
                _ = turnIndex
            }
        }
        syncTranscript(for: threadID)
        return CodexAgentItemUpdate(activityTitle: error == nil ? "Subagent completed" : "Subagent failed", activityDetail: error ?? threadID)
    }

    private mutating func collabUpdate(_ item: ThreadItem, completed: Bool) -> CodexAgentItemUpdate? {
        guard item.type == "collabAgentToolCall" else { return nil }
        guard let payload = CodexAgentItemParser.collabPayload(from: item) else { return nil }
        let ids = payload.receiverThreadIDs
        for id in ids {
            let name = CodexAgentItemParser.metadataDisplayName(in: payload.states[id]) ?? shortAgentName(id)
            let status: CodexSubagentState.Status = payload.tool == "closeAgent" && completed ? .closed : (completed && payload.tool == "wait" ? .completed : .running)
            _ = ensureSubagent(id: id, name: name, title: name, prompt: payload.prompt, status: status)
        }
        let title = CodexAgentItemParser.collabLifecycleTitle(tool: payload.tool, completed: completed, status: completed ? .completed : .running, names: ids.map(shortAgentName))
        lifecycleEvents.append(.init(status: completed ? (payload.tool == "closeAgent" ? .closed : .completed) : .running, title: title, detail: item.id, agentNames: ids.map(shortAgentName)))
        return CodexAgentItemUpdate(activityTitle: title, activityDetail: item.id)
    }

    private mutating func ensureSubagent(id: String, name: String, title: String, prompt: String, status: CodexSubagentState.Status) -> Bool {
        if let index = subagents.firstIndex(where: { $0.id == id }) {
            subagents[index].name = name; subagents[index].title = title; subagents[index].prompt = prompt; subagents[index].status = status
            if status != .running { subagents[index].completedAt = Date() }
            return true
        }
        subagents.append(.init(id: id, name: name, title: title, prompt: prompt, status: status))
        childReducers[id] = CodexTranscriptReducerV2(threadID: id)
        return true
    }

    private mutating func applyChildItem(_ item: ThreadItem, threadID: String, completed: Bool) -> Bool {
        guard var reducer = childReducers[threadID] else { return false }
        let explicitTurnID: String?
        if case .string(let value)? = item.raw["turnId"] { explicitTurnID = value } else { explicitTurnID = nil }
        let turnID = explicitTurnID ?? ("live-" + threadID)
        var raw = item.raw; raw["threadId"] = .string(threadID); raw["turnId"] = .string(turnID)
        reducer.apply(method: completed ? "item/completed" : "item/started", params: .dictionary(["threadId": .string(threadID), "turnId": .string(turnID), "item": .dictionary(raw)]))
        childReducers[threadID] = reducer; syncTranscript(for: threadID); return true
    }

    private mutating func applyTimelineItem(_ item: CodexTimelineItem, threadID: String, completed: Bool) -> Bool {
        guard let index = subagents.firstIndex(where: { $0.id == threadID }) else { return false }
        switch item {
        case .assistantMessage(_, let text, _, _): subagents[index].transcript.turns.append(.init(id: item.id, finalAnswer: .init(id: item.id, text: text, isStreaming: false), status: .done(durationMs: nil)))
        case .userMessage(_, let text, _): subagents[index].transcript.turns.append(.init(id: item.id, userMessage: .init(id: item.id, text: text), status: .done(durationMs: nil)))
        default: break
        }
        return completed
    }

    private mutating func syncTranscript(for id: String) {
        guard let index = subagents.firstIndex(where: { $0.id == id }), let reducer = childReducers[id] else { return }
        subagents[index].transcript = reducer.transcript
    }

    private func normalizedStatus(_ raw: String?) -> CodexSubagentState.Status { CodexSubagentState.Status.normalized(raw) ?? .running }
    private func shortAgentName(_ id: String) -> String { "agent-\(id.split(separator: "-").first.map(String.init) ?? id)" }
}
