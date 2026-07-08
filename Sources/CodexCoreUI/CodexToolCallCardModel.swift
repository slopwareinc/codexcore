import Foundation

// Tool-call *card* models. These were previously in CodexCore/Parser but are
// pure presentation: SF Symbol icon names, human-facing titles/labels,
// pre-formatted durations, and disclosure (expanded) state. They live in
// CodexCoreUI so the SDK stays free of view concerns. Parsing markdown into
// these cards is a UI-only path (see `CodexToolCallCardParser`).

public enum ToolCallKind: String, Codable, Sendable, Equatable {
    case commandExecution
    case commandOutput
    case fileChange
    case fileDiff
    case mcpToolCall
    case mcpToolProgress
    case webSearch
    case collaboration
    case imageView
    case widget

    public var title: String {
        switch self {
        case .commandExecution: return "Command Execution"
        case .commandOutput: return "Command Output"
        case .fileChange: return "File Change"
        case .fileDiff: return "File Diff"
        case .mcpToolCall: return "MCP Tool Call"
        case .mcpToolProgress: return "MCP Tool Progress"
        case .webSearch: return "Web Search"
        case .collaboration: return "Collaboration"
        case .imageView: return "Image View"
        case .widget: return "Widget"
        }
    }

    public var iconName: String {
        switch self {
        case .commandExecution, .commandOutput:
            return "terminal.fill"
        case .fileChange:
            return "doc.text.fill"
        case .fileDiff:
            return "arrow.left.arrow.right.square.fill"
        case .mcpToolCall:
            return "wrench.and.screwdriver.fill"
        case .mcpToolProgress:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .webSearch:
            return "globe"
        case .collaboration:
            return "person.2.fill"
        case .imageView:
            return "photo.fill"
        case .widget:
            return "sparkles"
        }
    }

    public static func from(title: String) -> ToolCallKind? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("command output") { return .commandOutput }
        if normalized.contains("command execution") || normalized == "command" { return .commandExecution }
        if normalized.contains("file change") { return .fileChange }
        if normalized.contains("file diff") || normalized == "diff" { return .fileDiff }
        if normalized.contains("mcp tool progress") { return .mcpToolProgress }
        if normalized.contains("mcp tool call") || normalized == "mcp" { return .mcpToolCall }
        if normalized.contains("web search") { return .webSearch }
        if normalized.contains("collaboration") || normalized.contains("collab") { return .collaboration }
        if normalized.contains("image view") || normalized == "image" { return .imageView }
        if normalized.contains("widget") || normalized.contains("show widget") { return .widget }
        if normalized.contains("dynamic tool call") { return .mcpToolCall }
        return nil
    }

    public var isCommandLike: Bool {
        switch self {
        case .commandExecution, .commandOutput:
            return true
        default:
            return false
        }
    }
}

public enum ToolCallStatus: String, Codable, Sendable, Equatable {
    case inProgress
    case completed
    case failed
    case unknown

    public var label: String {
        switch self {
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

public struct ToolCallKeyValue: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct ToolCallCommandContext: Codable, Sendable, Equatable {
    public let command: String
    public let directory: String?

    public init(command: String, directory: String?) {
        self.command = command
        self.directory = directory
    }
}

public enum ToolCallSection: Codable, Sendable, Equatable {
    case kv(label: String, entries: [ToolCallKeyValue])
    case code(label: String, language: String, content: String)
    case json(label: String, content: String)
    case diff(label: String, content: String)
    case text(label: String, content: String)
    case list(label: String, items: [String])
    case progress(label: String, items: [String])
}

public struct ToolCallCardModel: Codable, Sendable, Equatable {
    public let kind: ToolCallKind
    public let title: String
    public let summary: String
    public let status: ToolCallStatus
    public let duration: String?
    public let sections: [ToolCallSection]
    public let initiallyExpanded: Bool
    public let commandContext: ToolCallCommandContext?

    public init(
        kind: ToolCallKind,
        title: String,
        summary: String,
        status: ToolCallStatus,
        duration: String?,
        sections: [ToolCallSection],
        initiallyExpanded: Bool = false,
        commandContext: ToolCallCommandContext? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.status = status
        self.duration = duration
        self.sections = sections
        self.initiallyExpanded = initiallyExpanded
        self.commandContext = commandContext
    }

    public var defaultExpanded: Bool { initiallyExpanded || status == .failed }
}

/// Parses assistant markdown into rich tool-call cards. UI-only: the output is
/// a view model (icons, disclosure state, formatted durations).
public enum CodexToolCallCardParser {
    public static func parse(_ text: String) -> [ToolCallCardModel] {
        ToolCallMarkdownParser().parse(text: text)
    }
}
