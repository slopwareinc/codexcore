import Foundation
import CodexCore

public enum CodexChatTranscriptProjection {
    public static func messages(for thread: CodexThreadSnapshot) -> [CodexChatMessage] {
        thread.turns.flatMap(messages(for:))
    }

    public static func messages(for turn: CodexTurnSnapshot) -> [CodexChatMessage] {
        turn.items.compactMap { item in
            message(for: item, detail: turn.itemDetails[item.id])
        } + turnStatusMessages(for: turn)
    }

    public static func message(forItemID itemID: String, in turn: CodexTurnSnapshot) -> CodexChatMessage? {
        guard let item = turn.items.first(where: { $0.id == itemID }) else { return nil }
        return message(for: item, detail: turn.itemDetails[item.id])
    }

    public static func message(
        for item: ThreadItem,
        fallbackStatus: String,
        createdAt: Date = Date()
    ) -> CodexChatMessage? {
        message(
            forRawItemID: item.id,
            type: item.type,
            raw: item.raw,
            fallbackStatus: fallbackStatus,
            createdAt: createdAt
        )
    }

    public static func message(
        forRawItemID itemID: String,
        type: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String,
        createdAt: Date = Date()
    ) -> CodexChatMessage? {
        let timelineItem = CodexTimelineItemMapper.timelineItem(
            id: itemID,
            type: type,
            raw: raw,
            fallbackStatus: fallbackStatus,
            createdAt: createdAt
        )
        let detail = CodexTimelineItemMapper.detail(
            id: itemID,
            type: type,
            raw: raw,
            fallbackStatus: fallbackStatus
        )
        return message(for: timelineItem, detail: detail)
    }

    public static func turnStatusMessages(for turn: CodexTurnSnapshot) -> [CodexChatMessage] {
        [turnPlanMessage(for: turn), turnDiffMessage(for: turn)].compactMap { $0 }
    }

    public static func turnPlanMessage(for turn: CodexTurnSnapshot) -> CodexChatMessage? {
        guard let plan = turn.plan, !plan.isEmpty else { return nil }
        let update = CodexChatMessage.PlanUpdate(
            itemID: "turn-plan-\(turn.id)",
            explanation: turn.planExplanation,
            steps: plan.map { CodexChatMessage.PlanUpdate.Step(step: $0.step, status: $0.status.rawValue) },
            isStreaming: turn.status == .running
        )
        return planMessage(update, createdAt: turn.startedAt)
    }

    public static func turnDiffMessage(for turn: CodexTurnSnapshot) -> CodexChatMessage? {
        guard let diff = turn.diff?.trimmedNonEmpty else { return nil }
        let isStreaming = turn.status == .running
        let change = CodexChatMessage.fileChange(
            itemID: "turn-diff-\(turn.id)",
            path: nil,
            diff: diff,
            kind: "turn diff",
            status: isStreaming ? "active" : "completed",
            isStreaming: isStreaming
        )
        return fileChangeMessage(change, createdAt: turn.completedAt ?? turn.startedAt)
    }

    public static func message(for item: CodexTimelineItem) -> CodexChatMessage? {
        message(for: item, detail: nil)
    }

    public static func message(
        for item: CodexTimelineItem,
        detail: CodexTimelineItemDetail?
    ) -> CodexChatMessage? {
        switch item {
        case .userMessage(_, let text, let timestamp):
            guard let text = text.trimmedNonEmpty else { return nil }
            return CodexChatMessage(role: .user, text: text, createdAt: timestamp)

        case .assistantMessage(_, let text, let timestamp, let isStreaming):
            guard let text = text.trimmedNonEmpty else { return nil }
            let phase: String?
            if case .assistantMessage(let detail)? = detail {
                phase = detail.phase
            } else {
                phase = nil
            }
            return CodexChatMessage(role: .assistant, text: text, detail: phase, isStreaming: isStreaming, createdAt: timestamp)

        case .reasoning(let id, let text, let timestamp, let isStreaming):
            let block = CodexChatMessage.reasoningBlock(
                itemID: id,
                text: text,
                isStreaming: isStreaming
            )
            return CodexChatMessage.reasoningMessage(block, createdAt: timestamp)

        case .toolCall(let id, let name, let arguments, let status, let timestamp):
            if case .toolCall(let detail)? = detail {
                var toolCall = toolCall(from: detail, itemID: id)
                if toolCall.arguments.isEmpty {
                    toolCall.arguments = arguments
                }
                return toolCallMessage(toolCall, createdAt: timestamp)
            }
            let toolCall = CodexChatMessage.toolCall(
                itemID: id,
                server: nil,
                tool: name.isEmpty ? "Tool" : name,
                arguments: arguments,
                status: status,
                isStreaming: isActiveStatus(status)
            )
            return toolCallMessage(toolCall, createdAt: timestamp)

        case .commandExecution(let id, let command, let output, let status, let timestamp):
            if case .commandExecution(let detail)? = detail {
                var run = commandRun(from: detail, itemID: id)
                if run.output.isEmpty {
                    run.output = output
                }
                if run.command == "Command", !command.isEmpty {
                    run.command = command
                }
                return commandMessage(run, createdAt: timestamp)
            }
            let run = CodexChatMessage.CommandRun(
                itemID: id,
                command: command.isEmpty ? "Command" : command,
                output: output,
                status: status,
                exitCode: nil,
                isStreaming: isActiveStatus(status)
            )
            return commandMessage(run, createdAt: timestamp)

        case .fileChange(let id, let path, let patch, let status, let timestamp):
            if case .fileChange(let detail)? = detail {
                var change = fileChange(from: detail, itemID: id)
                if change.path == nil {
                    change.path = path.trimmedNonEmpty
                }
                if change.diff.isEmpty {
                    change.diff = patch
                }
                return fileChangeMessage(change, createdAt: timestamp)
            }
            let change = CodexChatMessage.fileChange(
                itemID: id,
                path: path.trimmedNonEmpty,
                diff: patch,
                status: status,
                isStreaming: isActiveStatus(status)
            )
            return fileChangeMessage(change, createdAt: timestamp)

        case .mcpToolCall(let id, let server, let tool, let status, let timestamp, let progress):
            if case .toolCall(let detail)? = detail {
                var toolCall = toolCall(from: detail, itemID: id)
                if toolCall.server == nil {
                    toolCall.server = server.trimmedNonEmpty
                }
                if toolCall.tool == "Tool", let tool = tool.trimmedNonEmpty {
                    toolCall.tool = tool
                }
                if toolCall.progress.isEmpty {
                    toolCall.progress = progress
                }
                return toolCallMessage(toolCall, createdAt: timestamp)
            }
            let toolCall = CodexChatMessage.toolCall(
                itemID: id,
                server: server.trimmedNonEmpty,
                tool: tool.trimmedNonEmpty ?? "Tool",
                status: status,
                progress: progress,
                isStreaming: isActiveStatus(status)
            )
            return toolCallMessage(toolCall, createdAt: timestamp)

        case .warning(let id, let text, let timestamp):
            let notice = CodexChatMessage.Notice(
                itemID: id,
                kind: "warning",
                title: "Warning",
                detail: text,
                severity: .warning
            )
            return CodexChatMessage(
                role: .notice,
                text: notice.copyText,
                createdAt: timestamp,
                parseContent: false,
                notice: notice
            )
        }
    }

    public static func commandRun(
        from detail: CodexCommandExecutionDetail,
        itemID: String
    ) -> CodexChatMessage.CommandRun {
        CodexChatMessage.CommandRun(
            itemID: itemID,
            command: detail.command,
            cwd: detail.cwd,
            output: detail.output,
            status: detail.status,
            exitCode: detail.exitCode,
            isStreaming: isActiveStatus(detail.status)
        )
    }

    public static func fileChange(
        from detail: CodexFileChangeDetail,
        itemID: String
    ) -> CodexChatMessage.FileChange {
        CodexChatMessage.fileChange(
            itemID: itemID,
            path: detail.path,
            diff: detail.diff,
            kind: detail.kind,
            output: detail.output,
            status: detail.status,
            isStreaming: isActiveStatus(detail.status)
        )
    }

    public static func toolCall(
        from detail: CodexToolCallDetail,
        itemID: String
    ) -> CodexChatMessage.ToolCall {
        CodexChatMessage.toolCall(
            itemID: itemID,
            server: detail.server,
            tool: detail.tool,
            arguments: detail.arguments,
            status: detail.status,
            progress: detail.progress,
            result: detail.result,
            error: detail.error,
            durationMilliseconds: detail.durationMilliseconds,
            isStreaming: isActiveStatus(detail.status)
        )
    }

    public static func commandMessage(
        _ run: CodexChatMessage.CommandRun,
        createdAt: Date = Date()
    ) -> CodexChatMessage {
        CodexChatMessage(
            role: .terminal,
            text: run.output,
            isStreaming: run.isStreaming,
            createdAt: createdAt,
            parseContent: false,
            commandRun: run
        )
    }

    public static func fileChangeMessage(
        _ change: CodexChatMessage.FileChange,
        createdAt: Date = Date()
    ) -> CodexChatMessage {
        CodexChatMessage(
            role: .fileChange,
            text: change.diff.isEmpty ? change.output : change.diff,
            isStreaming: change.isStreaming,
            createdAt: createdAt,
            parseContent: false,
            fileChange: change
        )
    }

    public static func planMessage(
        _ plan: CodexChatMessage.PlanUpdate,
        createdAt: Date = Date()
    ) -> CodexChatMessage {
        CodexChatMessage(
            role: .plan,
            text: plan.copyText,
            isStreaming: plan.isStreaming,
            createdAt: createdAt,
            parseContent: false,
            planUpdate: plan
        )
    }

    public static func toolCallMessage(
        _ toolCall: CodexChatMessage.ToolCall,
        createdAt: Date = Date()
    ) -> CodexChatMessage {
        CodexChatMessage(
            role: .tool,
            text: toolCall.copyText,
            isStreaming: toolCall.isStreaming,
            createdAt: createdAt,
            parseContent: false,
            toolCall: toolCall
        )
    }

    public static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string.trimmedNonEmpty
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values):
            return values.compactMap(string(from:)).joined(separator: " ").trimmedNonEmpty
        case .dictionary(let object):
            if let text = string(from: object["text"]) { return text }
            if let value = string(from: object["value"]) { return value }
            return nil
        case .null, nil:
            return nil
        }
    }

    public static func verbatimString(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string.isEmpty ? nil : string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        case .array(let values):
            let text = values.compactMap(verbatimString(from:)).joined(separator: " ")
            return text.isEmpty ? nil : text
        case .dictionary(let object):
            return verbatimString(from: object["text"]) ?? verbatimString(from: object["value"])
        case .null, nil:
            return nil
        }
    }

    public static func isActiveStatus(_ status: String) -> Bool {
        CodexStatusHeuristics.isActiveStreaming(status)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
