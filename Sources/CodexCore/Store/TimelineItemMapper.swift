import Foundation

public struct CodexTurnPlanDetail: Sendable, Equatable {
    public var plan: [TurnPlanStep]
    public var explanation: String?

    public init(plan: [TurnPlanStep], explanation: String? = nil) {
        self.plan = plan
        self.explanation = explanation
    }
}

public enum CodexTimelineItemMapper {
    public static func timelineItem(
        for item: ThreadItem,
        fallbackStatus: String,
        createdAt: Date = Date()
    ) -> CodexTimelineItem {
        timelineItem(
            id: item.id,
            type: item.type,
            raw: item.raw,
            fallbackStatus: fallbackStatus,
            createdAt: createdAt
        )
    }

    public static func detail(
        for item: ThreadItem,
        fallbackStatus: String
    ) -> CodexTimelineItemDetail? {
        detail(id: item.id, type: item.type, raw: item.raw, fallbackStatus: fallbackStatus)
    }

    public static func timelineItem(
        id: String,
        type: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String,
        createdAt: Date = Date()
    ) -> CodexTimelineItem {
        timelineItem(
            for: serverItem(id: id, type: type, raw: raw, fallbackStatus: fallbackStatus),
            createdAt: createdAt
        )
    }

    public static func detail(
        id: String,
        type: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String
    ) -> CodexTimelineItemDetail? {
        detail(for: serverItem(id: id, type: type, raw: raw, fallbackStatus: fallbackStatus))
    }

    public static func timelineItem(
        for item: CodexServerItem,
        createdAt: Date = Date()
    ) -> CodexTimelineItem {
        let status = item.status ?? string(item.raw["status"]) ?? "completed"
        switch item.type {
        case "userMessage":
            return .userMessage(id: item.id, text: userMessageText(from: item.raw) ?? "", timestamp: createdAt)

        case "assistantMessage", "agentMessage":
            let text = string(item.raw["text"]) ?? ""
            return .assistantMessage(id: item.id, text: text, timestamp: createdAt, isStreaming: isActiveStatus(status))

        case "reasoning":
            let text = string(item.raw["text"]) ?? ""
            return .reasoning(id: item.id, text: text, timestamp: createdAt, isStreaming: isActiveStatus(status))

        case "toolCall":
            let name = string(item.raw["name"]) ?? ""
            let args = jsonText(item.raw["arguments"]) ?? string(item.raw["arguments"]) ?? ""
            return .toolCall(id: item.id, name: name, arguments: args, status: status, timestamp: createdAt)

        case "commandExecution":
            let command = commandText(item.raw["command"]) ?? string(item.raw["cmd"]) ?? string(item.raw["name"]) ?? ""
            let output = verbatimString(item.raw["aggregatedOutput"])
                ?? verbatimString(item.raw["output"])
                ?? verbatimString(item.raw["stdout"])
                ?? verbatimStrings(item.raw["outputs"]).joined(separator: "\n")
            return .commandExecution(id: item.id, command: command, output: output, status: status, timestamp: createdAt)

        case "fileChange", "patch":
            let changes = fileUpdateChanges(item.raw["changes"])
            let path = string(item.raw["path"]) ?? changes.first?.path ?? ""
            let patch = string(item.raw["patch"])
                ?? string(item.raw["diff"])
                ?? string(item.raw["unified_diff"])
                ?? changes.map(\.diff).filter { !$0.isEmpty }.joined(separator: "\n")
            return .fileChange(id: item.id, path: path, patch: patch, status: status, timestamp: createdAt)

        case "mcpToolCall":
            let server = string(item.raw["serverName"]) ?? string(item.raw["server"]) ?? ""
            let tool = string(item.raw["toolName"]) ?? string(item.raw["tool"]) ?? ""
            return .mcpToolCall(id: item.id, server: server, tool: tool, status: status, timestamp: createdAt, progress: progressMessages(item.raw))

        default:
            return .warning(id: item.id, text: "Notice: \(item.type) item completed with status \(status)", timestamp: createdAt)
        }
    }

    public static func detail(for item: CodexServerItem) -> CodexTimelineItemDetail? {
        let status = item.status ?? string(item.raw["status"]) ?? "completed"
        switch item.type {
        case "assistantMessage", "agentMessage":
            guard let phase = string(item.raw["phase"]) else { return nil }
            return .assistantMessage(CodexAssistantMessageDetail(phase: phase))
        case "commandExecution":
            return .commandExecution(CodexCommandExecutionDetail(
                command: commandText(item.raw["command"]) ?? string(item.raw["cmd"]) ?? string(item.raw["name"]) ?? "Command",
                cwd: string(item.raw["cwd"]),
                output: verbatimString(item.raw["aggregatedOutput"])
                    ?? verbatimString(item.raw["output"])
                    ?? verbatimString(item.raw["stdout"])
                    ?? verbatimStrings(item.raw["outputs"]).joined(separator: "\n"),
                status: status,
                exitCode: int(item.raw["exitCode"])
            ))
        case "fileChange", "patch":
            let changes = fileUpdateChanges(item.raw["changes"])
            let diff = string(item.raw["diff"])
                ?? string(item.raw["patch"])
                ?? string(item.raw["unified_diff"])
                ?? changes.map(\.diff).filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty
                ?? ""
            let output = string(item.raw["output"]) ?? string(item.raw["delta"]) ?? string(item.raw["aggregatedOutput"]) ?? ""
            let path = string(item.raw["path"]) ?? changes.first?.path
            let kind = string(item.raw["kind"]) ?? changes.first?.kind ?? string(item.raw["type"]) ?? "update"
            guard path != nil || !diff.isEmpty || !output.isEmpty else { return nil }
            return .fileChange(CodexFileChangeDetail(path: path, kind: kind, diff: diff, output: output, status: status))
        case "mcpToolCall", "toolCall":
            let server = string(item.raw["server"]) ?? string(item.raw["serverName"]) ?? string(item.raw["mcpServer"])
            let tool = string(item.raw["tool"]) ?? string(item.raw["toolName"]) ?? string(item.raw["name"]) ?? "Tool"
            let detail = CodexToolCallDetail(
                server: server,
                tool: tool,
                arguments: jsonText(item.raw["arguments"]) ?? "",
                status: status,
                progress: progressMessages(item.raw),
                result: resultText(item.raw["result"]) ?? resultText(item.raw["output"]) ?? resultText(item.raw["content"]) ?? "",
                error: errorText(item.raw["error"]),
                durationMilliseconds: int(item.raw["durationMs"]) ?? int(item.raw["durationMilliseconds"])
            )
            guard detail.server != nil || detail.tool != "Tool" || !detail.arguments.isEmpty || !detail.result.isEmpty || detail.error != nil || !detail.progress.isEmpty else {
                return nil
            }
            return .toolCall(detail)
        default:
            return nil
        }
    }

    public static func turnPlan(from raw: [String: CodexJSONValue]) -> CodexTurnPlanDetail? {
        let plan = planSteps(raw["plan"]) + planSteps(raw["steps"])
        let explanation = string(raw["explanation"])
        guard !plan.isEmpty || explanation != nil else { return nil }
        return CodexTurnPlanDetail(plan: plan, explanation: explanation)
    }

    private static func serverItem(
        id: String,
        type: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String
    ) -> CodexServerItem {
        var raw = raw
        raw["id"] = raw["id"] ?? .string(id)
        raw["type"] = raw["type"] ?? .string(type)
        if raw["status"] == nil {
            raw["status"] = .string(fallbackStatus)
        }
        return CodexServerItem(
            id: id,
            type: type,
            status: string(raw["status"]) ?? fallbackStatus,
            raw: raw
        )
    }
}

private struct CodexFileUpdateChange {
    var path: String?
    var kind: String?
    var diff: String
}

private func userMessageText(from raw: [String: CodexJSONValue]) -> String? {
    if let text = string(raw["text"]) {
        return text
    }
    guard case .array(let parts)? = raw["content"] else { return nil }
    return parts.compactMap { part -> String? in
        guard case .dictionary(let object) = part else { return string(part) }
        return string(object["text"]) ?? string(object["content"])
    }
    .joined(separator: "\n")
    .nilIfEmpty
}

private func fileUpdateChanges(_ value: CodexJSONValue?) -> [CodexFileUpdateChange] {
    guard case .array(let values)? = value else { return [] }
    return values.compactMap { value in
        guard case .dictionary(let raw) = value else { return nil }
        let diff = string(raw["diff"]) ?? string(raw["unified_diff"]) ?? string(raw["patch"]) ?? ""
        guard raw["path"] != nil || !diff.isEmpty else { return nil }
        return CodexFileUpdateChange(path: string(raw["path"]), kind: string(raw["kind"]) ?? string(raw["type"]), diff: diff)
    }
}

private func progressMessages(_ raw: [String: CodexJSONValue]) -> [String] {
    var messages = strings(raw["progress"])
    if let message = string(raw["message"]) {
        messages.append(message)
    }
    return messages
}

private func planSteps(_ value: CodexJSONValue?) -> [TurnPlanStep] {
    guard case .array(let values)? = value else { return [] }
    return values.compactMap { value in
        guard case .dictionary(let raw) = value else { return nil }
        guard let step = string(raw["step"]) ?? string(raw["text"]) ?? string(raw["title"]) else {
            return nil
        }
        let status = string(raw["status"]).flatMap(TurnPlanStepStatus.init(rawValue:)) ?? .pending
        return TurnPlanStep(step: step, status: status)
    }
}

private func resultText(_ value: CodexJSONValue?) -> String? {
    switch value {
    case .string(let string):
        return nilIfEmpty(string)
    case .int(let int):
        return String(int)
    case .double(let double):
        return String(double)
    case .bool(let bool):
        return String(bool)
    case .array(let values):
        return values.compactMap(resultText).joined(separator: "\n").nilIfEmpty
    case .dictionary(let object):
        if let text = string(object["text"]) { return text }
        if let value = resultText(object["value"]) { return value }
        if let content = resultText(object["content"]) { return content }
        return jsonText(value)
    case .null, nil:
        return nil
    }
}

private func errorText(_ value: CodexJSONValue?) -> String? {
    switch value {
    case .dictionary(let object):
        return string(object["message"]) ?? string(object["text"]) ?? string(object["error"])
    default:
        return string(value)
    }
}

private func jsonText(_ value: CodexJSONValue?) -> String? {
    guard let value else { return nil }
    let object = value.rawValue
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return string(value)
    }
    return text
}

private func commandText(_ value: CodexJSONValue?) -> String? {
    switch value {
    case .array(let values):
        return values.compactMap(string).joined(separator: " ").nilIfEmpty
    default:
        return string(value)
    }
}

private func string(_ value: CodexJSONValue?) -> String? {
    switch value {
    case .string(let string):
        return nilIfEmpty(string)
    case .int(let int):
        return String(int)
    case .double(let double):
        return String(double)
    case .bool(let bool):
        return String(bool)
    case .array(let values):
        return values.compactMap(string).joined(separator: " ").nilIfEmpty
    case .dictionary(let object):
        return string(object["type"]) ?? string(object["text"]) ?? string(object["value"])
    case .null, nil:
        return nil
    }
}

private func strings(_ value: CodexJSONValue?) -> [String] {
    switch value {
    case .array(let values):
        return values.compactMap(string)
    case let value?:
        return string(value).map { [$0] } ?? []
    case nil:
        return []
    }
}

private func verbatimString(_ value: CodexJSONValue?) -> String? {
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
        return values.compactMap(verbatimString).joined(separator: " ").nilIfEmpty
    case .dictionary(let object):
        return verbatimString(object["text"]) ?? verbatimString(object["value"])
    case .null, nil:
        return nil
    }
}

private func verbatimStrings(_ value: CodexJSONValue?) -> [String] {
    switch value {
    case .array(let values):
        return values.flatMap(verbatimStrings)
    case let value?:
        return verbatimString(value).map { [$0] } ?? []
    case nil:
        return []
    }
}

private func int(_ value: CodexJSONValue?) -> Int? {
    switch value {
    case .int(let int):
        return int
    case .double(let double):
        return Int(double)
    case .string(let string):
        return Int(string)
    case .bool, .array, .dictionary, .null, nil:
        return nil
    }
}

private func isActiveStatus(_ status: String) -> Bool {
    CodexStatusHeuristics.isActiveStreaming(status)
}

private func nilIfEmpty(_ string: String?) -> String? {
    string?.isEmpty == false ? string : nil
}
