import Foundation

public struct CodexCompletedWorkTrace: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case command
            case read
            case edit
            case tool
            case plan
            case reasoning
            case notice
        }

        public var id: String { kind.rawValue }
        public var kind: Kind
        public var title: String
        public var operations: [Operation]
        public var isCollapsedByDefault: Bool

        public init(
            kind: Kind,
            title: String,
            operations: [Operation],
            isCollapsedByDefault: Bool = true
        ) {
            self.kind = kind
            self.title = title
            self.operations = operations
            self.isCollapsedByDefault = isCollapsedByDefault
        }
    }

    public struct Operation: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        public var status: String
        public var isFailure: Bool
        public var isCollapsedByDefault: Bool
        public var message: CodexChatMessage

        public init(
            id: String,
            title: String,
            detail: String?,
            status: String,
            isFailure: Bool,
            isCollapsedByDefault: Bool = true,
            message: CodexChatMessage
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
            self.isFailure = isFailure
            self.isCollapsedByDefault = isCollapsedByDefault
            self.message = message
        }
    }

    public var id: String
    public var title: String
    public var groups: [Group]
    public var isCollapsedByDefault: Bool
    public var createdAt: Date

    public init(
        id: String,
        title: String,
        groups: [Group],
        isCollapsedByDefault: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.groups = groups
        self.isCollapsedByDefault = isCollapsedByDefault
        self.createdAt = createdAt
    }

    public static func project(from messages: [CodexChatMessage]) -> CodexCompletedWorkTrace? {
        let workMessages = messages.filter(\.isCompletedWorkTraceInput)
        guard !workMessages.isEmpty, workMessages.allSatisfy({ !$0.isStreaming }) else { return nil }

        let assistantEnd = messages.first { message in
            message.role == .assistant && !message.isStreaming
        }?.createdAt
        let start = workMessages.map(\.createdAt).min() ?? Date()
        let end = assistantEnd ?? workMessages.map(\.createdAt).max() ?? start
        let groups = projectedGroups(from: workMessages)
        guard !groups.isEmpty else { return nil }

        let firstID = workMessages.first?.id.uuidString ?? UUID().uuidString
        return CodexCompletedWorkTrace(
            id: "completed-work-\(firstID)-\(workMessages.count)",
            title: "Worked for \(durationLabel(seconds: Int(max(0, end.timeIntervalSince(start)).rounded())))",
            groups: groups,
            createdAt: start
        )
    }

    private static func projectedGroups(from messages: [CodexChatMessage]) -> [Group] {
        let commands = messages.compactMap(commandOperation)
        let reads = messages.compactMap(readOperation)
        let edits = messages.compactMap(editOperation)
        let tools = messages.compactMap(toolOperation)
        let plans = messages.compactMap(planOperation)
        let reasoning = messages.compactMap(reasoningOperation)
        let notices = messages.compactMap(noticeOperation)

        return [
            group(kind: .command, title: "Ran commands", operations: commands),
            group(kind: .read, title: "Read files", operations: reads),
            group(kind: .edit, title: "Edited files", operations: edits),
            group(kind: .tool, title: "Used tools", operations: tools),
            group(kind: .plan, title: "Updated plan", operations: plans),
            group(kind: .reasoning, title: "Reasoned", operations: reasoning),
            group(kind: .notice, title: "Notices", operations: notices)
        ].compactMap { $0 }
    }

    private static func group(kind: Group.Kind, title: String, operations: [Operation]) -> Group? {
        guard !operations.isEmpty else { return nil }
        return Group(kind: kind, title: title, operations: operations)
    }

    private static func commandOperation(from message: CodexChatMessage) -> Operation? {
        guard let run = message.commandRun else { return nil }
        return Operation(
            id: run.itemID,
            title: run.command,
            detail: run.output.traceNilIfBlank,
            status: commandStatus(run),
            isFailure: isFailedCommand(run),
            message: message
        )
    }

    private static func readOperation(from message: CodexChatMessage) -> Operation? {
        guard let tool = message.toolCall, isReadTool(tool) else { return nil }
        return Operation(
            id: tool.itemID,
            title: readTitle(for: tool),
            detail: tool.copyText.traceNilIfBlank,
            status: toolStatus(tool),
            isFailure: isFailedTool(tool),
            message: message
        )
    }

    private static func editOperation(from message: CodexChatMessage) -> Operation? {
        guard let change = message.fileChange else { return nil }
        return Operation(
            id: change.itemID,
            title: change.displayPath,
            detail: change.diff.traceNilIfBlank ?? change.output.traceNilIfBlank,
            status: change.status.traceNilIfBlank ?? "updated",
            isFailure: change.status.localizedCaseInsensitiveContains("fail"),
            message: message
        )
    }

    private static func toolOperation(from message: CodexChatMessage) -> Operation? {
        guard let tool = message.toolCall, !isReadTool(tool) else { return nil }
        return Operation(
            id: tool.itemID,
            title: tool.displayName,
            detail: tool.copyText.traceNilIfBlank,
            status: toolStatus(tool),
            isFailure: isFailedTool(tool),
            message: message
        )
    }

    private static func planOperation(from message: CodexChatMessage) -> Operation? {
        guard let plan = message.planUpdate else { return nil }
        return Operation(
            id: plan.itemID,
            title: "Plan",
            detail: plan.copyText.traceNilIfBlank,
            status: plan.summary,
            isFailure: false,
            message: message
        )
    }

    private static func reasoningOperation(from message: CodexChatMessage) -> Operation? {
        guard let block = message.reasoningBlock else { return nil }
        return Operation(
            id: block.itemID,
            title: block.title,
            detail: block.text.traceNilIfBlank,
            status: block.isStreaming ? "running" : "done",
            isFailure: false,
            message: message
        )
    }

    private static func noticeOperation(from message: CodexChatMessage) -> Operation? {
        guard let notice = message.notice else { return nil }
        return Operation(
            id: notice.itemID,
            title: notice.title,
            detail: notice.copyText.traceNilIfBlank,
            status: notice.statusLabel,
            isFailure: notice.severity == .danger,
            message: message
        )
    }

    private static func isReadTool(_ tool: CodexChatMessage.ToolCall) -> Bool {
        let name = tool.displayName.lowercased()
        return name.contains("read") || tool.progress.contains { $0.lowercased().hasPrefix("read ") }
    }

    private static func readTitle(for tool: CodexChatMessage.ToolCall) -> String {
        if let progress = tool.progress.first(where: { $0.lowercased().hasPrefix("read ") }) {
            return String(progress.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines).traceNilIfBlank ?? tool.displayName
        }
        return tool.result.trimmingCharacters(in: .whitespacesAndNewlines).traceNilIfBlank ?? tool.displayName
    }

    private static func commandStatus(_ run: CodexChatMessage.CommandRun) -> String {
        if let exitCode = run.exitCode { return exitCode == 0 ? "exit 0" : "exit \(exitCode)" }
        return run.status.traceNilIfBlank ?? "done"
    }

    private static func toolStatus(_ tool: CodexChatMessage.ToolCall) -> String {
        if isFailedTool(tool) { return "failed" }
        return tool.status.traceNilIfBlank ?? "done"
    }

    private static func isFailedCommand(_ run: CodexChatMessage.CommandRun) -> Bool {
        if let exitCode = run.exitCode { return exitCode != 0 }
        return run.status.localizedCaseInsensitiveContains("fail")
    }

    private static func isFailedTool(_ tool: CodexChatMessage.ToolCall) -> Bool {
        tool.error != nil || tool.status.localizedCaseInsensitiveContains("fail")
    }

    private static func durationLabel(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return "\(minutes)m " + String(format: "%02ds", remainder)
        }
        let hours = minutes / 60
        return "\(hours)h " + String(format: "%02dm %02ds", minutes % 60, remainder)
    }
}

private extension CodexChatMessage {
    var isCompletedWorkTraceInput: Bool {
        switch role {
        case .terminal:
            return commandRun != nil
        case .fileChange:
            return fileChange != nil
        case .tool:
            return toolCall != nil
        case .plan:
            return planUpdate != nil
        case .reasoning:
            return reasoningBlock != nil
        case .notice:
            return notice != nil
        case .assistant, .user, .system:
            return false
        }
    }
}

private extension String {
    var traceNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
