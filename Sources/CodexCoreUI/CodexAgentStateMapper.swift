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
    private var subagentMetadataByID: [String: CodexSubagentMetadata]
    private var subagentTranscriptsByID: [String: CodexChatTranscriptState]
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
        self.subagentTranscriptsByID = Dictionary(uniqueKeysWithValues: subagents.map { subagent in
            (subagent.id, CodexChatTranscriptState(messages: subagent.messages))
        })
        self.completedCollabToolCallIDs = []
    }

    public mutating func reset() {
        lifecycleEvents = []
        sideChat = nil
        subagents = []
        subagentIDsByItemID = [:]
        subagentMetadataByID = [:]
        subagentTranscriptsByID = [:]
        completedCollabToolCallIDs = []
    }

    @discardableResult
    public mutating func updateSubagentMetadata(id: String, name: String?, role: String? = nil) -> Bool {
        let metadata = CodexSubagentMetadata(
            nickname: CodexAgentItemParser.cleanMetadataValue(name),
            role: CodexAgentItemParser.cleanMetadataValue(role)
        )
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
        CodexAgentItemParser.isSubagentType(type)
    }

    public func isSubagentItem(_ item: ThreadItem) -> Bool {
        CodexAgentItemParser.isSubagentItem(item)
    }

    @discardableResult
    public mutating func itemStarted(_ item: ThreadItem) -> CodexAgentItemUpdate? {
        guard isSubagentItem(item) else { return nil }
        if CodexAgentItemParser.isCollabAgentToolCall(item) {
            guard !completedCollabToolCallIDs.contains(item.id) else { return nil }
            return applyCollabAgentToolCall(item, completed: false)
        }

        let agents = subagentDescriptors(from: item)
        guard !agents.isEmpty else {
            return CodexAgentItemUpdate(
                activityTitle: CodexAgentItemParser.humanItemType(item.type),
                activityDetail: CodexAgentItemParser.previewText(item.text ?? "Subagent started")
            )
        }

        let agentNames = agents.map(\.name)
        appendLifecycleEvent(CodexAgentLifecycleBuilder.spawning(agents: agents, item: item))

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
        if CodexAgentItemParser.isCollabAgentToolCall(item) {
            completedCollabToolCallIDs.insert(item.id)
            return applyCollabAgentToolCall(item, completed: true)
        }

        let agents = subagentDescriptors(from: item)
        let status = CodexAgentItemParser.subagentStatus(from: item)
        let completedAt = Date()
        let result = CodexAgentItemParser.subagentResultText(from: item)

        if agents.isEmpty, let id = subagentIDsByItemID[item.id], let index = subagents.firstIndex(where: { $0.id == id }) {
            subagents[index].status = status
            subagents[index].completedAt = completedAt
            appendResult(result, toSubagentAt: index, createdAt: completedAt)
            appendLifecycleEvent(CodexAgentLifecycleBuilder.finished(
                status: status,
                item: item,
                result: result,
                names: [subagents[index].name],
                fallback: "Subagent finished.",
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
                activityTitle: CodexAgentItemParser.humanItemType(item.type),
                activityDetail: CodexAgentItemParser.previewText(result ?? item.text ?? "Completed")
            )
        }

        appendLifecycleEvent(CodexAgentLifecycleBuilder.finished(
            status: status,
            item: item,
            result: result,
            names: names,
            fallback: "Subagent work finished.",
            createdAt: completedAt
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagents \(status.rawValue)", activityDetail: names.joined(separator: ", "))
    }

    @discardableResult
    public mutating func assistantMessageCompleted(_ text: String) -> Bool {
        let names = CodexAgentItemParser.parseMentionedAgentNames(from: text)
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

        return subagentMessageDelta(delta, threadID: subagentID, itemID: itemID)
    }

    public func hasSubagentThread(id: String) -> Bool {
        subagents.contains { $0.id == id } || subagentMetadataByID[id] != nil
    }

    @discardableResult
    public mutating func applyChildThreadReferences(_ references: [CodexChildThreadReference]) -> Bool {
        var changed = false
        for reference in references {
            let name = reference.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? nameForSubagent(id: reference.threadID, state: nil)
            upsertSubagent(
                id: reference.threadID,
                name: name,
                title: reference.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name,
                prompt: reference.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Subagent task",
                status: CodexSubagentState.Status(historyStatus: reference.status) ?? .running,
                itemID: reference.itemID ?? reference.threadID,
                result: nil,
                createdAt: nil,
                completedAt: nil
            )
            changed = true
        }
        if changed {
            ensureSideChat()
        }
        return changed
    }

    @discardableResult
    public mutating func applyHydratedChildThread(
        _ child: CodexHydratedThread,
        reference: CodexChildThreadReference? = nil
    ) -> Bool {
        let threadID = child.snapshot.id
        var messages = child.snapshot.turns.flatMap(CodexChatTranscriptProjection.messages(for:))
        let firstUserMessage = messages.first(where: { $0.role == .user })?.text
        let name = child.agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? reference?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? nameForSubagent(id: threadID, state: nil)
        let prompt = firstUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? reference?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Subagent task"
        let status = CodexSubagentState.Status(snapshot: child.snapshot)
            ?? CodexSubagentState.Status(historyStatus: reference?.status)
            ?? .completed
        let completedAt = child.snapshot.turns.compactMap(\.completedAt).last
        let createdAt = child.snapshot.turns.first?.startedAt ?? completedAt ?? Date()
        if firstUserMessage == nil, !CodexAgentItemParser.isPlaceholderPrompt(prompt) {
            messages.insert(CodexChatMessage(role: .user, text: prompt, createdAt: createdAt), at: 0)
        }

        subagentIDsByItemID[reference?.itemID ?? threadID] = threadID
        if let metadataName = child.agentName ?? reference?.name {
            _ = updateSubagentMetadata(id: threadID, name: metadataName, role: child.agentRole)
        }

        let state = CodexSubagentState(
            id: threadID,
            name: name,
            title: reference?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name,
            prompt: prompt,
            status: status,
            messages: messages,
            createdAt: createdAt,
            completedAt: completedAt
        )

        if let index = subagents.firstIndex(where: { $0.id == threadID }) {
            subagents[index] = state
        } else {
            subagents.append(state)
        }
        subagentTranscriptsByID[threadID] = CodexChatTranscriptState(messages: messages)
        ensureSideChat()
        return true
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
        case "commandExecution", "fileChange", "patch", "plan", "mcpToolCall", "toolCall":
            updateSubagentTranscript(threadID: threadID, itemID: item.id) { transcript in
                transcript.startItem(item)
            }
        case "userMessage":
            if let text = CodexAgentItemParser.userMessageText(from: item) {
                upsertPromptMessage(text, toSubagentAt: index, replacing: subagents[index].prompt)
            }
        case "agentMessage", "assistantMessage":
            break
        default:
            if let text = CodexAgentItemParser.childActivityText(from: item, started: true) {
                appendSubagentSystemMessage(text, itemID: item.id, at: index)
            }
        }

        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent item started", activityDetail: "\(subagents[index].name): \(CodexAgentItemParser.humanItemType(item.type))")
    }

    @discardableResult
    public mutating func subagentItemCompleted(threadID: String, item: ThreadItem) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[item.id] = threadID

        switch item.type {
        case "agentMessage", "assistantMessage":
            if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateSubagentTranscript(threadID: threadID, itemID: item.id) { transcript in
                    transcript.completeItem(item)
                }
            }
        case "userMessage":
            if let text = CodexAgentItemParser.userMessageText(from: item) {
                upsertPromptMessage(text, toSubagentAt: index, replacing: subagents[index].prompt)
            }
        case "commandExecution", "fileChange", "patch", "plan", "mcpToolCall", "toolCall":
            updateSubagentTranscript(threadID: threadID, itemID: item.id) { transcript in
                transcript.completeItem(item)
            }
        default:
            if let text = CodexAgentItemParser.childActivityText(from: item, started: false) {
                appendSubagentSystemMessage(text, itemID: item.id, at: index)
            }
        }

        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent item completed", activityDetail: "\(subagents[index].name): \(CodexAgentItemParser.humanItemType(item.type))")
    }

    @discardableResult
    public mutating func subagentProjectedItemCompleted(
        threadID: String,
        itemID: String,
        message: CodexChatMessage,
        itemType: String
    ) -> CodexAgentItemUpdate? {
        return applyProjectedSubagentItem(
            threadID: threadID,
            itemID: itemID,
            message: message,
            itemType: itemType,
            activityVerb: "completed"
        )
    }

    @discardableResult
    public mutating func subagentProjectedItemStarted(
        threadID: String,
        itemID: String,
        message: CodexChatMessage,
        itemType: String
    ) -> CodexAgentItemUpdate? {
        let update = applyProjectedSubagentItem(
            threadID: threadID,
            itemID: itemID,
            message: message,
            itemType: itemType,
            activityVerb: "started"
        )
        if let index = subagents.firstIndex(where: { $0.id == threadID }) {
            subagents[index].status = .running
        }
        return update
    }

    private mutating func applyProjectedSubagentItem(
        threadID: String,
        itemID: String,
        message: CodexChatMessage,
        itemType: String,
        activityVerb: String
    ) -> CodexAgentItemUpdate? {
        guard hasSubagentThread(id: threadID) else { return nil }
        let index = ensureSubagentThread(id: threadID)
        subagentIDsByItemID[itemID] = threadID
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.upsertProjectedMessage(message, itemID: itemID)
        }
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent item \(activityVerb)", activityDetail: "\(subagents[index].name): \(CodexAgentItemParser.humanItemType(itemType))")
    }

    @discardableResult
    public mutating func subagentProjectedItemUpdated(
        threadID: String,
        itemID: String,
        message: CodexChatMessage
    ) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.upsertProjectedMessage(message, itemID: itemID)
        }
        subagentIDsByItemID[itemID] = threadID
        subagents[index].status = .running
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentMessageDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        let index = updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.appendAssistantDelta(delta, itemID: itemID)
        }
        subagents[index].status = .running
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentCommandOutputDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.appendCommandOutput(delta, itemID: itemID)
        }
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentFileChangeOutputDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.appendFileChangeOutput(delta, itemID: itemID)
        }
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentPlanDelta(_ delta: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.appendPlanDelta(delta, itemID: itemID)
        }
        ensureSideChat()
        return true
    }

    @discardableResult
    public mutating func subagentToolCallProgress(_ progress: String, threadID: String, itemID: String) -> Bool {
        guard hasSubagentThread(id: threadID) else { return false }
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.appendToolCallProgress(progress, itemID: itemID)
        }
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
        updateSubagentTranscript(threadID: threadID, itemID: itemID) { transcript in
            transcript.upsertNotice(notice)
        }
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
        updateSubagentTranscript(threadID: threadID) { transcript in
            transcript.finishStreamingMessages()
        }

        let detail = if let cleanError, !cleanError.isEmpty { cleanError } else { "Subagent turn finished." }
        appendLifecycleEvent(CodexAgentLifecycleBuilder.turnFinished(
            status: subagents[index].status,
            name: subagents[index].name,
            detail: detail,
            createdAt: completedAt
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(activityTitle: "Subagent \(subagents[index].status.rawValue)", activityDetail: subagents[index].name)
    }

    private func subagentDescriptors(from item: ThreadItem) -> [CodexSubagentDescriptor] {
        if let id = subagentIDsByItemID[item.id], let existing = subagents.first(where: { $0.id == id }) {
            return CodexAgentItemParser.subagentDescriptors(
                from: item,
                existing: CodexSubagentDescriptor(id: existing.id, name: existing.name, title: existing.title, prompt: existing.prompt)
            )
        }

        return CodexAgentItemParser.subagentDescriptors(from: item)
    }

    mutating func upsertSubagent(
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
            if !CodexAgentItemParser.isPlaceholderPrompt(prompt) {
                let previousPrompt = subagents[index].prompt
                subagents[index].prompt = prompt
                upsertPromptMessage(prompt, toSubagentAt: index, replacing: previousPrompt)
            }
            subagents[index].status = status
            if let completedAt { subagents[index].completedAt = completedAt }
            appendResult(result, toSubagentAt: index, createdAt: completedAt ?? Date())
            syncSubagentTranscript(at: index)
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
        syncSubagentTranscript(at: subagents.count - 1)
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

    @discardableResult
    private mutating func updateSubagentTranscript(
        threadID: String,
        itemID: String? = nil,
        _ update: (inout CodexChatTranscriptState) -> Void
    ) -> Int {
        let index = ensureSubagentThread(id: threadID)
        if let itemID {
            subagentIDsByItemID[itemID] = threadID
        }
        var transcript = subagentTranscriptsByID[threadID] ?? CodexChatTranscriptState(messages: subagents[index].messages)
        update(&transcript)
        subagentTranscriptsByID[threadID] = transcript
        subagents[index].messages = transcript.messages
        ensureSideChat()
        return index
    }

    private mutating func syncSubagentTranscript(at index: Int) {
        subagentTranscriptsByID[subagents[index].id] = CodexChatTranscriptState(messages: subagents[index].messages)
    }

    private mutating func appendResult(_ result: String?, toSubagentAt index: Int, createdAt: Date) {
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .assistant }) {
            subagents[index].messages[messageIndex].setText(result, parseContent: true)
            subagents[index].messages[messageIndex].isStreaming = false
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .assistant, text: result, createdAt: createdAt))
        }
        syncSubagentTranscript(at: index)
    }

    private mutating func upsertPromptMessage(_ prompt: String, toSubagentAt index: Int, replacing previousPrompt: String?) {
        guard !CodexAgentItemParser.isPlaceholderPrompt(prompt) else { return }
        subagents[index].prompt = prompt

        if let messageIndex = subagents[index].messages.firstIndex(where: { $0.role == .user }) {
            let current = subagents[index].messages[messageIndex].text
            if previousPrompt == nil || current == previousPrompt || CodexAgentItemParser.isPlaceholderPrompt(current) {
                subagents[index].messages[messageIndex].setText(prompt, parseContent: true)
                syncSubagentTranscript(at: index)
            }
            return
        }

        subagents[index].messages.insert(CodexChatMessage(role: .user, text: prompt, createdAt: subagents[index].createdAt), at: 0)
        syncSubagentTranscript(at: index)
    }

    private mutating func appendSubagentSystemMessage(_ text: String, itemID: String, at index: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let messageIndex = subagents[index].messages.lastIndex(where: { $0.role == .system && $0.detail == itemID }) {
            subagents[index].messages[messageIndex].setText(text, parseContent: true)
            subagents[index].messages[messageIndex].isStreaming = false
        } else {
            subagents[index].messages.append(CodexChatMessage(role: .system, text: text, detail: itemID))
        }
        syncSubagentTranscript(at: index)
    }

    mutating func ensureSideChat() {
        if sideChat == nil {
            sideChat = CodexSideChatState(title: "Side chat", createdAt: Date())
        }
    }

    mutating func appendLifecycleEvent(_ event: CodexAgentLifecycleEvent) {
        lifecycleEvents.append(event)
    }

    private mutating func replaceAgentName(_ oldName: String, with newName: String) {
        guard oldName != newName else { return }
        for index in lifecycleEvents.indices {
            lifecycleEvents[index].title = lifecycleEvents[index].title.replacingOccurrences(of: oldName, with: newName)
            lifecycleEvents[index].agentNames = lifecycleEvents[index].agentNames.map { $0 == oldName ? newName : $0 }
        }
    }

    func nameForSubagent(id: String, state: [String: CodexJSONValue]?) -> String {
        if let existing = subagents.first(where: { $0.id == id }) {
            return existing.name
        }
        if let displayName = CodexAgentItemParser.metadataDisplayName(in: state) {
            return displayName
        }
        if let displayName = subagentMetadataByID[id]?.displayName {
            return displayName
        }
        return "Agent \(subagents.count + 1)"
    }

}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
