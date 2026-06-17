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

}
