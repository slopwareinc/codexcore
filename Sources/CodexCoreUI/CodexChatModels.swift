import Foundation
import SwiftUI
import CodexCore

public enum CodexConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(server: String)
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected(let server): return "Connected to \(server)"
        case .failed: return "Connection failed"
        }
    }
}

public struct CodexChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user = "You"
        case assistant = "Codex"
        case terminal = "Terminal"
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

    public let id: UUID
    public var role: Role
    public var text: String
    public var detail: String?
    public var isStreaming: Bool
    public var createdAt: Date
    public var renderBlocks: [AssistantRenderBlock]
    public var commandRun: CommandRun?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        detail: String? = nil,
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        parseContent: Bool = true,
        renderBlocks: [AssistantRenderBlock]? = nil,
        commandRun: CommandRun? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.renderBlocks = renderBlocks ?? (parseContent ? Self.renderBlocks(for: text) : [.markdown(text)])
        self.commandRun = commandRun
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
}

public struct CodexActivity: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case turn
        case tool
        case token
        case login
        case notice
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct CodexAgentLifecycleEvent: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case spawning
        case running
        case completed
        case closed
        case failed
    }

    public let id: UUID
    public var status: Status
    public var title: String
    public var detail: String
    public var agentNames: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        status: Status,
        title: String,
        detail: String = "",
        agentNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.agentNames = agentNames
        self.createdAt = createdAt
    }
}

public struct CodexSubagentState: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case running
        case completed
        case closed
        case failed
    }

    public let id: String
    public var name: String
    public var title: String
    public var prompt: String
    public var status: Status
    public var messages: [CodexChatMessage]
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String? = nil,
        name: String,
        title: String,
        prompt: String,
        status: Status,
        messages: [CodexChatMessage] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id ?? "subagent-\(name.lowercased())"
        self.name = name
        self.title = title
        self.prompt = prompt
        self.status = status
        self.messages = messages
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public struct CodexSideChatState: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var messages: [CodexChatMessage]
    public var createdAt: Date

    public init(
        id: String = "side-chat",
        title: String = "Side chat",
        messages: [CodexChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }
}

public enum CodexAgentPanelTab: Identifiable, Equatable, Sendable {
    case sideChat(CodexSideChatState)
    case subagent(CodexSubagentState)

    public var id: String {
        switch self {
        case .sideChat(let sideChat): return sideChat.id
        case .subagent(let subagent): return subagent.id
        }
    }

    public var title: String {
        switch self {
        case .sideChat(let sideChat): return sideChat.title
        case .subagent(let subagent): return subagent.name
        }
    }

    public var messages: [CodexChatMessage] {
        switch self {
        case .sideChat(let sideChat): return sideChat.messages
        case .subagent(let subagent): return subagent.messages
        }
    }
}

public struct CodexAgentPanelState: Equatable, Sendable {
    public var isOpen: Bool
    public var selectedTabID: String?
    public var sideChat: CodexSideChatState?
    public var subagents: [CodexSubagentState]

    public init(
        isOpen: Bool = false,
        selectedTabID: String? = nil,
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = []
    ) {
        self.isOpen = isOpen
        self.selectedTabID = selectedTabID
        self.sideChat = sideChat
        self.subagents = subagents
    }

    public var tabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        tabs.append(contentsOf: subagents.map(CodexAgentPanelTab.subagent))
        return tabs
    }
}

public struct CodexPromptSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { prompt }
    public var systemImage: String
    public var prompt: String

    public init(systemImage: String, prompt: String) {
        self.systemImage = systemImage
        self.prompt = prompt
    }
}

extension CodexActivity.Kind {
    var systemImage: String {
        switch self {
        case .turn: return "arrow.triangle.2.circlepath"
        case .tool: return "wrench.and.screwdriver.fill"
        case .token: return "gauge.with.dots.needle.33percent"
        case .login: return "person.badge.key.fill"
        case .notice: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .turn: return CodexTheme.accent
        case .tool: return CodexTheme.tool
        case .token: return CodexTheme.success
        case .login: return CodexTheme.warning
        case .notice: return CodexTheme.tertiary
        }
    }
}
