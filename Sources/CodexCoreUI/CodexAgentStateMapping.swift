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

    public init(
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = []
    ) {
        self.lifecycleEvents = lifecycleEvents; self.sideChat = sideChat; self.subagents = subagents
    }

    public mutating func reset() { lifecycleEvents = []; sideChat = nil; subagents = [] }
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

    @discardableResult public mutating func applyChildThreadReferences(_: [CodexChildThreadReference]) -> Bool { false }
    @discardableResult public mutating func applyHydratedChildThread(_: CodexHydratedThread, reference _: CodexChildThreadReference? = nil) -> Bool { false }
    @discardableResult public mutating func subagentTurnStarted(threadID _: String) -> CodexAgentItemUpdate? { nil }
    @discardableResult public mutating func subagentItemStarted(threadID _: String, item _: ThreadItem) -> CodexAgentItemUpdate? { nil }
    @discardableResult public mutating func subagentItemCompleted(threadID _: String, item _: ThreadItem) -> CodexAgentItemUpdate? { nil }
    @discardableResult public mutating func subagentTurnCompleted(threadID _: String, error _: String? = nil) -> CodexAgentItemUpdate? { nil }

    private mutating func collabUpdate(_ item: ThreadItem, completed: Bool) -> CodexAgentItemUpdate? {
        guard item.type == "collabAgentToolCall" else { return nil }
        let title = completed ? "Subagent updated" : "Subagent working"
        return CodexAgentItemUpdate(activityTitle: title, activityDetail: item.id)
    }
}
