import Foundation
import CodexCore

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
    public var tokenUsageSummary: String?
    public var rateLimitSummary: String?
    public var gitBranch: String?

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
        subagentCount: Int,
        tokenUsageSummary: String? = nil,
        rateLimitSummary: String? = nil,
        gitBranch: String? = nil
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
        self.tokenUsageSummary = tokenUsageSummary
        self.rateLimitSummary = rateLimitSummary
        self.gitBranch = gitBranch
    }
}

public enum CodexChatUtilitySession {
    public static func transcriptText(transcript: CodexTranscriptV2) -> String {
        transcript.turns.flatMap { turn in
            [turn.userMessage.map { "You: \($0.text)" }, turn.finalAnswer.map { "Codex: \($0.text)" }].compactMap { $0 }
        }.joined(separator: "\n\n")
    }

    public static func copiedTranscriptActivityDetail(messageCount: Int) -> String {
        messageCount == 0 ? "No transcript text yet" : "\(messageCount) messages copied"
    }

    public static func tokenUsageSummary(_ usage: ThreadTokenUsage) -> String {
        CodexNotificationPresentation.tokenUsageSummary(usage)
    }

    public static func statusSummary(_ context: CodexChatStatusSummaryContext) -> String {
        var lines = [
            "Connection: \(context.connectionLabel)",
            "Project: \(context.workspacePath)",
            "Chat: \(context.currentThreadID ?? "preparing")",
            "Model: \(context.modelDisplayName) \(context.reasoningDisplayName)",
            "Approval: \(context.approvalDisplayName)",
            "Messages: \(context.messageCount)",
            "Side chat: \(context.isSideChatOpen ? "open" : "closed")",
            "Subagents: \(context.activeSubagentCount) active / \(context.subagentCount) total"
        ]
        if let gitBranch = context.gitBranch, !gitBranch.isEmpty {
            lines.insert("Branch: \(gitBranch)", at: 2)
        }
        if let tokenUsageSummary = context.tokenUsageSummary {
            lines.append("Tokens: \(tokenUsageSummary)")
        }
        if let rateLimitSummary = context.rateLimitSummary {
            lines.append("Rate limits: \(rateLimitSummary)")
        }
        return lines.joined(separator: "\n")
    }
}
