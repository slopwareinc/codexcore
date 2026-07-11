import Foundation
import CodexCore

public struct CodexThreadHistorySnapshot: Sendable {
    public var agentStateMapper: CodexAgentStateMapper

    public init(agentStateMapper: CodexAgentStateMapper = CodexAgentStateMapper()) {
        self.agentStateMapper = agentStateMapper
    }

    public init(raw response: CodexJSONValue) {
        self.init(parentRaw: response, parent: CodexThreadHistoryHydrator.decode(raw: response))
    }

    public init(parentRaw _: CodexJSONValue, parent: CodexHydratedThread) {
        var mapper = CodexAgentStateMapper()
        _ = mapper.applyChildThreadReferences(parent.snapshot.childThreads)

        self.init(agentStateMapper: mapper)
    }

    public init(hydration: CodexThreadHistoryHydrationResult) {
        self.init(parentRaw: .dictionary([:]), parent: hydration.parent)
        for child in hydration.childThreads {
            _ = applyHydratedChildThread(child)
        }
    }

    public var lifecycleEvents: [CodexAgentLifecycleEvent] {
        agentStateMapper.lifecycleEvents
    }

    public var sideChat: CodexSideChatState? {
        agentStateMapper.sideChat
    }

    public var subagents: [CodexSubagentState] {
        agentStateMapper.subagents
    }

    public var subagentThreadIDs: [String] {
        agentStateMapper.subagents.map(\.id)
    }

    @discardableResult
    public mutating func applyChildThread(raw response: CodexJSONValue, threadID explicitThreadID: String? = nil) -> Bool {
        guard let threadID = explicitThreadID ?? Self.threadID(from: response) else { return false }
        var didApply = false

        if let thread = Self.threadObject(from: response) {
            let name = Self.string(from: thread["agentNickname"]) ?? Self.string(from: thread["name"])
            let role = Self.string(from: thread["agentRole"])
            didApply = agentStateMapper.updateSubagentMetadata(id: threadID, name: name, role: role) || didApply
        }

        for turn in Self.turnObjects(from: response) {
            var sawItem = false
            guard case .array(let items)? = turn["items"] else { continue }
            for itemValue in items {
                guard let item = try? itemValue.decode(ThreadItem.self) else { continue }
                sawItem = true
                didApply = agentStateMapper.subagentItemCompleted(threadID: threadID, item: item) != nil || didApply
            }

            guard sawItem, Self.isFinishedTurnStatus(Self.string(from: turn["status"])) else { continue }
            didApply = agentStateMapper.subagentTurnCompleted(threadID: threadID, error: Self.turnErrorMessage(from: turn)) != nil || didApply
        }

        return didApply
    }

    @discardableResult
    public mutating func applyHydratedChildThread(_ child: CodexHydratedThread) -> Bool {
        let reference = agentStateMapper.subagents.first(where: { $0.id == child.snapshot.id }).map {
            CodexChildThreadReference(
                threadID: $0.id,
                name: $0.name,
                title: $0.title,
                prompt: $0.prompt,
                status: $0.status.rawValue
            )
        }
        return agentStateMapper.applyHydratedChildThread(child, reference: reference)
    }

    private static func turnObjects(from response: CodexJSONValue) -> [[String: CodexJSONValue]] {
        if let thread = threadObject(from: response),
           case .array(let turns)? = thread["turns"] {
            return dictionaries(from: turns)
        }

        if case .dictionary(let object) = response,
           case .array(let turns)? = object["turns"] {
            return dictionaries(from: turns)
        }
        return []
    }

    private static func dictionaries(from values: [CodexJSONValue]) -> [[String: CodexJSONValue]] {
        values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            return object
        }
    }

    private static func threadObject(from response: CodexJSONValue) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object) = response else { return nil }
        if case .dictionary(let thread)? = object["thread"] { return thread }
        if object["turns"] != nil, object["id"] != nil { return object }
        return nil
    }

    private static func threadID(from response: CodexJSONValue) -> String? {
        threadObject(from: response).flatMap { string(from: $0["id"]) }
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: return nil
        }
    }

    private static func date(from value: CodexJSONValue?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case .int(let int): seconds = TimeInterval(int)
        case .double(let double): seconds = double
        case .string(let string): seconds = TimeInterval(string)
        case .bool, .array, .dictionary, .null, nil: seconds = nil
        }
        guard var seconds else { return nil }
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isFinishedTurnStatus(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        switch status {
        case "completed", "failed", "interrupted", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private static func turnErrorMessage(from turn: [String: CodexJSONValue]) -> String? {
        guard let error = turn["error"] else { return nil }
        if case .null = error { return nil }
        return string(from: error)
    }
}
