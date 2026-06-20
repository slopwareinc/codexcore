import Foundation
import CodexCore

struct CodexSubagentDescriptor: Equatable, Sendable {
    var id: String
    var name: String
    var title: String
    var prompt: String
}

struct CodexSubagentMetadata: Equatable, Sendable {
    var nickname: String?
    var role: String?

    var displayName: String? {
        CodexAgentItemParser.agentDisplayName(nickname: nickname, role: role)
    }
}

struct CodexCollabAgentPayload {
    var tool: String
    var receiverThreadIDs: [String]
    var states: [String: [String: CodexJSONValue]]
    var prompt: String

    func status(completed: Bool) -> CodexSubagentState.Status {
        if tool == "closeAgent", completed { return .closed }
        let stateStatuses = states.values.compactMap {
            CodexAgentItemParser.firstString(in: $0, keys: ["status", "state"])?.lowercased()
        }
        for raw in stateStatuses {
            if let mapped = CodexAgentItemParser.customSubagentStatusMapping[raw], mapped == .failed { return .failed }
        }
        if stateStatuses.contains(where: { $0 == "failed" || $0 == "error" || $0 == "cancelled" || $0 == "canceled" }) {
            return .failed
        }
        if completed, tool == "wait", stateStatuses.contains(where: { $0 == "completed" }) {
            return .completed
        }
        if completed, tool == "spawnAgent" {
            return .running
        }
        return completed ? .completed : .running
    }
}

enum CodexAgentItemParser {
    static func isSubagentType(_ type: String) -> Bool {
        normalizedKey(type).contains("subagent")
    }

    static func isSubagentItem(_ item: ThreadItem) -> Bool {
        if isSubagentType(item.type) { return true }
        if isCollabAgentToolCall(item) { return true }

        if item.raw.keys.contains(where: isSubagentKey) { return true }

        for key in ["source", "thread", "metadata", "agent", "agents", "subagent", "subAgent", "subagents", "subAgents"] {
            if containsSubagentSignal(in: item.raw[key]) { return true }
        }

        return false
    }

    static func isCollabAgentToolCall(_ item: ThreadItem) -> Bool {
        normalizedKey(item.type) == "collabagenttoolcall"
            || (collabTool(from: item) != nil && (item.raw["receiverThreadIds"] != nil || item.raw["agentsStates"] != nil))
    }

    static func collabPayload(from item: ThreadItem) -> CodexCollabAgentPayload? {
        guard let tool = collabTool(from: item) else { return nil }
        let states = collabAgentStates(from: item)
        let receiverIDs = collabReceiverThreadIDs(from: item, states: states)
        return CodexCollabAgentPayload(
            tool: tool,
            receiverThreadIDs: receiverIDs,
            states: states,
            prompt: firstString(in: item.raw, keys: ["prompt"]) ?? "Subagent task"
        )
    }

    static func subagentDescriptors(
        from item: ThreadItem,
        existing: CodexSubagentDescriptor? = nil
    ) -> [CodexSubagentDescriptor] {
        for key in ["agents", "subagents", "subAgents", "children", "threads"] {
            if let array = arrayValue(item.raw[key]) {
                let descriptors = array.enumerated().compactMap { offset, value -> CodexSubagentDescriptor? in
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
            return [CodexSubagentDescriptor(
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
                    CodexSubagentDescriptor(id: "subagent-\(item.id)-\(offset)", name: name, title: name, prompt: text)
                }
            }
        }

        if let existing {
            return [existing]
        }

        if isSubagentType(item.type) {
            let name = firstString(in: item.raw, keys: nameKeys) ?? humanItemType(item.type)
            return [CodexSubagentDescriptor(
                id: "subagent-\(item.id)",
                name: sanitizedAgentName(name),
                title: humanItemType(item.type),
                prompt: item.text ?? firstString(in: item.raw, keys: promptKeys) ?? "Subagent task"
            )]
        }

        return []
    }

    nonisolated(unsafe) public static var customSubagentStatusMapping: [String: CodexSubagentState.Status] = [:]

    static func subagentStatus(from item: ThreadItem) -> CodexSubagentState.Status {
        let rawStatus = firstString(in: item.raw, keys: ["status", "state", "phase"])?.lowercased() ?? item.phase?.lowercased()
        if let raw = rawStatus, let mapped = customSubagentStatusMapping[raw] { return mapped }
        switch rawStatus {
        case "running", "active", "inprogress", "in_progress": return .running
        case "failed", "error", "cancelled", "canceled": return .failed
        case "closed", "archived": return .closed
        default: return .completed
        }
    }

    static func lifecycleDetail(for item: ThreadItem, fallback: String) -> String {
        firstString(in: item.raw, keys: ["summary", "detail", "message", "description", "statusText"])
            ?? item.text
            ?? fallback
    }

    static func subagentResultText(from item: ThreadItem) -> String? {
        firstString(in: item.raw, keys: ["result", "output", "summary", "text", "message", "response"])
            ?? item.text
    }

    static func userMessageText(from item: ThreadItem) -> String? {
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        guard let content = arrayValue(item.raw["content"]) else { return nil }
        let parts = content.compactMap { value -> String? in
            if let object = dictionaryValue(value) {
                return firstString(in: object, keys: ["text", "content", "message"])
            }
            return stringValue(value)
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func childActivityText(from item: ThreadItem, started: Bool) -> String? {
        switch item.type {
        case "webSearch":
            let query = firstString(in: item.raw, keys: ["query"]) ?? "Search"
            return started ? "Web search: \(query)" : "Web search completed: \(query)"
        case "reasoning":
            return item.text ?? firstString(in: item.raw, keys: ["summary", "content", "text"])
        case "fileChange", "patch":
            return started ? "File change started" : "File change completed"
        default:
            if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            return started ? "Started \(humanItemType(item.type))" : nil
        }
    }

    static func parseMentionedAgentNames(from text: String) -> [String] {
        let pattern = #"(?<![`A-Za-z0-9_-])([A-Z][A-Za-z0-9_-]{2,})(?=\s+(has|is|ran|finished|completed|returned)\b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var names: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            guard !seen.contains(name), !["Both", "Used", "Exact", "Command"].contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    static func metadataDisplayName(in state: [String: CodexJSONValue]?) -> String? {
        guard let state else { return nil }
        return agentDisplayName(
            nickname: firstString(in: state, keys: ["agentNickname", "agent_nickname", "nickname", "name", "title"]),
            role: firstString(in: state, keys: ["agentRole", "agent_role", "role", "kind"])
        )
    }

    static func agentDisplayName(nickname: String?, role: String?) -> String? {
        let nickname = cleanMetadataValue(nickname)
        let role = cleanMetadataValue(role)
        switch (nickname, role) {
        case let (nickname?, role?): return "\(nickname) [\(role)]"
        case let (nickname?, nil): return nickname
        case let (nil, role?): return "[\(role)]"
        case (nil, nil): return nil
        }
    }

    static func cleanMetadataValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func firstString(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key], let string = stringValue(value), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    static func stringValue(_ value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(stringValue).joined(separator: " ")
        case .dictionary, .null, nil: return nil
        }
    }

    static func humanCollabToolTitle(_ tool: String, completed: Bool = true) -> String {
        switch tool {
        case "spawnAgent": return completed ? "Subagents started" : "Subagent spawning"
        case "wait": return completed ? "Subagents completed" : "Waiting on subagents"
        case "closeAgent": return completed ? "Subagents closed" : "Closing subagents"
        default: return "Subagent update"
        }
    }

    static func collabLifecycleTitle(
        tool: String,
        completed: Bool,
        status: CodexSubagentState.Status,
        names: [String]
    ) -> String {
        let label = names.count == 1 ? names[0] : "\(names.count) agents"
        switch tool {
        case "spawnAgent": return completed ? "Spawned \(label)" : "Spawning \(label)"
        case "sendInput": return completed ? "Sent input to \(label)" : "Sending input to \(label)"
        case "resumeAgent": return completed ? "Resumed \(label)" : "Resuming \(label)"
        case "wait": return completed ? "Finished waiting" : "Waiting for \(label)"
        case "closeAgent": return completed ? "Closed \(label)" : "Closing \(label)"
        default: return lifecycleTitle(status: status, count: names.count)
        }
    }

    static func lifecycleTitle(status: CodexSubagentState.Status, count: Int) -> String {
        let noun = count == 1 ? "agent" : "agents"
        switch status {
        case .running: return "Running \(count) \(noun)"
        case .completed: return "Completed \(count) \(noun)"
        case .closed: return "Closed \(count) \(noun)"
        case .failed: return "Failed \(count) \(noun)"
        }
    }

    static func titleForCollabPrompt(_ prompt: String) -> String {
        guard !isPlaceholderPrompt(prompt) else { return "Delegated agent" }
        let normalized = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 56 else { return normalized }
        return String(normalized.prefix(56)) + "…"
    }

    static func isPlaceholderPrompt(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt == "Subagent task"
    }

    static func humanItemType(_ type: String) -> String {
        CodexNotificationPresentation.itemTypeTitle(type)
    }

    static func previewText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nestedSubagentDescriptors(
        from object: [String: CodexJSONValue],
        item: ThreadItem
    ) -> [CodexSubagentDescriptor]? {
        for key in ["agents", "subagents", "subAgents", "children", "threads"] {
            if let array = arrayValue(object[key]) {
                let descriptors = array.enumerated().compactMap { offset, value -> CodexSubagentDescriptor? in
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

    private static func subagentDescriptor(
        from object: [String: CodexJSONValue],
        item: ThreadItem,
        index: Int
    ) -> CodexSubagentDescriptor? {
        let name = firstString(in: object, keys: nameKeys) ?? "Agent \(index + 1)"
        return CodexSubagentDescriptor(
            id: firstString(in: object, keys: idKeys) ?? "subagent-\(item.id)-\(index)",
            name: sanitizedAgentName(name),
            title: firstString(in: object, keys: titleKeys) ?? sanitizedAgentName(name),
            prompt: firstString(in: object, keys: promptKeys) ?? item.text ?? "Subagent task"
        )
    }

    private static func collabTool(from item: ThreadItem) -> String? {
        firstString(in: item.raw, keys: ["tool"])
    }

    private static func collabReceiverThreadIDs(
        from item: ThreadItem,
        states: [String: [String: CodexJSONValue]]
    ) -> [String] {
        let receiverIDs = arrayValue(item.raw["receiverThreadIds"])?.compactMap(stringValue) ?? []
        if !receiverIDs.isEmpty { return receiverIDs }
        return states.keys.sorted()
    }

    private static func collabAgentStates(from item: ThreadItem) -> [String: [String: CodexJSONValue]] {
        guard let object = dictionaryValue(item.raw["agentsStates"]) else { return [:] }
        var states: [String: [String: CodexJSONValue]] = [:]
        for (key, value) in object {
            if let state = dictionaryValue(value) {
                states[key] = state
            }
        }
        return states
    }

    private static func dictionaryValue(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        if case .dictionary(let object)? = value { return object }
        return nil
    }

    private static func arrayValue(_ value: CodexJSONValue?) -> [CodexJSONValue]? {
        if case .array(let array)? = value { return array }
        return nil
    }

    private static func containsSubagentSignal(in value: CodexJSONValue?) -> Bool {
        switch value {
        case .string(let string):
            return isSubagentType(string)
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

    private static func isSubagentKey(_ key: String) -> Bool {
        let normalized = normalizedKey(key)
        return normalized.contains("subagent")
            || normalized == "agentname"
            || normalized == "agentid"
            || normalized == "collabagent"
            || normalized == "guardiansubagent"
    }

    private static func parseAgentNames(from text: String) -> [String] {
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

    private static func sanitizedAgentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent" : trimmed
    }

    private static func normalizedKey(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static var idKeys: [String] { ["id", "agentId", "agent_id", "subagentId", "subagent_id", "threadId", "thread_id"] }
    private static var nameKeys: [String] { ["name", "agentName", "agent_name", "subagentName", "subagent_name", "title", "label", "id"] }
    private static var titleKeys: [String] { ["title", "role", "kind", "type", "label"] }
    private static var promptKeys: [String] { ["prompt", "input", "instructions", "task", "description", "message"] }
}
