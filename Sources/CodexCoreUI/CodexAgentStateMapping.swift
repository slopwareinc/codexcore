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
    private var subagentMetadataByID: [String: SubagentMetadata]
    private var completedCollabToolCallIDs: Set<String>

    public init(
        lifecycleEvents: [CodexAgentLifecycleEvent] = [],
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = []
    ) {
        self.lifecycleEvents = lifecycleEvents
        self.sideChat = sideChat
        self.subagents = subagents
        self.subagentIDsByItemID = [:]
        self.subagentMetadataByID = [:]
        self.completedCollabToolCallIDs = []
    }

    public mutating func reset() {
        lifecycleEvents = []
        sideChat = nil
        subagents = []
        subagentIDsByItemID = [:]
        subagentMetadataByID = [:]
        completedCollabToolCallIDs = []
    }

    @discardableResult
    public mutating func updateSubagentMetadata(id: String, name: String?, role: String? = nil) -> Bool {
        let metadata = SubagentMetadata(nickname: cleanMetadataValue(name), role: cleanMetadataValue(role))
        guard metadata.displayName != nil else { return false }

        subagentMetadataByID[id] = metadata
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return false }

        var changed = false
        if let displayName = metadata.displayName, subagents[index].name != displayName {
            let oldName = subagents[index].name
            subagents[index].name = displayName
            replaceAgentName(oldName, with: displayName)
            changed = true
        }
        return changed
    }

    public static func isSubagentType(_ type: String) -> Bool {
        normalizedKey(type).contains("subagent")
    }

    public func isSubagentItem(_ item: ThreadItem) -> Bool {
        if Self.isSubagentType(item.type) { return true }
        if isCollabAgentToolCall(item) { return true }

        if item.raw.keys.contains(where: isSubagentKey) { return true }

        for key in ["source", "thread", "metadata", "agent", "agents", "subagent", "subAgent", "subagents", "subAgents"] {
            if containsSubagentSignal(in: item.raw[key]) { return true }
        }

        return false
    }

    @discardableResult
    public mutating func itemStarted(_ item: ThreadItem) -> CodexAgentItemUpdate? {
        guard isSubagentItem(item) else { return nil }
        if isCollabAgentToolCall(item) {
            guard !completedCollabToolCallIDs.contains(item.id) else { return nil }
            return applyCollabAgentToolCall(item, completed: false)
        }

        let agents = extractSubagentDescriptors(from: item)
        guard !agents.isEmpty else {
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
        if isCollabAgentToolCall(item) {
            completedCollabToolCallIDs.insert(item.id)
            return applyCollabAgentToolCall(item, completed: true)
        }

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
    public mutating func assistantMessageCompleted(_ text: String) -> Bool {
        let names = parseMentionedAgentNames(from: text)
        guard !names.isEmpty else { return false }

        var changed = false
        let unnamedIndices = subagents.indices.filter { subagents[$0].name.hasPrefix("Agent ") }
        for (name, index) in zip(names, unnamedIndices) {
            let oldName = subagents[index].name
            subagents[index].name = name
            if subagents[index].title.hasPrefix("Agent ") || subagents[index].title == "Delegated agent" {
                subagents[index].title = name
            }
            replaceAgentName(oldName, with: name)
            changed = true
        }
        return changed
    }

    @discardableResult
    public mutating func messageDelta(_ delta: String, itemID: String) -> Bool {
        guard let subagentID = subagentIDsByItemID[itemID] else {
            return false
        }

        return appendSubagentAssistantDelta(delta, threadID: subagentID, itemID: itemID)
    }

    public func hasSubagentThread(id: String) -> Bool {
        subagents.contains { $0.id == id } || subagentMetadataByID[id] != nil
    }

    @discardableResult
    public mutating func subagentTurnStarted(threadID: String) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        subagents[index].status = .running
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent turn started", activityDetail: subagents[index].name)
    }

    @discardableResult
    public mutating func subagentItemStarted(threadID: String, item: ThreadItem) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        subagents[index].status = .running
        subagentIDsByItemID[item.id] = threadID

        switch item.type {
        case "commandExecution":
            startSubagentCommand(item, at: index)
        case "fileChange", "patch":
            startSubagentFileChange(item, at: index)
        case "plan":
            startSubagentPlan(item, at: index)
        case "mcpToolCall", "toolCall":
            startSubagentToolCall(item, at: index)
        case "userMessage":
            if let text = userMessageText(from: item) {
                upsertPromptMessage(text, toSubagentAt: index, replacing: subagents[index].prompt)
            }
        case "agentMessage", "assistantMessage":
            break
        default:
            if let text = childActivityText(from: item, started: true) {
                appendSubagentSystemMessage(text, itemID: item.id, at: index)
            }
        }

        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent item started", activityDetail: "\(subagents[index].name): \(humanItemType(item.type))")
    }

    @discardableResult
    public mutating func subagentItemCompleted(threadID: String, item: ThreadItem) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[item.id] = threadID

        switch item.type {
        case "agentMessage", "assistantMessage":
            if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completeSubagentAssistantMessage(text, threadID: threadID, itemID: item.id, createdAt: Date())
            }
        case "userMessage":
            if let text = userMessageText(from: item) {
                upsertPromptMessage(text, toSubagentAt: index, replacing: subagents[index].prompt)
            }
        case "commandExecution":
            finishSubagentCommand(item, at: index)
        case "fileChange", "patch":
            finishSubagentFileChange(item, at: index)
        case "plan":
            finishSubagentPlan(item, at: index)
        case "mcpToolCall", "toolCall":
            finishSubagentToolCall(item, at: index)
        default:
            if let text = childActivityText(from: item, started: false) {
                appendSubagentSystemMessage(text, itemID: item.id, at: index)
            }
        }

        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent item completed", activityDetail: "\(subagents[index].name): \(humanItemType(item.type))")
    }

    @discardableResult
    public mutating func subagentMessageDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        return appendSubagentAssistantDelta(delta, threadID: threadID, itemID: itemID)
    }

    @discardableResult
    public mutating func subagentCommandOutputDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        appendSubagentCommandOutput(delta, itemID: itemID, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentFileChangeOutputDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        appendSubagentFileChangeOutput(delta, itemID: itemID, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentFileChangePatchUpdated(
        threadID: String,
        itemID: String,
        raw: [String: CodexJSONValue]
    ) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        let change = fileChange(from: raw, itemID: itemID, fallbackStatus: "active")
        upsertSubagentFileChange(change, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentPlanDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        appendSubagentPlanDelta(delta, itemID: itemID, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentPlanUpdated(
        threadID: String,
        itemID: String,
        raw: [String: CodexJSONValue],
        isStreaming: Bool
    ) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        guard let plan = CodexChatMessage.planUpdate(itemID: itemID, raw: raw, isStreaming: isStreaming) else {
            return false
        }
        upsertSubagentPlan(plan, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentToolCallProgress(_ progress: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        appendSubagentToolCallProgress(progress, itemID: itemID, at: index)
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentNotice(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        threadID: String,
        itemID: String,
        isStreaming: Bool = false
    ) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID),
              let notice = CodexChatMessage.notice(itemID: itemID, method: method, raw: params, isStreaming: isStreaming) else {
            return nil
        }
        let index = ensureSubagentThread(id: threadID)
        upsertSubagentNotice(notice, at: index)
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: notice.title, activityDetail: notice.detail)
    }

    @discardableResult
    public mutating func subagentTurnCompleted(threadID: String, error: String? = nil) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        let completedAt = Date()
        let cleanError = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: CodexSubagentState.Status = cleanError?.isEmpty == false ? .failed : .completed

        if subagents[index].status != .closed {
            subagents[index].status = status
        }
        subagents[index].completedAt = completedAt
        finishSubagentStreamingMessages(at: index)

        let lifecycleStatus = lifecycleStatus(from: subagents[index].status)
        let detail = cleanError?.isEmpty == false ? cleanError! : "Subagent turn finished."
        lifecycleEvents.append(CodexAgentLifecycleEvent(
            status: lifecycleStatus,
            title: lifecycleTitle(status: subagents[index].status, count: 1),
            detail: detail,
            agentNames: [subagents[index].name],
            createdAt: completedAt
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent \(subagents[index].status.rawValue)", activityDetail: subagents[index].name)
    }

    private struct SubagentDescriptor {
        var id: String
        var name: String
        var title: String
        var prompt: String
    }

    private struct SubagentMetadata: Equatable, Sendable {
        var nickname: String?
        var role: String?

        var displayName: String? {
            CodexAgentStateMapper.agentDisplayName(nickname: nickname, role: role)
        }
    }

    private mutating func applyCollabAgentToolCall(_ item: ThreadItem, completed: Bool) -> CodexAgentItemUpdate? {
        let tool = collabTool(from: item) ?? "agent"
        let states = collabAgentStates(from: item)
        let receiverIDs = collabReceiverThreadIDs(from: item, states: states)
        let prompt = firstString(in: item.raw, keys: ["prompt"]) ?? "Subagent task"

        if tool == "spawnAgent", !completed, receiverIDs.isEmpty {
            lifecycleEvents.append(CodexAgentLifecycleEvent(
                status: .spawning,
                title: "Spawning agent",
                detail: prompt == "Subagent task" ? "Starting delegated agent." : prompt
            ))
            ensureSideChat()
            return CodexAgentItemUpdate(activityTitle: "Subagent spawning", activityDetail: previewText(prompt))
        }

        guard !receiverIDs.isEmpty else {
            ensureSideChat()
            return CodexAgentItemUpdate(activityTitle: humanCollabToolTitle(tool, completed: completed), activityDetail: previewText(prompt))
        }

        let status = collabStatus(tool: tool, completed: completed, states: states)
        let now = Date()
        var names: [String] = []
        var resultText: String?
        for receiverID in receiverIDs {
            let state = states[receiverID]
            let result = firstString(in: state ?? [:], keys: ["message", "summary", "result"])
            if resultText == nil { resultText = result }
            let name = nameForSubagent(id: receiverID, state: state)
            names.append(name)
            upsertSubagent(
                id: receiverID,
                name: name,
                title: titleForCollabPrompt(prompt),
                prompt: prompt,
                status: status,
                itemID: item.id,
                result: result,
                createdAt: status == .running ? now : nil,
                completedAt: status == .running ? nil : now
            )
        }

        let lifecycleStatus = lifecycleStatus(from: status)
        lifecycleEvents.append(CodexAgentLifecycleEvent(
            status: lifecycleStatus,
            title: collabLifecycleTitle(tool: tool, completed: completed, status: status, names: names),
            detail: resultText ?? (prompt == "Subagent task" ? humanCollabToolTitle(tool, completed: completed) : prompt),
            agentNames: names,
            createdAt: now
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: humanCollabToolTitle(tool, completed: completed), activityDetail: names.joined(separator: ", "))
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
            if !isPlaceholderPrompt(prompt) {
                let previousPrompt = subagents[index].prompt
                subagents[index].prompt = prompt
                upsertPromptMessage(prompt, toSubagentAt: index, replacing: previousPrompt)
            }
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

    private mutating func ensureSubagentThread(id: String, createdAt: Date = Date()) -> Int {
        if let index = subagents.firstIndex(where: { $0.id == id }) {
            return index
        }

        let name = nameForSubagent(id: id, state: nil)
        subagents.append(CodexSubagentState(
            id: id,
            name: name,
            title: name,
            prompt: "Subagent task",
            status: .running,
            messages: [],
            createdAt: createdAt,
            completedAt: nil
        ))
        ensureSideChat()
        return subagents.count - 1
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

    private mutating func upsertPromptMessage(_ prompt: String, toSubagentAt index: Int, replacing previousPrompt: String?) {
        guard !isPlaceholderPrompt(prompt) else { return }
        subagents[index].prompt = prompt

        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.role == .user }) {
            let current = subagents[index].messages[messageIndex].text
            if previousPrompt == nil || current == previousPrompt || isPlaceholderPrompt(current) {
                subagents[index].messages[messageIndex].setText(prompt, parseContent: true)
            }
            return
        }

        subagents[index].messages.insert(CodexChatMessage(role: .user, text: prompt, createdAt: subagents[index].createdAt), at: 0)
    }

    private mutating func appendSubagentAssistantDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        subagents[index].status = .running
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            subagents[index].messages[messageIndex].appendStreamingText(delta)
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .assistant, text: delta, isStreaming: true, parseContent: false))
        }
        ensureSideChat()
        return true
    }

    private mutating func completeSubagentAssistantMessage(_ text: String, threadID: String, itemID: String, createdAt: Date) {
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            subagents[index].messages[messageIndex].setText(text, parseContent: true)
            subagents[index].messages[messageIndex].isStreaming = false
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .assistant, text: text, createdAt: createdAt))
        }
    }

    private mutating func startSubagentCommand(_ item: ThreadItem, at index: Int) {
        guard subagents[index].messages.contains(where: { $0.commandRun?.itemID == item.id }) == false else { return }
        let run = CodexChatMessage.CommandRun(
            itemID: item.id,
            command: firstString(in: item.raw, keys: ["command"]) ?? "Running command",
            cwd: firstString(in: item.raw, keys: ["cwd"]),
            output: "",
            status: firstString(in: item.raw, keys: ["status"]) ?? "active",
            exitCode: nil,
            isStreaming: true
        )
        subagents[index].messages.append(CodexChatMessage(role: .terminal, text: "", isStreaming: true, parseContent: false, commandRun: run))
    }

    private mutating func appendSubagentCommandOutput(_ delta: String, itemID: String, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.commandRun?.itemID == itemID }) {
            subagents[index].messages[messageIndex].commandRun?.output.append(delta)
            subagents[index].messages[messageIndex].commandRun?.isStreaming = true
            subagents[index].messages[messageIndex].isStreaming = true
            subagents[index].messages[messageIndex].text = subagents[index].messages[messageIndex].commandRun?.output ?? ""
            return
        }

        let run = CodexChatMessage.CommandRun(
            itemID: itemID,
            command: "Running command",
            cwd: nil,
            output: delta,
            status: "active",
            exitCode: nil,
            isStreaming: true
        )
        subagents[index].messages.append(CodexChatMessage(role: .terminal, text: delta, isStreaming: true, parseContent: false, commandRun: run))
    }

    private mutating func finishSubagentCommand(_ item: ThreadItem, at index: Int) {
        let output = firstString(in: item.raw, keys: ["aggregatedOutput", "output", "stdout"]) ?? ""
        let status = firstString(in: item.raw, keys: ["status"]) ?? "completed"
        let run = CodexChatMessage.CommandRun(
            itemID: item.id,
            command: firstString(in: item.raw, keys: ["command"]) ?? "Command",
            cwd: firstString(in: item.raw, keys: ["cwd"]),
            output: output,
            status: status,
            exitCode: intValue(item.raw["exitCode"]),
            isStreaming: status == "active" || status == "inProgress"
        )

        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.commandRun?.itemID == item.id }) {
            var finalRun = run
            if finalRun.output.isEmpty {
                finalRun.output = subagents[index].messages[messageIndex].commandRun?.output ?? ""
            }
            subagents[index].messages[messageIndex].commandRun = finalRun
            subagents[index].messages[messageIndex].text = finalRun.output
            subagents[index].messages[messageIndex].isStreaming = finalRun.isStreaming
            return
        }

        subagents[index].messages.append(CodexChatMessage(role: .terminal, text: output, isStreaming: run.isStreaming, parseContent: false, commandRun: run))
    }

    private mutating func startSubagentFileChange(_ item: ThreadItem, at index: Int) {
        guard subagents[index].messages.contains(where: { $0.fileChange?.itemID == item.id }) == false else { return }
        let change = fileChange(from: item.raw, itemID: item.id, fallbackStatus: "active")
        let message = CodexChatMessage(
            role: .fileChange,
            text: change.diff.isEmpty ? change.output : change.diff,
            isStreaming: change.isStreaming,
            parseContent: false,
            fileChange: change
        )
        subagents[index].messages.append(message)
    }

    private mutating func appendSubagentFileChangeOutput(_ delta: String, itemID: String, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.fileChange?.itemID == itemID }) {
            subagents[index].messages[messageIndex].fileChange?.output.append(delta)
            subagents[index].messages[messageIndex].fileChange?.isStreaming = true
            subagents[index].messages[messageIndex].isStreaming = true
            if subagents[index].messages[messageIndex].text.isEmpty {
                subagents[index].messages[messageIndex].text = subagents[index].messages[messageIndex].fileChange?.output ?? ""
            }
            return
        }

        let change = CodexChatMessage.fileChange(
            itemID: itemID,
            path: nil,
            diff: "",
            output: delta,
            status: "active",
            isStreaming: true
        )
        subagents[index].messages.append(CodexChatMessage(
            role: .fileChange,
            text: delta,
            isStreaming: true,
            parseContent: false,
            fileChange: change
        ))
    }

    private mutating func finishSubagentFileChange(_ item: ThreadItem, at index: Int) {
        var change = fileChange(from: item.raw, itemID: item.id, fallbackStatus: "completed")
        change.isStreaming = false
        if change.status == "active" || change.status == "running" || change.status == "inProgress" {
            change.status = "completed"
        }
        upsertSubagentFileChange(change, at: index)
    }

    private mutating func upsertSubagentFileChange(_ change: CodexChatMessage.FileChange, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.fileChange?.itemID == change.itemID }) {
            var merged = change
            if merged.diff.isEmpty {
                merged.diff = subagents[index].messages[messageIndex].fileChange?.diff ?? ""
            }
            if merged.output.isEmpty {
                merged.output = subagents[index].messages[messageIndex].fileChange?.output ?? ""
            }
            subagents[index].messages[messageIndex].fileChange = merged
            subagents[index].messages[messageIndex].text = merged.diff.isEmpty ? merged.output : merged.diff
            subagents[index].messages[messageIndex].isStreaming = merged.isStreaming
            return
        }

        subagents[index].messages.append(CodexChatMessage(
            role: .fileChange,
            text: change.diff.isEmpty ? change.output : change.diff,
            isStreaming: change.isStreaming,
            parseContent: false,
            fileChange: change
        ))
    }

    private func fileChange(
        from raw: [String: CodexJSONValue],
        itemID: String,
        fallbackStatus: String
    ) -> CodexChatMessage.FileChange {
        var patchedRaw = raw
        if patchedRaw["status"] == nil {
            patchedRaw["status"] = .string(fallbackStatus)
        }
        return CodexChatMessage.fileChange(itemID: itemID, raw: patchedRaw, fallbackStatus: fallbackStatus)
            ?? CodexChatMessage.fileChange(
                itemID: itemID,
                path: firstString(in: patchedRaw, keys: ["path"]),
                diff: firstString(in: patchedRaw, keys: ["diff", "patch", "unified_diff"]) ?? "",
                kind: firstString(in: patchedRaw, keys: ["kind", "type"]) ?? "update",
                output: firstString(in: patchedRaw, keys: ["delta", "output", "aggregatedOutput"]) ?? "",
                status: fallbackStatus,
                isStreaming: fallbackStatus == "active"
            )
    }

    private mutating func startSubagentPlan(_ item: ThreadItem, at index: Int) {
        guard subagents[index].messages.contains(where: { $0.planUpdate?.itemID == item.id }) == false else { return }
        guard let plan = CodexChatMessage.planUpdate(itemID: item.id, raw: item.raw, isStreaming: true) else { return }
        subagents[index].messages.append(CodexChatMessage(
            role: .plan,
            text: plan.copyText,
            isStreaming: plan.isStreaming,
            parseContent: false,
            planUpdate: plan
        ))
    }

    private mutating func appendSubagentPlanDelta(_ delta: String, itemID: String, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.planUpdate?.itemID == itemID }) {
            subagents[index].messages[messageIndex].planUpdate?.text.append(delta)
            subagents[index].messages[messageIndex].planUpdate?.isStreaming = true
            subagents[index].messages[messageIndex].text = subagents[index].messages[messageIndex].planUpdate?.copyText ?? ""
            subagents[index].messages[messageIndex].isStreaming = true
            return
        }

        let plan = CodexChatMessage.planUpdate(itemID: itemID, text: delta, isStreaming: true)
        subagents[index].messages.append(CodexChatMessage(
            role: .plan,
            text: plan.copyText,
            isStreaming: true,
            parseContent: false,
            planUpdate: plan
        ))
    }

    private mutating func finishSubagentPlan(_ item: ThreadItem, at index: Int) {
        guard var plan = CodexChatMessage.planUpdate(itemID: item.id, raw: item.raw, isStreaming: false) else { return }
        plan.isStreaming = false
        upsertSubagentPlan(plan, at: index)
    }

    private mutating func upsertSubagentPlan(_ plan: CodexChatMessage.PlanUpdate, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.planUpdate?.itemID == plan.itemID }) {
            var merged = plan
            if merged.text.isEmpty {
                merged.text = subagents[index].messages[messageIndex].planUpdate?.text ?? ""
            }
            subagents[index].messages[messageIndex].planUpdate = merged
            subagents[index].messages[messageIndex].text = merged.copyText
            subagents[index].messages[messageIndex].isStreaming = merged.isStreaming
            return
        }

        subagents[index].messages.append(CodexChatMessage(
            role: .plan,
            text: plan.copyText,
            isStreaming: plan.isStreaming,
            parseContent: false,
            planUpdate: plan
        ))
    }

    private mutating func startSubagentToolCall(_ item: ThreadItem, at index: Int) {
        guard subagents[index].messages.contains(where: { $0.toolCall?.itemID == item.id }) == false else { return }
        let toolCall = toolCall(from: item.raw, itemID: item.id, fallbackStatus: "inProgress")
        subagents[index].messages.append(CodexChatMessage(
            role: .tool,
            text: toolCall.copyText,
            isStreaming: toolCall.isStreaming,
            parseContent: false,
            toolCall: toolCall
        ))
    }

    private mutating func appendSubagentToolCallProgress(_ progress: String, itemID: String, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.toolCall?.itemID == itemID }) {
            subagents[index].messages[messageIndex].toolCall?.progress.append(progress)
            subagents[index].messages[messageIndex].toolCall?.isStreaming = true
            subagents[index].messages[messageIndex].text = subagents[index].messages[messageIndex].toolCall?.copyText ?? ""
            subagents[index].messages[messageIndex].isStreaming = true
            return
        }

        let toolCall = CodexChatMessage.toolCall(
            itemID: itemID,
            server: nil,
            tool: "Tool",
            progress: [progress],
            isStreaming: true
        )
        subagents[index].messages.append(CodexChatMessage(
            role: .tool,
            text: toolCall.copyText,
            isStreaming: true,
            parseContent: false,
            toolCall: toolCall
        ))
    }

    private mutating func finishSubagentToolCall(_ item: ThreadItem, at index: Int) {
        var toolCall = toolCall(from: item.raw, itemID: item.id, fallbackStatus: "completed")
        toolCall.isStreaming = false
        upsertSubagentToolCall(toolCall, at: index)
    }

    private mutating func upsertSubagentToolCall(_ toolCall: CodexChatMessage.ToolCall, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.toolCall?.itemID == toolCall.itemID }) {
            var merged = toolCall
            if merged.progress.isEmpty {
                merged.progress = subagents[index].messages[messageIndex].toolCall?.progress ?? []
            }
            if merged.arguments.isEmpty {
                merged.arguments = subagents[index].messages[messageIndex].toolCall?.arguments ?? ""
            }
            if merged.result.isEmpty {
                merged.result = subagents[index].messages[messageIndex].toolCall?.result ?? ""
            }
            subagents[index].messages[messageIndex].toolCall = merged
            subagents[index].messages[messageIndex].text = merged.copyText
            subagents[index].messages[messageIndex].isStreaming = merged.isStreaming
            return
        }

        subagents[index].messages.append(CodexChatMessage(
            role: .tool,
            text: toolCall.copyText,
            isStreaming: toolCall.isStreaming,
            parseContent: false,
            toolCall: toolCall
        ))
    }

    private mutating func upsertSubagentNotice(_ notice: CodexChatMessage.Notice, at index: Int) {
        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.notice?.itemID == notice.itemID }) {
            subagents[index].messages[messageIndex].notice = notice
            subagents[index].messages[messageIndex].text = notice.copyText
            subagents[index].messages[messageIndex].isStreaming = notice.isStreaming
            return
        }

        subagents[index].messages.append(CodexChatMessage(
            role: .notice,
            text: notice.copyText,
            isStreaming: notice.isStreaming,
            parseContent: false,
            notice: notice
        ))
    }

    private func toolCall(
        from raw: [String: CodexJSONValue],
        itemID: String,
        fallbackStatus: String
    ) -> CodexChatMessage.ToolCall {
        CodexChatMessage.toolCall(itemID: itemID, raw: raw, fallbackStatus: fallbackStatus)
            ?? CodexChatMessage.toolCall(
                itemID: itemID,
                server: firstString(in: raw, keys: ["server", "serverName"]),
                tool: firstString(in: raw, keys: ["tool", "toolName", "name"]) ?? "Tool",
                status: fallbackStatus,
                isStreaming: fallbackStatus == "inProgress"
            )
    }

    private mutating func appendSubagentSystemMessage(_ text: String, itemID: String, at index: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .system && $0.detail == itemID }) {
            subagents[index].messages[messageIndex].setText(text, parseContent: true)
            subagents[index].messages[messageIndex].isStreaming = false
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .system, text: text, detail: itemID))
        }
    }

    private mutating func finishSubagentStreamingMessages(at index: Int) {
        for messageIndex in subagents[index].messages.indices {
            guard subagents[index].messages[messageIndex].isStreaming else { continue }
            subagents[index].messages[messageIndex].isStreaming = false
            if subagents[index].messages[messageIndex].role == .assistant {
                subagents[index].messages[messageIndex].setText(subagents[index].messages[messageIndex].text, parseContent: true)
            }
            if subagents[index].messages[messageIndex].commandRun != nil {
                subagents[index].messages[messageIndex].commandRun?.isStreaming = false
            }
            if subagents[index].messages[messageIndex].fileChange != nil {
                subagents[index].messages[messageIndex].fileChange?.isStreaming = false
            }
            if subagents[index].messages[messageIndex].planUpdate != nil {
                subagents[index].messages[messageIndex].planUpdate?.isStreaming = false
            }
            if subagents[index].messages[messageIndex].toolCall != nil {
                subagents[index].messages[messageIndex].toolCall?.isStreaming = false
            }
            if subagents[index].messages[messageIndex].notice != nil {
                subagents[index].messages[messageIndex].notice?.isStreaming = false
            }
        }
    }

    private mutating func ensureSideChat() {
        if sideChat == nil {
            sideChat = CodexSideChatState(title: "Side chat", createdAt: Date())
        }
    }

    private mutating func replaceAgentName(_ oldName: String, with newName: String) {
        guard oldName != newName else { return }
        for index in lifecycleEvents.indices {
            lifecycleEvents[index].title = lifecycleEvents[index].title.replacingOccurrences(of: oldName, with: newName)
            lifecycleEvents[index].agentNames = lifecycleEvents[index].agentNames.map { $0 == oldName ? newName : $0 }
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

    private func isCollabAgentToolCall(_ item: ThreadItem) -> Bool {
        Self.normalizedKey(item.type) == "collabagenttoolcall"
            || (collabTool(from: item) != nil && (item.raw["receiverThreadIds"] != nil || item.raw["agentsStates"] != nil))
    }

    private func collabTool(from item: ThreadItem) -> String? {
        firstString(in: item.raw, keys: ["tool"])
    }

    private func collabReceiverThreadIDs(from item: ThreadItem, states: [String: [String: CodexJSONValue]]) -> [String] {
        let receiverIDs = arrayValue(item.raw["receiverThreadIds"])?.compactMap(stringValue) ?? []
        if !receiverIDs.isEmpty { return receiverIDs }
        return states.keys.sorted()
    }

    private func collabAgentStates(from item: ThreadItem) -> [String: [String: CodexJSONValue]] {
        guard let object = dictionaryValue(item.raw["agentsStates"]) else { return [:] }
        var states: [String: [String: CodexJSONValue]] = [:]
        for (key, value) in object {
            if let state = dictionaryValue(value) {
                states[key] = state
            }
        }
        return states
    }

    private func collabStatus(
        tool: String,
        completed: Bool,
        states: [String: [String: CodexJSONValue]]
    ) -> CodexSubagentState.Status {
        if tool == "closeAgent", completed { return .closed }
        let stateStatuses = states.values.compactMap { firstString(in: $0, keys: ["status", "state"])?.lowercased() }
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

    private func humanCollabToolTitle(_ tool: String, completed: Bool = true) -> String {
        switch tool {
        case "spawnAgent": return completed ? "Subagents started" : "Subagent spawning"
        case "wait": return completed ? "Subagents completed" : "Waiting on subagents"
        case "closeAgent": return completed ? "Subagents closed" : "Closing subagents"
        default: return "Subagent update"
        }
    }

    private func nameForSubagent(id: String, state: [String: CodexJSONValue]?) -> String {
        if let existing = subagents.first(where: { $0.id == id }) {
            return existing.name
        }
        if let displayName = metadataDisplayName(in: state) {
            return displayName
        }
        if let displayName = subagentMetadataByID[id]?.displayName {
            return displayName
        }
        return "Agent \(subagents.count + 1)"
    }

    private func metadataDisplayName(in state: [String: CodexJSONValue]?) -> String? {
        guard let state else { return nil }
        return Self.agentDisplayName(
            nickname: firstString(in: state, keys: ["agentNickname", "agent_nickname", "nickname", "name", "title"]),
            role: firstString(in: state, keys: ["agentRole", "agent_role", "role", "kind"])
        )
    }

    private static func agentDisplayName(nickname: String?, role: String?) -> String? {
        let nickname = cleanMetadataValue(nickname)
        let role = cleanMetadataValue(role)
        switch (nickname, role) {
        case let (nickname?, role?): return "\(nickname) [\(role)]"
        case let (nickname?, nil): return nickname
        case let (nil, role?): return "[\(role)]"
        case (nil, nil): return nil
        }
    }

    private func cleanMetadataValue(_ value: String?) -> String? {
        Self.cleanMetadataValue(value)
    }

    private static func cleanMetadataValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func collabLifecycleTitle(tool: String, completed: Bool, status: CodexSubagentState.Status, names: [String]) -> String {
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

    private func titleForCollabPrompt(_ prompt: String) -> String {
        guard !isPlaceholderPrompt(prompt) else { return "Delegated agent" }
        let normalized = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 56 else { return normalized }
        return String(normalized.prefix(56)) + "…"
    }

    private func isPlaceholderPrompt(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt == "Subagent task"
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

    private func intValue(_ value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private func userMessageText(from item: ThreadItem) -> String? {
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

    private func childActivityText(from item: ThreadItem, started: Bool) -> String? {
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

    private func parseMentionedAgentNames(from text: String) -> [String] {
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
