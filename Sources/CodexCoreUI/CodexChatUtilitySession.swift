import Foundation

public struct CodexChatStatusSummaryContext: Equatable, Sendable {
    public var connectionLabel: String
    public var workspacePath: String
    public var currentThreadID: String?
    public var modelDisplayName: String
    public var reasoningDisplayName: String
    public var approvalDisplayName: String
    public var messageCount: Int
    public var isSideChatOpen: Bool
    public var activeSubagentCount: Int
    public var subagentCount: Int

    public init(
        connectionLabel: String,
        workspacePath: String,
        currentThreadID: String?,
        modelDisplayName: String,
        reasoningDisplayName: String,
        approvalDisplayName: String,
        messageCount: Int,
        isSideChatOpen: Bool,
        activeSubagentCount: Int,
        subagentCount: Int
    ) {
        self.connectionLabel = connectionLabel
        self.workspacePath = workspacePath
        self.currentThreadID = currentThreadID
        self.modelDisplayName = modelDisplayName
        self.reasoningDisplayName = reasoningDisplayName
        self.approvalDisplayName = approvalDisplayName
        self.messageCount = messageCount
        self.isSideChatOpen = isSideChatOpen
        self.activeSubagentCount = activeSubagentCount
        self.subagentCount = subagentCount
    }
}

public enum CodexChatUtilitySession {
    public static func transcriptText(messages: [CodexChatMessage]) -> String {
        messages.map { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = text.isEmpty ? (message.commandRun?.command ?? "") : text
            return "\(message.role.rawValue): \(content)"
        }
        .joined(separator: "\n\n")
    }

    public static func copiedTranscriptActivityDetail(messageCount: Int) -> String {
        messageCount == 0 ? "No transcript text yet" : "\(messageCount) messages copied"
    }

    public static func statusSummary(_ context: CodexChatStatusSummaryContext) -> String {
        [
            "Connection: \(context.connectionLabel)",
            "Project: \(context.workspacePath)",
            "Chat: \(context.currentThreadID ?? "preparing")",
            "Model: \(context.modelDisplayName) \(context.reasoningDisplayName)",
            "Approval: \(context.approvalDisplayName)",
            "Messages: \(context.messageCount)",
            "Side chat: \(context.isSideChatOpen ? "open" : "closed")",
            "Subagents: \(context.activeSubagentCount) active / \(context.subagentCount) total"
        ].joined(separator: "\n")
    }
}
