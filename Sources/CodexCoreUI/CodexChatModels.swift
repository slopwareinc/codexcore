import Foundation
import CodexCore

public struct CodexChatActionHandlers {
    public var renameChat: (() -> Void)?
    public var archiveChat: (() -> Void)?
    public var openSideChat: (() -> Void)?
    public var copyChat: (() -> Void)?
    public var forkChat: (() -> Void)?

    public init(
        renameChat: (() -> Void)? = nil,
        archiveChat: (() -> Void)? = nil,
        openSideChat: (() -> Void)? = nil,
        copyChat: (() -> Void)? = nil,
        forkChat: (() -> Void)? = nil
    ) {
        self.renameChat = renameChat
        self.archiveChat = archiveChat
        self.openSideChat = openSideChat
        self.copyChat = copyChat
        self.forkChat = forkChat
    }
}

public struct CodexChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user = "You"
        case assistant = "Codex"
        case terminal = "Terminal"
        case fileChange = "File change"
        case plan = "Plan"
        case tool = "Tool"
        case notice = "Notice"
        case system = "System"
    }

    public struct CommandRun: Equatable, Sendable {
        public var itemID: String
        public var command: String
        public var cwd: String?
        public var output: String
        public var status: String
        public var exitCode: Int?
        public var isStreaming: Bool

        public init(
            itemID: String,
            command: String,
            cwd: String? = nil,
            output: String,
            status: String,
            exitCode: Int? = nil,
            isStreaming: Bool
        ) {
            self.itemID = itemID
            self.command = command
            self.cwd = cwd
            self.output = output
            self.status = status
            self.exitCode = exitCode
            self.isStreaming = isStreaming
        }
    }

    public struct FileChange: Equatable, Sendable {
        public var itemID: String
        public var path: String?
        public var kind: String
        public var diff: String
        public var output: String
        public var status: String
        public var isStreaming: Bool

        public init(
            itemID: String,
            path: String? = nil,
            kind: String = "update",
            diff: String = "",
            output: String = "",
            status: String = "active",
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.path = path
            self.kind = kind
            self.diff = diff
            self.output = output
            self.status = status
            self.isStreaming = isStreaming
        }

        public var displayPath: String {
            path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "File changes"
        }

        public var changedFileCount: Int {
            guard !diff.isEmpty else { return path == nil ? 0 : 1 }
            let lines = diff.split(whereSeparator: \.isNewline)
            let gitHeaders = lines.compactMap { line -> String? in
                if line.hasPrefix("diff --git ") {
                    return String(line)
                }
                return nil
            }
            let fileHeaders = gitHeaders.isEmpty ? lines.compactMap { line -> String? in
                if line.hasPrefix("+++ ") {
                    let newPath = line.dropFirst(4)
                    return newPath == "/dev/null" ? nil : String(newPath)
                }
                return nil
            } : gitHeaders
            let count = Set(fileHeaders).count
            return max(path == nil ? 0 : 1, count)
        }

        public var addedLineCount: Int {
            diff.split(whereSeparator: \.isNewline).filter { line in
                line.hasPrefix("+") && !line.hasPrefix("+++")
            }.count
        }

        public var removedLineCount: Int {
            diff.split(whereSeparator: \.isNewline).filter { line in
                line.hasPrefix("-") && !line.hasPrefix("---")
            }.count
        }
    }

    public struct PlanUpdate: Equatable, Sendable {
        public struct Step: Equatable, Sendable {
            public var step: String
            public var status: String

            public init(step: String, status: String) {
                self.step = step
                self.status = status
            }

            public var displayStatus: String {
                status.replacingOccurrences(of: "_", with: " ")
            }

            public var isCompleted: Bool {
                status == "completed"
            }

            public var isActive: Bool {
                status == "inProgress" || status == "in_progress" || status == "active" || status == "running"
            }
        }

        public var itemID: String
        public var explanation: String?
        public var steps: [Step]
        public var text: String
        public var isStreaming: Bool

        public init(
            itemID: String,
            explanation: String? = nil,
            steps: [Step] = [],
            text: String = "",
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.explanation = explanation
            self.steps = steps
            self.text = text
            self.isStreaming = isStreaming
        }

        public var completedStepCount: Int {
            steps.filter(\.isCompleted).count
        }

        public var activeStepCount: Int {
            steps.filter(\.isActive).count
        }

        public var summary: String {
            if steps.isEmpty {
                return isStreaming ? "Planning" : "Plan"
            }
            if completedStepCount == steps.count {
                return "Completed \(steps.count)/\(steps.count)"
            }
            return "\(completedStepCount)/\(steps.count) complete"
        }

        public var copyText: String {
            var lines: [String] = []
            if let explanation, !explanation.isEmpty {
                lines.append(explanation)
            }
            if !steps.isEmpty {
                lines.append(contentsOf: steps.map { "- [\($0.displayStatus)] \($0.step)" })
            } else if !text.isEmpty {
                lines.append(text)
            }
            return lines.joined(separator: "\n")
        }
    }

    public struct ToolCall: Equatable, Sendable {
        public var itemID: String
        public var server: String?
        public var tool: String
        public var arguments: String
        public var status: String
        public var progress: [String]
        public var result: String
        public var error: String?
        public var durationMilliseconds: Int?
        public var isStreaming: Bool

        public init(
            itemID: String,
            server: String? = nil,
            tool: String,
            arguments: String = "",
            status: String = "inProgress",
            progress: [String] = [],
            result: String = "",
            error: String? = nil,
            durationMilliseconds: Int? = nil,
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.server = server
            self.tool = tool
            self.arguments = arguments
            self.status = status
            self.progress = progress
            self.result = result
            self.error = error
            self.durationMilliseconds = durationMilliseconds
            self.isStreaming = isStreaming
        }

        public var displayName: String {
            guard let server, !server.isEmpty else { return tool }
            return "\(server).\(tool)"
        }

        public var summary: String {
            if let error, !error.isEmpty { return error }
            if !result.isEmpty { return result }
            if let lastProgress = progress.last, !lastProgress.isEmpty { return lastProgress }
            return isStreaming ? "Calling tool" : status
        }

        public var copyText: String {
            var parts: [String] = []
            if !arguments.isEmpty { parts.append("Arguments:\n\(arguments)") }
            if !progress.isEmpty { parts.append("Progress:\n\(progress.joined(separator: "\n"))") }
            if !result.isEmpty { parts.append("Result:\n\(result)") }
            if let error, !error.isEmpty { parts.append("Error:\n\(error)") }
            return parts.joined(separator: "\n\n")
        }
    }

    public struct Notice: Equatable, Sendable {
        public enum Severity: String, Equatable, Sendable {
            case info
            case success
            case warning
            case danger
        }

        public var itemID: String
        public var kind: String
        public var title: String
        public var detail: String
        public var status: String?
        public var metadata: [String]
        public var severity: Severity
        public var isStreaming: Bool

        public init(
            itemID: String,
            kind: String,
            title: String,
            detail: String,
            status: String? = nil,
            metadata: [String] = [],
            severity: Severity = .info,
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.kind = kind
            self.title = title
            self.detail = detail
            self.status = status
            self.metadata = metadata
            self.severity = severity
            self.isStreaming = isStreaming
        }

        public var copyText: String {
            ([title, detail] + metadata).filter { !$0.isEmpty }.joined(separator: "\n")
        }

        public var statusLabel: String {
            if isStreaming { return "running" }
            return status?.replacingOccurrences(of: "_", with: " ") ?? severity.rawValue
        }
    }

    public let id: UUID
    public var role: Role
    public var text: String
    public var detail: String?
    public var isStreaming: Bool
    public var createdAt: Date
    public var renderBlocks: [AssistantRenderBlock]
    public var commandRun: CommandRun?
    public var fileChange: FileChange?
    public var planUpdate: PlanUpdate?
    public var toolCall: ToolCall?
    public var notice: Notice?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        detail: String? = nil,
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        parseContent: Bool = true,
        renderBlocks: [AssistantRenderBlock]? = nil,
        commandRun: CommandRun? = nil,
        fileChange: FileChange? = nil,
        planUpdate: PlanUpdate? = nil,
        toolCall: ToolCall? = nil,
        notice: Notice? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.renderBlocks = renderBlocks ?? (parseContent ? Self.renderBlocks(for: text) : [.markdown(text)])
        self.commandRun = commandRun
        self.fileChange = fileChange
        self.planUpdate = planUpdate
        self.toolCall = toolCall
        self.notice = notice
    }

    public mutating func setText(_ text: String, parseContent: Bool = true) {
        self.text = text
        renderBlocks = parseContent ? Self.renderBlocks(for: text) : [.markdown(text)]
    }

    public mutating func appendStreamingText(_ delta: String) {
        text.append(delta)
    }

    public static func renderBlocks(for text: String) -> [AssistantRenderBlock] {
        MessageContentBridge.assistantRenderBlocks(text)
    }

    public static func fileChange(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String = "completed"
    ) -> FileChange? {
        let changes = fileUpdateChanges(from: raw["changes"])
        let changesDiff = changes.map(\.diff).filter { !$0.isEmpty }.joined(separator: "\n").nilIfBlank
        let path = string(from: raw["path"])
            ?? changes.first?.path
            ?? firstFileChangePath(from: raw["fileChanges"])
        let kind = string(from: raw["kind"])
            ?? changes.first?.kind
            ?? firstFileChangeKind(from: raw["fileChanges"])
            ?? string(from: raw["type"])
            ?? "update"
        let diff = string(from: raw["diff"])
            ?? string(from: raw["patch"])
            ?? string(from: raw["unified_diff"])
            ?? changesDiff
            ?? fileChangesDiff(from: raw["fileChanges"])
            ?? ""
        let output = string(from: raw["output"])
            ?? string(from: raw["delta"])
            ?? string(from: raw["aggregatedOutput"])
            ?? ""
        let status = string(from: raw["status"]) ?? fallbackStatus
        let isStreaming = status == "active" || status == "inProgress" || status == "running"

        guard path != nil || !diff.isEmpty || !output.isEmpty else { return nil }
        return FileChange(
            itemID: itemID,
            path: path,
            kind: kind,
            diff: diff,
            output: output,
            status: status,
            isStreaming: isStreaming
        )
    }

    public static func fileChange(
        itemID: String,
        path: String?,
        diff: String,
        kind: String = "update",
        output: String = "",
        status: String = "active",
        isStreaming: Bool = true
    ) -> FileChange {
        FileChange(
            itemID: itemID,
            path: path,
            kind: kind,
            diff: diff,
            output: output,
            status: status,
            isStreaming: isStreaming
        )
    }

    public static func planUpdate(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackText: String = "",
        isStreaming: Bool = false
    ) -> PlanUpdate? {
        let explanation = string(from: raw["explanation"])
        let steps = planSteps(from: raw["plan"]) + planSteps(from: raw["steps"])
        let text = string(from: raw["delta"])
            ?? string(from: raw["text"])
            ?? string(from: raw["summary"])
            ?? fallbackText.nilIfBlank
            ?? ""
        guard explanation != nil || !steps.isEmpty || !text.isEmpty else { return nil }
        return PlanUpdate(
            itemID: itemID,
            explanation: explanation,
            steps: steps,
            text: text,
            isStreaming: isStreaming
        )
    }

    public static func planUpdate(
        itemID: String,
        text: String,
        isStreaming: Bool = true
    ) -> PlanUpdate {
        PlanUpdate(itemID: itemID, text: text, isStreaming: isStreaming)
    }

    public static func toolCall(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String = "inProgress"
    ) -> ToolCall? {
        let server = string(from: raw["server"])
            ?? string(from: raw["serverName"])
            ?? string(from: raw["mcpServer"])
        let tool = string(from: raw["tool"])
            ?? string(from: raw["toolName"])
            ?? string(from: raw["name"])
            ?? "Tool"
        let arguments = jsonText(from: raw["arguments"]) ?? ""
        let status = string(from: raw["status"]) ?? fallbackStatus
        let progress = progressMessages(from: raw)
        let result = resultText(from: raw["result"])
            ?? resultText(from: raw["output"])
            ?? resultText(from: raw["content"])
            ?? ""
        let error = errorText(from: raw["error"])
        let duration = int(from: raw["durationMs"]) ?? int(from: raw["durationMilliseconds"])
        let isStreaming = status == "inProgress" || status == "active" || status == "running"

        guard server != nil || tool != "Tool" || !arguments.isEmpty || !result.isEmpty || error != nil || !progress.isEmpty else {
            return nil
        }

        return ToolCall(
            itemID: itemID,
            server: server,
            tool: tool,
            arguments: arguments,
            status: status,
            progress: progress,
            result: result,
            error: error,
            durationMilliseconds: duration,
            isStreaming: isStreaming
        )
    }

    public static func toolCall(
        itemID: String,
        server: String?,
        tool: String,
        arguments: String = "",
        status: String = "inProgress",
        progress: [String] = [],
        result: String = "",
        error: String? = nil,
        durationMilliseconds: Int? = nil,
        isStreaming: Bool = true
    ) -> ToolCall {
        ToolCall(
            itemID: itemID,
            server: server,
            tool: tool,
            arguments: arguments,
            status: status,
            progress: progress,
            result: result,
            error: error,
            durationMilliseconds: durationMilliseconds,
            isStreaming: isStreaming
        )
    }

    public static func notice(
        itemID: String,
        method: CodexAppServerNotificationMethod,
        raw: [String: CodexJSONValue],
        isStreaming: Bool? = nil
    ) -> Notice? {
        switch method {
        case .modelRerouted:
            let fromModel = string(from: raw["fromModel"]) ?? "selected model"
            let toModel = string(from: raw["toModel"]) ?? "alternate model"
            let reason = string(from: raw["reason"])
            let detail = "\(fromModel) -> \(toModel)"
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Model rerouted",
                detail: detail,
                metadata: reason.map { ["Reason: \(humanize($0))"] } ?? [],
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .modelVerification:
            let verifications = stringArray(from: raw["verifications"]).map(humanize)
            let detail = verifications.isEmpty ? "Model verification updated" : verifications.joined(separator: ", ")
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Model verification",
                detail: detail,
                metadata: verifications.map { "Verified: \($0)" },
                severity: .info,
                isStreaming: isStreaming ?? false
            )

        case .warning:
            guard let message = string(from: raw["message"]) else { return nil }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Warning",
                detail: message,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .guardianWarning:
            guard let message = string(from: raw["message"]) else { return nil }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Guardian warning",
                detail: message,
                severity: .danger,
                isStreaming: isStreaming ?? false
            )

        case .configWarning:
            guard let summary = string(from: raw["summary"]) else { return nil }
            var metadata: [String] = []
            if let details = string(from: raw["details"]) { metadata.append(details) }
            if let path = string(from: raw["path"]) { metadata.append("Config: \(path)") }
            if let range = textRangeSummary(from: raw["range"]) { metadata.append(range) }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Config warning",
                detail: summary,
                metadata: metadata,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .deprecationNotice:
            guard let summary = string(from: raw["summary"]) else { return nil }
            let details = string(from: raw["details"]).map { [$0] } ?? []
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Deprecation notice",
                detail: summary,
                metadata: details,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            return approvalReviewNotice(
                itemID: itemID,
                method: method,
                raw: raw,
                isStreaming: isStreaming ?? (method == .itemAutoApprovalReviewStarted)
            )

        default:
            return nil
        }
    }

    public static func notice(
        itemID: String,
        kind: String,
        title: String,
        detail: String,
        status: String? = nil,
        metadata: [String] = [],
        severity: Notice.Severity = .info,
        isStreaming: Bool = false
    ) -> Notice {
        Notice(
            itemID: itemID,
            kind: kind,
            title: title,
            detail: detail,
            status: status,
            metadata: metadata,
            severity: severity,
            isStreaming: isStreaming
        )
    }

    private struct FileUpdateChange {
        var path: String?
        var kind: String?
        var diff: String
    }

    private static func approvalReviewNotice(
        itemID: String,
        method: CodexAppServerNotificationMethod,
        raw: [String: CodexJSONValue],
        isStreaming: Bool
    ) -> Notice? {
        guard let review = dictionary(from: raw["review"]),
              let status = string(from: review["status"]) else {
            return nil
        }

        let action = dictionary(from: raw["action"])
        let actionSummary = approvalActionSummary(from: action)
        let rationale = string(from: review["rationale"])
        let riskLevel = string(from: review["riskLevel"]).map(humanize)
        let targetItemID = string(from: raw["targetItemId"])
        let source = string(from: raw["decisionSource"]).map(humanize)
        let title: String
        switch status {
        case "approved":
            title = "Auto review approved"
        case "denied":
            title = "Auto review denied"
        case "timedOut":
            title = "Auto review timed out"
        case "aborted":
            title = "Auto review aborted"
        default:
            title = "Auto review"
        }

        var metadata: [String] = []
        if let rationale { metadata.append(rationale) }
        if let riskLevel { metadata.append("Risk: \(riskLevel)") }
        if let targetItemID { metadata.append("Target: \(targetItemID)") }
        if let source { metadata.append("Decision source: \(source)") }

        let duration = durationSummary(startedAtMs: int(from: raw["startedAtMs"]), completedAtMs: int(from: raw["completedAtMs"]))
        if let duration { metadata.append(duration) }

        return Notice(
            itemID: itemID,
            kind: method.rawValue,
            title: title,
            detail: actionSummary,
            status: status,
            metadata: metadata,
            severity: reviewSeverity(for: status),
            isStreaming: isStreaming
        )
    }

    private static func approvalActionSummary(from action: [String: CodexJSONValue]?) -> String {
        guard let action else { return "Reviewing requested action" }
        switch string(from: action["type"]) {
        case "command":
            return string(from: action["command"]) ?? "Reviewing command"
        case "execve":
            let argv = stringArray(from: action["argv"])
            if !argv.isEmpty { return argv.joined(separator: " ") }
            return string(from: action["program"]) ?? "Reviewing process execution"
        case "applyPatch":
            let files = stringArray(from: action["files"])
            return files.isEmpty ? "Reviewing patch" : "Reviewing patch: \(files.joined(separator: ", "))"
        case "networkAccess":
            let target = string(from: action["target"])
            let host = string(from: action["host"])
            let port = string(from: action["port"])
            let endpoint = [host, port].compactMap { $0 }.joined(separator: ":")
            return target ?? (endpoint.isEmpty ? "Reviewing network access" : "Reviewing network access: \(endpoint)")
        case "mcpToolCall":
            let server = string(from: action["server"])
            let tool = string(from: action["toolTitle"]) ?? string(from: action["toolName"])
            return [server, tool].compactMap { $0 }.joined(separator: ".").nilIfBlank ?? "Reviewing MCP tool call"
        case "requestPermissions":
            return string(from: action["reason"]) ?? "Reviewing permission request"
        case let type?:
            return "Reviewing \(humanize(type))"
        case nil:
            return "Reviewing requested action"
        }
    }

    private static func reviewSeverity(for status: String) -> Notice.Severity {
        switch status {
        case "approved":
            return .success
        case "denied", "timedOut", "aborted":
            return .danger
        default:
            return .info
        }
    }

    private static func durationSummary(startedAtMs: Int?, completedAtMs: Int?) -> String? {
        guard let startedAtMs, let completedAtMs, completedAtMs >= startedAtMs else { return nil }
        let duration = Double(completedAtMs - startedAtMs) / 1_000
        return String(format: "Duration: %.1fs", duration)
    }

    private static func stringArray(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap(string(from:))
        case let value?:
            return string(from: value).map { [$0] } ?? []
        case nil:
            return []
        }
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = value else { return nil }
        return object
    }

    private static func textRangeSummary(from value: CodexJSONValue?) -> String? {
        guard let range = dictionary(from: value),
              let start = dictionary(from: range["start"]),
              let line = string(from: start["line"]) else {
            return nil
        }
        if let column = string(from: start["column"]) {
            return "Location: \(line):\(column)"
        }
        return "Location: line \(line)"
    }

    private static func humanize(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var result = ""
        for scalar in spaced.unicodeScalars {
            let string = String(scalar)
            if string.rangeOfCharacter(from: .uppercaseLetters) != nil, !result.isEmpty, result.last != " " {
                result.append(" ")
            }
            result.append(string)
        }
        return result
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
    }

    private static func planSteps(from value: CodexJSONValue?) -> [PlanUpdate.Step] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            guard let step = string(from: object["step"]) ?? string(from: object["text"]) ?? string(from: object["title"]) else {
                return nil
            }
            let status = string(from: object["status"]) ?? "pending"
            return PlanUpdate.Step(step: step, status: status)
        }
    }

    private static func progressMessages(from raw: [String: CodexJSONValue]) -> [String] {
        var messages: [String] = []
        for key in ["message", "progress", "progressMessage", "statusText"] {
            if let text = string(from: raw[key]), !text.isEmpty {
                messages.append(text)
            }
        }
        if case .array(let values)? = raw["progressMessages"] {
            messages.append(contentsOf: values.compactMap(string(from:)))
        }
        var seen: Set<String> = []
        return messages.filter { seen.insert($0).inserted }
    }

    private static func resultText(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string.nilIfBlank
        case .array(let values):
            return values.compactMap(resultText(from:)).joined(separator: "\n").nilIfBlank
        case .dictionary(let object):
            if let content = resultText(from: object["content"]) {
                return content
            }
            if let structured = jsonText(from: object["structuredContent"]) {
                return structured
            }
            return string(from: object["text"])
                ?? string(from: object["message"])
                ?? jsonText(from: value)
        case .int, .double, .bool, .null, nil:
            return string(from: value)
        }
    }

    private static func errorText(from value: CodexJSONValue?) -> String? {
        switch value {
        case .dictionary(let object):
            return string(from: object["message"])
                ?? string(from: object["error"])
                ?? jsonText(from: value)
        case .string:
            return string(from: value)
        case .int, .double, .bool, .array, .null, nil:
            return nil
        }
    }

    private static func fileUpdateChanges(from value: CodexJSONValue?) -> [FileUpdateChange] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            let path = string(from: object["path"])
            let diff = string(from: object["diff"]) ?? ""
            let kind = string(from: object["kind"])
                ?? string(from: object["type"])
                ?? string(from: nestedValue(object["kind"], key: "type"))
            guard path != nil || !diff.isEmpty else { return nil }
            return FileUpdateChange(path: path, kind: kind, diff: diff)
        }
    }

    private static func firstFileChangePath(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        return object.keys.sorted().first
    }

    private static func firstFileChangeKind(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        for key in object.keys.sorted() {
            guard case .dictionary(let change)? = object[key],
                  let kind = string(from: change["type"]) else { continue }
            return kind
        }
        return nil
    }

    private static func fileChangesDiff(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        let chunks = object.keys.sorted().compactMap { path -> String? in
            guard case .dictionary(let change)? = object[path] else { return nil }
            if let diff = string(from: change["unified_diff"])?.nilIfBlank {
                return diff
            }
            if let content = string(from: change["content"])?.nilIfBlank,
               let type = string(from: change["type"])?.nilIfBlank {
                return syntheticDiff(path: path, type: type, content: content)
            }
            return nil
        }
        let diff = chunks.joined(separator: "\n")
        return diff.nilIfBlank
    }

    private static func syntheticDiff(path: String, type: String, content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch type {
        case "delete":
            return (["--- a/\(path)", "+++ /dev/null"] + lines.map { "-\($0)" }).joined(separator: "\n")
        case "add":
            return (["--- /dev/null", "+++ b/\(path)"] + lines.map { "+\($0)" }).joined(separator: "\n")
        default:
            return content
        }
    }

    private static func nestedValue(_ value: CodexJSONValue?, key: String) -> CodexJSONValue? {
        guard case .dictionary(let object)? = value else { return nil }
        return object[key]
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string.nilIfBlank
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values):
            return values.compactMap(string(from:)).joined(separator: " ").nilIfBlank
        case .dictionary(let object):
            return string(from: object["type"])
                ?? string(from: object["message"])
                ?? string(from: object["text"])
        case .null, nil:
            return nil
        }
    }

    private static func int(from value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private static func jsonText(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string, .int, .double, .bool:
            return string(from: value)
        case .array, .dictionary:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else {
                return value.description.nilIfBlank
            }
            return text.nilIfBlank
        }
    }
}
