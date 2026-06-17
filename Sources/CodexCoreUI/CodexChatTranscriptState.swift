import Foundation
import CodexCore

public struct CodexChatTranscriptState: Sendable, Equatable {
    public private(set) var messages: [CodexChatMessage]

    private var assistantMessageIDsByItemID: [String: UUID]
    private var commandMessageIDsByItemID: [String: UUID]
    private var fileChangeMessageIDsByItemID: [String: UUID]
    private var planMessageIDsByItemID: [String: UUID]
    private var toolCallMessageIDsByItemID: [String: UUID]
    private var noticeMessageIDsByItemID: [String: UUID]
    private var reasoningMessageIDsByItemID: [String: UUID]

    public init(messages: [CodexChatMessage] = []) {
        self.messages = messages
        self.assistantMessageIDsByItemID = [:]
        self.commandMessageIDsByItemID = [:]
        self.fileChangeMessageIDsByItemID = [:]
        self.planMessageIDsByItemID = [:]
        self.toolCallMessageIDsByItemID = [:]
        self.noticeMessageIDsByItemID = [:]
        self.reasoningMessageIDsByItemID = [:]
        rebuildItemIndexes()
    }

    public mutating func reset(messages: [CodexChatMessage] = []) {
        self = CodexChatTranscriptState(messages: messages)
    }

    public mutating func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        messages.append(CodexChatMessage(role: role, text: text, detail: detail))
    }

    public mutating func append(_ message: CodexChatMessage) {
        remember(message)
        messages.append(message)
    }

    @discardableResult
    public mutating func upsertProjectedMessage(_ message: CodexChatMessage, itemID: String? = nil) -> Bool {
        switch message.role {
        case .assistant:
            guard let itemID else {
                append(message)
                return true
            }
            upsertAssistantMessage(message, itemID: itemID)
        case .terminal:
            guard let run = message.commandRun else { return false }
            upsertCommandRun(run)
        case .fileChange:
            guard let change = message.fileChange else { return false }
            upsertFileChange(change)
        case .plan:
            guard let plan = message.planUpdate else { return false }
            upsertPlan(plan)
        case .tool:
            guard let toolCall = message.toolCall else { return false }
            upsertToolCall(toolCall)
        case .notice:
            guard let notice = message.notice else { return false }
            upsertNotice(notice)
        case .reasoning:
            guard let block = message.reasoningBlock else { return false }
            upsertReasoning(block)
        case .user, .system:
            append(message)
        }
        return true
    }

    public mutating func appendAssistantDelta(_ delta: String, itemID: String) {
        if let index = index(for: itemID, in: assistantMessageIDsByItemID) {
            messages[index].appendStreamingText(delta)
            messages[index].isStreaming = true
            return
        }

        var message = CodexChatMessage(role: .assistant, text: delta, isStreaming: true, parseContent: false)
        message.detail = nil
        assistantMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    @discardableResult
    public mutating func startItem(_ item: ThreadItem) -> CodexChatMessage? {
        guard !hasMessage(for: item.id, type: item.type),
              let message = CodexChatTranscriptProjection.message(for: item, fallbackStatus: "active") else {
            return nil
        }
        remember(message)
        messages.append(message)
        return message
    }

    @discardableResult
    public mutating func completeItem(_ item: ThreadItem) -> CodexChatMessage? {
        guard let message = CodexChatTranscriptProjection.message(for: item, fallbackStatus: "completed") else {
            return nil
        }

        switch item.type {
        case "agentMessage", "assistantMessage":
            upsertAssistantMessage(message, itemID: item.id)
        case "commandExecution":
            guard let run = message.commandRun else { return nil }
            upsertCommandRun(run)
        case "fileChange", "patch":
            guard let change = message.fileChange else { return nil }
            upsertFileChange(change)
        case "plan":
            guard let plan = message.planUpdate else { return nil }
            upsertPlan(plan)
        case "mcpToolCall", "toolCall":
            guard let toolCall = message.toolCall else { return nil }
            upsertToolCall(toolCall)
        case "reasoning":
            guard let block = message.reasoningBlock else { return nil }
            upsertReasoning(block)
        default:
            messages.append(message)
        }
        return message
    }

    public mutating func appendCommandOutput(_ delta: String, itemID: String) {
        if let index = index(for: itemID, in: commandMessageIDsByItemID) {
            messages[index].commandRun?.output.append(delta)
            messages[index].commandRun?.isStreaming = true
            messages[index].isStreaming = true
            messages[index].text = messages[index].commandRun?.output ?? ""
            return
        }

        let run = CodexChatMessage.CommandRun(
            itemID: itemID,
            command: "Running command",
            output: delta,
            status: "active",
            exitCode: nil,
            isStreaming: true
        )
        append(CodexChatTranscriptProjection.commandMessage(run))
    }

    public mutating func appendReasoningDelta(_ delta: String, itemID: String, isSummary: Bool = false) {
        if let index = index(for: itemID, in: reasoningMessageIDsByItemID) {
            messages[index].reasoningBlock?.text.append(delta)
            if isSummary {
                messages[index].reasoningBlock?.isSummary = true
            }
            messages[index].reasoningBlock?.isStreaming = true
            messages[index].text = messages[index].reasoningBlock?.text ?? ""
            messages[index].isStreaming = true
            return
        }

        let block = CodexChatMessage.reasoningBlock(
            itemID: itemID,
            text: delta,
            isSummary: isSummary,
            isStreaming: true
        )
        append(CodexChatMessage.reasoningMessage(block))
    }

    public mutating func upsertReasoning(_ block: CodexChatMessage.ReasoningBlock) {
        if let index = index(for: block.itemID, in: reasoningMessageIDsByItemID) {
            var merged = block
            if merged.text.isEmpty {
                merged.text = messages[index].reasoningBlock?.text ?? ""
            }
            if messages[index].reasoningBlock?.isSummary == true {
                merged.isSummary = true
            }
            messages[index].reasoningBlock = merged
            messages[index].text = merged.text
            messages[index].isStreaming = merged.isStreaming
            return
        }

        append(CodexChatMessage.reasoningMessage(block))
    }

    public mutating func appendFileChangeOutput(_ delta: String, itemID: String) {
        if let index = index(for: itemID, in: fileChangeMessageIDsByItemID) {
            messages[index].fileChange?.output.append(delta)
            messages[index].fileChange?.isStreaming = true
            messages[index].isStreaming = true
            if messages[index].text.isEmpty {
                messages[index].text = messages[index].fileChange?.output ?? ""
            }
            return
        }

        var change = CodexChatMessage.fileChange(itemID: itemID, path: nil, diff: "", output: delta, status: "active", isStreaming: true)
        change.output = delta
        upsertFileChange(change)
    }

    public mutating func upsertFileChange(_ change: CodexChatMessage.FileChange) {
        if let index = index(for: change.itemID, in: fileChangeMessageIDsByItemID) {
            var merged = change
            if merged.diff.isEmpty {
                merged.diff = messages[index].fileChange?.diff ?? ""
            }
            if merged.output.isEmpty {
                merged.output = messages[index].fileChange?.output ?? ""
            }
            messages[index].fileChange = merged
            messages[index].text = merged.diff.isEmpty ? merged.output : merged.diff
            messages[index].isStreaming = merged.isStreaming
            return
        }

        append(CodexChatTranscriptProjection.fileChangeMessage(change))
    }

    public mutating func appendPlanDelta(_ delta: String, itemID: String) {
        if let index = index(for: itemID, in: planMessageIDsByItemID) {
            messages[index].planUpdate?.text.append(delta)
            messages[index].planUpdate?.isStreaming = true
            messages[index].text = messages[index].planUpdate?.copyText ?? messages[index].text
            messages[index].isStreaming = true
            return
        }

        upsertPlan(CodexChatMessage.planUpdate(itemID: itemID, text: delta, isStreaming: true))
    }

    public mutating func upsertPlan(_ plan: CodexChatMessage.PlanUpdate) {
        if let index = index(for: plan.itemID, in: planMessageIDsByItemID) {
            var merged = plan
            if merged.text.isEmpty {
                merged.text = messages[index].planUpdate?.text ?? ""
            }
            messages[index].planUpdate = merged
            messages[index].text = merged.copyText
            messages[index].isStreaming = merged.isStreaming
            return
        }

        append(CodexChatTranscriptProjection.planMessage(plan))
    }

    public mutating func appendToolCallProgress(_ progress: String, itemID: String) {
        if let index = index(for: itemID, in: toolCallMessageIDsByItemID) {
            messages[index].toolCall?.progress.append(progress)
            messages[index].toolCall?.isStreaming = true
            messages[index].isStreaming = true
            messages[index].text = messages[index].toolCall?.copyText ?? ""
            return
        }

        let toolCall = CodexChatMessage.toolCall(itemID: itemID, server: nil, tool: "Tool", progress: [progress], isStreaming: true)
        upsertToolCall(toolCall)
    }

    public mutating func upsertToolCall(_ toolCall: CodexChatMessage.ToolCall) {
        if let index = index(for: toolCall.itemID, in: toolCallMessageIDsByItemID) {
            var merged = toolCall
            if merged.progress.isEmpty {
                merged.progress = messages[index].toolCall?.progress ?? []
            }
            if merged.arguments.isEmpty {
                merged.arguments = messages[index].toolCall?.arguments ?? ""
            }
            if merged.result.isEmpty {
                merged.result = messages[index].toolCall?.result ?? ""
            }
            messages[index].toolCall = merged
            messages[index].text = merged.copyText
            messages[index].isStreaming = merged.isStreaming
            return
        }

        append(CodexChatTranscriptProjection.toolCallMessage(toolCall))
    }

    public mutating func upsertNotice(_ notice: CodexChatMessage.Notice) {
        if let index = index(for: notice.itemID, in: noticeMessageIDsByItemID) {
            messages[index].notice = notice
            messages[index].text = notice.copyText
            messages[index].isStreaming = notice.isStreaming
            return
        }

        append(CodexChatMessage(
            role: .notice,
            text: notice.copyText,
            isStreaming: notice.isStreaming,
            parseContent: false,
            notice: notice
        ))
    }

    public mutating func finishStreamingMessages() {
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            if messages[index].role == .assistant {
                messages[index].setText(messages[index].text, parseContent: true)
            }
            messages[index].commandRun?.isStreaming = false
            messages[index].fileChange?.isStreaming = false
            messages[index].planUpdate?.isStreaming = false
            messages[index].toolCall?.isStreaming = false
            messages[index].notice?.isStreaming = false
            messages[index].reasoningBlock?.isStreaming = false
        }
    }

    private mutating func upsertAssistantMessage(_ message: CodexChatMessage, itemID: String) {
        if let index = index(for: itemID, in: assistantMessageIDsByItemID) {
            messages[index].setText(message.text, parseContent: true)
            messages[index].isStreaming = false
            messages[index].detail = message.detail
            return
        }

        assistantMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private mutating func upsertCommandRun(_ run: CodexChatMessage.CommandRun) {
        if let index = index(for: run.itemID, in: commandMessageIDsByItemID) {
            var finalRun = run
            if finalRun.output.isEmpty {
                finalRun.output = messages[index].commandRun?.output ?? ""
            }
            messages[index].commandRun = finalRun
            messages[index].text = finalRun.output
            messages[index].isStreaming = finalRun.isStreaming
            return
        }

        append(CodexChatTranscriptProjection.commandMessage(run))
    }

    private func hasMessage(for itemID: String, type: String) -> Bool {
        switch type {
        case "agentMessage", "assistantMessage":
            return assistantMessageIDsByItemID[itemID] != nil
        case "commandExecution":
            return commandMessageIDsByItemID[itemID] != nil
        case "fileChange", "patch":
            return fileChangeMessageIDsByItemID[itemID] != nil
        case "plan":
            return planMessageIDsByItemID[itemID] != nil
        case "mcpToolCall", "toolCall":
            return toolCallMessageIDsByItemID[itemID] != nil
        case "reasoning":
            return reasoningMessageIDsByItemID[itemID] != nil
        default:
            return false
        }
    }

    private mutating func remember(_ message: CodexChatMessage) {
        switch message.role {
        case .assistant:
            break
        case .terminal:
            if let itemID = message.commandRun?.itemID {
                commandMessageIDsByItemID[itemID] = message.id
            }
        case .fileChange:
            if let itemID = message.fileChange?.itemID {
                fileChangeMessageIDsByItemID[itemID] = message.id
            }
        case .plan:
            if let itemID = message.planUpdate?.itemID {
                planMessageIDsByItemID[itemID] = message.id
            }
        case .tool:
            if let itemID = message.toolCall?.itemID {
                toolCallMessageIDsByItemID[itemID] = message.id
            }
        case .notice:
            if let itemID = message.notice?.itemID {
                noticeMessageIDsByItemID[itemID] = message.id
            }
        case .reasoning:
            if let itemID = message.reasoningBlock?.itemID {
                reasoningMessageIDsByItemID[itemID] = message.id
            }
        case .user, .system:
            break
        }
    }

    private mutating func rebuildItemIndexes() {
        for message in messages {
            remember(message)
        }
    }

    private func index(for itemID: String, in index: [String: UUID]) -> Int? {
        guard let messageID = index[itemID] else { return nil }
        return messages.firstIndex(where: { $0.id == messageID })
    }
}
