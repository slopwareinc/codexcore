import Foundation
import CodexCore

public struct CodexAgentItemUpdate: Equatable, Sendable {
    public var activityTitle: String
    public var activityDetail: String

    public init(activityTitle: String, activityDetail: String) {
        self.activityTitle = activityTitle
        self.activityDetail = activityDetail
    }
}

public struct CodexAgentStateMapper: Sendable {
    public private(set) var lifecycleEvents: [CodexAgentLifecycleEvent]
    public private(set) var sideChat: CodexSideChatState?
    public private(set) var subagents: [CodexSubagentState]

    private var subagentIDsByItemID: [String: String]

    public init(
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = []
    ) {
        self.lifecycleEvents = lifecycleEvents
        self.sideChat = sideChat
        self.subagents = subagents
        self.subagentIDsByItemID = [:]
    }

    public mutating func reset() {
        lifecycleEvents = []
        sideChat = nil
        subagents = []
        subagentIDsByItemID = [:]
    }

    public static func isSubagentType(_ type: String) -> Bool {
        normalizedKey(type).contains("subagent")
    }

    public func isSubagentItem(_ item: ThreadItem) -> Bool {
        if Self.isSubagentType(item.type) { return true }

        if item.raw.keys.contains(where: isSubagentKey) { return true }

        for key in ["source", "thread", "metadata", "agent", "agents", "subagent", "subAgent", "subagents", "subAgents"] {
            if containsSubagentSignal(in: item.raw[key]) { return true }
        }

        return false
    }

    @discardableResult
    public mutating func itemStarted(_ item: ThreadItem) -> CodexAgentItemUpdate? {
        let agents = extractSubagentDescriptors(from: item)
        guard !agents.isEmpty else {
            guard isSubagentItem(item) else { return nil }
            return CodexAgentItemUpdate(
                activityTitle: humanItemType(item.type),
                activityDetail: previewText(item.text ?? "Subagent started")
            )
        }

        let agentNames = agents.map(\.name)
        lifecycleEvents.append(CodexAgentLifecycleEvent(
            status: .spawning,
            title: agentNames.count == 1 ? "Spawning 1 agent" : "Spawning \(agentNames.count) agents",
            detail: lifecycleDetail(for: item, fallback: "Delegating focused work to side agents."),
            agentNames: agentNames
        ))

        for agent in agents {
            upsertSubagent(
                id: agent.id,
                name: agent.name,
                title: agent.title,
                prompt: agent.prompt,
                status: .running,
                itemID: item.id,
                result: nil,
                createdAt: Date(),
                completedAt: nil
            )
        }

        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagents started", activityDetail: agentNames.joined(separator: ", "))
    }

    @discardableResult
    public mutating func itemCompleted(_ item: ThreadItem) -> CodexAgentItemUpdate? {
        guard isSubagentItem(item) else { return nil }

        let agents = extractSubagentDescriptors(from: item)
        let status = subagentStatus(from: item)
        let completedAt = Date()
        let result = subagentResultText(from: item)

        if agents.isEmpty, let id = subagentIDsByItemID[item.id], let index = subagents.firstIndex(where: { $0.id == id }) {
            subagents[index].status = status
            subagents[index].completedAt = completedAt
            appendResult(result, toSubagentAt: index, createdAt: completedAt)
            lifecycleEvents.append(CodexAgentLifecycleEvent(
                status: lifecycleStatus(from: status),
                title: lifecycleTitle(status: status, count: 1),
                detail: lifecycleDetail(for: item, fallback: result ?? "Subagent finished."),
                agentNames: [subagents[index].name],
                createdAt: completedAt
            ))
            ensureSideChat()
            return CodexAgentItemUpdate(activityTitle: "Subagent \(status.rawValue)", activityDetail: subagents[index].name)
        }

        let names = agents.map(\.name)
        for agent in agents {
            upsertSubagent(
                id: agent.id,
                name: agent.name,
                title: agent.title,
                prompt: agent.prompt,
                status: status,
                itemID: item.id,
                result: result,
                createdAt: nil,
                completedAt: completedAt
            )
        }

        guard !names.isEmpty else {
            return CodexAgentItemUpdate(
                activityTitle: humanItemType(item.type),
                activityDetail: previewText(result ?? item.text ?? "Completed")
            )
        }

        lifecycleEvents.append(CodexAgentLifecycleEvent(
            status: lifecycleStatus(from: status),
            title: lifecycleTitle(status: status, count: names.count),
            detail: lifecycleDetail(for: item, fallback: result ?? "Subagent work finished."),
            agentNames: names,
            createdAt: completedAt
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagents \(status.rawValue)", activityDetail: names.joined(separator: ", "))
    }

    @discardableResult
    public mutating func messageDelta(_ delta: String, itemID: String) -> Bool {
        guard let subagentID = subagentIDsByItemID[itemID],
              let index = subagents.firstIndex(where: { $0.id == subagentID }) else {
            return false
        }

        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            subagents[index].messages[messageIndex].appendStreamingText(delta)
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .assistant, text: delta, isStreaming: true, parseContent: false))
        }
        return true
    }

    private struct SubagentDescriptor {
        var id: String
        var name: String
        var title: String
        var prompt: String
    }

    private func extractSubagentDescriptors(from item: ThreadItem) -> [SubagentDescriptor] {
        for key in ["agents", "subagents", "subAgents", "children", "threads"] {
            if let array = arrayValue(item.raw[key]) {
                let descriptors = array.enumerated().compactMap { offset, value -> SubagentDescriptor? in
                    guard let object = dictionaryValue(value) else { return nil }
                    return subagentDescriptor(from: object, item: item, index: offset)
                }
                if !descriptors.isEmpty { return descriptors }
            }
        }

        for key in ["agent", "subagent", "subAgent", "collabAgent", "guardianSubagent", "source", "thread", "metadata"] {
            if let object = dictionaryValue(item.raw[key]) {
                if let nested = nestedSubagentDescriptors(from: object, item: item), !nested.isEmpty {
                    return nested
                }
                if let descriptor = subagentDescriptor(from: object, item: item, index: 0) {
                    return [descriptor]
                }
            }
        }

        if let name = firstString(in: item.raw, keys: nameKeys) {
            return [SubagentDescriptor(
                id: firstString(in: item.raw, keys: idKeys) ?? "subagent-\(item.id)",
                name: sanitizedAgentName(name),
                title: firstString(in: item.raw, keys: titleKeys) ?? sanitizedAgentName(name),
                prompt: firstString(in: item.raw, keys: promptKeys) ?? item.text ?? "Subagent task"
            )]
        }

        if let text = item.text {
            let names = parseAgentNames(from: text)
            if !names.isEmpty {
                return names.enumerated().map { offset, name in
                    SubagentDescriptor(id: "subagent-\(item.id)-\(offset)", name: name, title: name, prompt: text)
                }
            }
        }

        if let id = subagentIDsByItemID[item.id], let existing = subagents.first(where: { $0.id == id }) {
            return [SubagentDescriptor(id: existing.id, name: existing.name, title: existing.title, prompt: existing.prompt)]
        }

        if Self.isSubagentType(item.type) {
            let name = firstString(in: item.raw, keys: nameKeys) ?? humanItemType(item.type)
            return [SubagentDescriptor(
                id: "subagent-\(item.id)",
                name: sanitizedAgentName(name),
                title: humanItemType(item.type),
                prompt: item.text ?? firstString(in: item.raw, keys: promptKeys) ?? "Subagent task"
            )]
        }

        return []
    }

    private func nestedSubagentDescriptors(from object: [String: CodexJSONValue], item: ThreadItem) -> [SubagentDescriptor]? {
        for key in ["agents", "subagents", "subAgents", "children", "threads"] {
            if let array = arrayValue(object[key]) {
                let descriptors = array.enumerated().compactMap { offset, value -> SubagentDescriptor? in
                    guard let nested = dictionaryValue(value) else { return nil }
                    return subagentDescriptor(from: nested, item: item, index: offset)
                }
                if !descriptors.isEmpty { return descriptors }
            }
        }

        for key in ["agent", "subagent", "subAgent", "thread", "metadata"] {
            if let nested = dictionaryValue(object[key]), let descriptor = subagentDescriptor(from: nested, item: item, index: 0) {
                return [descriptor]
            }
        }

        return nil
    }

    private func subagentDescriptor(from object: [String: CodexJSONValue], item: ThreadItem, index: Int) -> SubagentDescriptor? {
        let name = firstString(in: object, keys: nameKeys) ?? "Agent \(index + 1)"
        return SubagentDescriptor(
            id: firstString(in: object, keys: idKeys) ?? "subagent-\(item.id)-\(index)",
            name: sanitizedAgentName(name),
            title: firstString(in: object, keys: titleKeys) ?? sanitizedAgentName(name),
            prompt: firstString(in: object, keys: promptKeys) ?? item.text ?? "Subagent task"
        )
    }

    private mutating func upsertSubagent(
        id: String,
        name: String,
        title: String,
        prompt: String,
        status: CodexSubagentState.Status,
        itemID: String,
        result: String?,
        createdAt: Date?,
        completedAt: Date?
    ) {
        subagentIDsByItemID[itemID] = id
        if let index = subagents.firstIndex(where: { $0.id == id || $0.name == name }) {
            subagents[index].name = name
            subagents[index].title = title
            subagents[index].prompt = prompt
            subagents[index].status = status
            if let completedAt { subagents[index].completedAt = completedAt }
            appendResult(result, toSubagentAt: index, createdAt: completedAt ?? Date())
            return
        }

        var messages: [CodexChatMessage] = [CodexChatMessage(role: .user, text: prompt, createdAt: createdAt ?? Date())]
        if let result, !result.isEmpty {
            messages.append(CodexChatMessage(role: .assistant, text: result, createdAt: completedAt ?? Date()))
        }

        subagents.append(CodexSubagentState(
            id: id,
            name: name,
            title: title,
            prompt: prompt,
            status: status,
            messages: messages,
            createdAt: createdAt ?? Date(),
            completedAt: completedAt
        ))
    }

    private mutating func appendResult(_ result: String?, toSubagentAt index: Int, createdAt: Date) {
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .assistant }) {
            subagents[index].messages[messageIndex].setText(result, parseContent: true)
            subagents[index].messages[messageIndex].isStreaming = false
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .assistant, text: result, createdAt: createdAt))
        }
    }

    private mutating func ensureSideChat() {
        if sideChat == nil {
            sideChat = CodexSideChatState(title: "Side chat", createdAt: Date())
        }
    }

    private func subagentStatus(from item: ThreadItem) -> CodexSubagentState.Status {
        let rawStatus = firstString(in: item.raw, keys: ["status", "state", "phase"])?.lowercased() ?? item.phase?.lowercased()
        switch rawStatus {
        case "running", "active", "inprogress", "in_progress": return .running
        case "failed", "error", "cancelled", "canceled": return .failed
        case "closed", "archived": return .closed
        default: return .completed
        }
    }

    private func lifecycleStatus(from status: CodexSubagentState.Status) -> CodexAgentLifecycleEvent.Status {
        switch status {
        case .running: return .running
        case .completed: return .completed
        case .closed: return .closed
        case .failed: return .failed
        }
    }

    private func lifecycleTitle(status: CodexSubagentState.Status, count: Int) -> String {
        let noun = count == 1 ? "agent" : "agents"
        switch status {
        case .running: return "Running \(count) \(noun)"
        case .completed: return "Completed \(count) \(noun)"
        case .closed: return "Closed \(count) \(noun)"
        case .failed: return "Failed \(count) \(noun)"
        }
    }

    private func lifecycleDetail(for item: ThreadItem, fallback: String) -> String {
        firstString(in: item.raw, keys: ["summary", "detail", "message", "description", "statusText"])
            ?? item.text
            ?? fallback
    }

    private func subagentResultText(from item: ThreadItem) -> String? {
        firstString(in: item.raw, keys: ["result", "output", "summary", "text", "message", "response"])
            ?? item.text
    }

    private var idKeys: [String] { ["id", "agentId", "agent_id", "subagentId", "subagent_id", "threadId", "thread_id"] }
    private var nameKeys: [String] { ["name", "agentName", "agent_name", "subagentName", "subagent_name", "title", "label", "id"] }
    private var titleKeys: [String] { ["title", "role", "kind", "type", "label"] }
    private var promptKeys: [String] { ["prompt", "input", "instructions", "task", "description", "message"] }

    private func firstString(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key], let string = stringValue(value), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func stringValue(_ value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(stringValue).joined(separator: " ")
        case .dictionary, .null, nil: return nil
        }
    }

    private func dictionaryValue(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        if case .dictionary(let object)? = value { return object }
        return nil
    }

    private func arrayValue(_ value: CodexJSONValue?) -> [CodexJSONValue]? {
        if case .array(let array)? = value { return array }
        return nil
    }

    private func containsSubagentSignal(in value: CodexJSONValue?) -> Bool {
        switch value {
        case .string(let string):
            return Self.isSubagentType(string)
        case .array(let values):
            return values.contains { containsSubagentSignal(in: $0) }
        case .dictionary(let object):
            return object.contains { key, value in
                isSubagentKey(key) || containsSubagentSignal(in: value)
            }
        case .int, .double, .bool, .null, nil:
            return false
        }
    }

    private func isSubagentKey(_ key: String) -> Bool {
        let normalized = Self.normalizedKey(key)
        return normalized.contains("subagent")
            || normalized == "agentname"
            || normalized == "agentid"
            || normalized == "collabagent"
            || normalized == "guardiansubagent"
    }

    private func parseAgentNames(from text: String) -> [String] {
        let patterns = ["Created ", "Spawned ", "Started ", "Closed "]
        var names: [String] = []
        var seen: Set<String> = []
        for pattern in patterns {
            let components = text.components(separatedBy: pattern).dropFirst()
            for component in components {
                let candidate = component
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == ":" || $0 == "," || $0 == "." })
                    .first
                    .map(String.init)
                guard let candidate,
                      candidate.range(of: #"^[A-Z][A-Za-z0-9_-]{2,}$"#, options: .regularExpression) != nil,
                      !seen.contains(candidate) else {
                    continue
                }
                seen.insert(candidate)
                names.append(candidate)
            }
        }
        return names
    }

    private func sanitizedAgentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent" : trimmed
    }

    private func humanItemType(_ type: String) -> String {
        switch type {
        case "agentMessage", "assistantMessage": return "Codex message"
        case "commandExecution": return "Command"
        case "fileChange", "patch": return "File change"
        case "reasoning": return "Reasoning"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func previewText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedKey(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").lowercased()
    }
}
