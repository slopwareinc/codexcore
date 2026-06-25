import Foundation

public enum CodexAutomationRouteAction: Equatable, Sendable {
    case createViaChat
    case template(CodexAutomationTemplate)
    case addForChat(threadID: String, threadTitle: String, workspacePath: String)
    case learnMore

    public var title: String {
        switch self {
        case .createViaChat:
            return "Create via chat"
        case .template(let template):
            return template.title
        case .addForChat:
            return "Add automation"
        case .learnMore:
            return "Learn more"
        }
    }

    public var draftPrompt: String? {
        draftRequest?.prompt
    }

    public var draftRequest: CodexAutomationDraftRequest? {
        switch self {
        case .createViaChat:
            return CodexAutomationDraftRequest(
                prompt: Self.createViaChatPrompt,
                activityTitle: "Automation draft",
                activityDetail: "Prepared automation chat",
                startsNewChat: true
            )
        case .template(let template):
            guard let prompt = template.draftPrompt else { return nil }
            return CodexAutomationDraftRequest(
                prompt: prompt,
                activityTitle: "Automation draft",
                activityDetail: "Prepared \(template.title)",
                startsNewChat: true
            )
        case .addForChat(let threadID, let threadTitle, let workspacePath):
            return CodexAutomationDraftRequest(
                prompt: CodexThreadLifecycleActionModel.addAutomationDraftPrompt(
                    threadID: threadID,
                    threadTitle: threadTitle,
                    workspacePath: workspacePath
                ),
                activityTitle: "Automation draft",
                activityDetail: "Prepared automation draft for \(threadTitle)",
                startsNewChat: false
            )
        case .learnMore:
            return nil
        }
    }

    public static let createViaChatPrompt = "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run"
}

public struct CodexAutomationDraftRequest: Equatable, Sendable {
    public var prompt: String
    public var activityTitle: String
    public var activityDetail: String
    public var startsNewChat: Bool

    public init(
        prompt: String,
        activityTitle: String,
        activityDetail: String,
        startsNewChat: Bool
    ) {
        self.prompt = prompt
        self.activityTitle = activityTitle
        self.activityDetail = activityDetail
        self.startsNewChat = startsNewChat
    }
}

public enum CodexAutomationRouteMode: String, CaseIterable, Equatable, Sendable, Identifiable {
    case viewTemplates
    case createViaChat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .viewTemplates:
            return "View templates"
        case .createViaChat:
            return "Create via chat"
        }
    }
}

public struct CodexAutomationSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var statusLabel: String

    public init(id: String, title: String, statusLabel: String) {
        self.id = id
        self.title = title
        self.statusLabel = statusLabel
    }
}

public struct CodexAutomationRouteState: Equatable, Sendable {
    public var mode: CodexAutomationRouteMode
    public var automations: [CodexAutomationSummary]
    public var templates: [CodexAutomationTemplate]

    public init(
        mode: CodexAutomationRouteMode = .viewTemplates,
        automations: [CodexAutomationSummary] = [],
        templates: [CodexAutomationTemplate] = CodexAutomationTemplate.allCases
    ) {
        self.mode = mode
        self.automations = automations
        self.templates = templates
    }

    public var headerTitle: String { "Automations" }
    public var description: String { "Run chats on a schedule or whenever you need them." }
    public var learnMoreTitle: String { "Learn more" }
    public var emptyTitle: String { "Create your first automation" }
    public var newAutomationOptionsTitle: String { "New automation options" }
    public var showsEmptyState: Bool { automations.isEmpty }

    public var selectedModeTitle: String {
        mode.title
    }
}

public struct CodexAutomationRouteSession: Equatable, Sendable {
    public private(set) var state: CodexAutomationRouteState
    public private(set) var lastDraftRequest: CodexAutomationDraftRequest?

    public init(state: CodexAutomationRouteState = CodexAutomationRouteState()) {
        self.state = state
        self.lastDraftRequest = nil
    }

    @discardableResult
    public mutating func perform(_ action: CodexAutomationRouteAction) -> CodexAutomationDraftRequest? {
        switch action {
        case .createViaChat:
            state.mode = .createViaChat
        case .template, .addForChat, .learnMore:
            break
        }
        lastDraftRequest = action.draftRequest
        return lastDraftRequest
    }

    public mutating func viewTemplates() {
        state.mode = .viewTemplates
        lastDraftRequest = nil
    }
}

public enum CodexAutomationTemplate: String, CaseIterable, Equatable, Sendable, Identifiable {
    case dailyBrief
    case weeklyReview
    case projectMonitor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dailyBrief:
            return "Daily brief"
        case .weeklyReview:
            return "Weekly review"
        case .projectMonitor:
            return "Project monitor"
        }
    }

    public var systemImage: String {
        switch self {
        case .dailyBrief:
            return "sun.max"
        case .weeklyReview:
            return "calendar"
        case .projectMonitor:
            return "eye"
        }
    }

    public var draftPrompt: String? {
        switch self {
        case .dailyBrief:
            return "Set up an automation that gives me a morning brief each weekday; what's on my calendar, important unread emails, and anything that needs my attention today."
        case .weeklyReview, .projectMonitor:
            return nil
        }
    }

    public var isDraftBacked: Bool {
        draftPrompt != nil
    }
}
