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

    enum TranscriptAvailability: Equatable, Sendable {
        case available
        case exceedsDisplayLimit
    }

    public let id: String
    public var name: String
    public var title: String
    public var prompt: String
    public var status: Status
    public var transcript: CodexTranscriptV2
    var transcriptAvailability: TranscriptAvailability
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String? = nil,
        name: String,
        title: String,
        prompt: String,
        status: Status,
        transcript: CodexTranscriptV2 = .init(),
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id ?? "subagent-\(name.lowercased())"
        self.name = name
        self.title = title
        self.prompt = prompt
        self.status = status
        self.transcript = transcript
        self.transcriptAvailability = .available
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public extension CodexSubagentState {
    internal var emptyTranscriptMessage: String {
        if transcriptAvailability == .exceedsDisplayLimit {
            return "This transcript exceeds the in-memory display limit."
        }
        switch status {
        case .running:
            return "Waiting for this agent’s transcript…"
        case .completed, .closed:
            return "This agent completed without returning a transcript."
        case .failed:
            return "This agent failed before returning a transcript."
        }
    }

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
    public var transcript: CodexTranscriptV2
    public var createdAt: Date

    public init(
        id: String = Self.defaultID,
        title: String = "Side chat",
        transcript: CodexTranscriptV2 = .init(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.createdAt = createdAt
    }
}

public enum CodexAgentPanelTab: Identifiable, Equatable, Sendable {
    case sideChat(CodexSideChatState)
    case subagent(CodexSubagentState)

    public var isSubagent: Bool {
        if case .subagent = self { return true }
        return false
    }

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

    public var systemImage: String {
        switch self {
        case .sideChat: return "rectangle.split.2x1"
        case .subagent: return "person.wave.2"
        }
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

    func tint(in theme: CodexAgentTheme) -> Color {
        switch self {
        case .turn: return theme.colors.accent
        case .tool: return theme.colors.tool
        case .token: return theme.colors.success
        case .login: return theme.colors.warning
        case .notice: return theme.colors.textTertiary
        }
    }
}
