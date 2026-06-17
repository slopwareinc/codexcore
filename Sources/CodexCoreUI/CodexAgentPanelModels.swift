import Foundation
import SwiftUI

/// Inline transcript indicator shown while a turn is in progress before assistant streaming begins.
public struct CodexActiveTurnState: Equatable, Sendable {
    public var activity: CodexActivity?
    public var startedAt: Date

    public init(activity: CodexActivity? = nil, startedAt: Date = Date()) {
        self.activity = activity
        self.startedAt = startedAt
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

public extension CodexSubagentState {
    var isVisibleInFloatingSummary: Bool {
        status != .closed
    }

    var floatingSummaryTitle: String {
        switch status {
        case .running:
            return "\(name) is working"
        case .completed:
            return name
        case .failed:
            return "\(name) failed"
        case .closed:
            return name
        }
    }

    var floatingSummarySystemImage: String {
        switch status {
        case .running:
            return "person.crop.circle.badge.clock"
        case .completed:
            return "person.crop.circle.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .closed:
            return "person.crop.circle"
        }
    }
}

public struct CodexSideChatState: Identifiable, Equatable, Sendable {
    public static let defaultID = "side-chat"

    public let id: String
    public var title: String
    public var messages: [CodexChatMessage]
    public var createdAt: Date

    public init(
        id: String = Self.defaultID,
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
    public var detail: String?

    public init(systemImage: String, prompt: String, detail: String? = nil) {
        self.systemImage = systemImage
        self.prompt = prompt
        self.detail = detail
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
