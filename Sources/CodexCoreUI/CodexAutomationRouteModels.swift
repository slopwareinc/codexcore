import Foundation

public enum CodexAutomationRouteAction: Equatable, Sendable {
    case createViaChat
    case template(CodexAutomationTemplate)

    public var title: String {
        switch self {
        case .createViaChat:
            return "Create via chat"
        case .template(let template):
            return template.title
        }
    }

    public var draftPrompt: String? {
        switch self {
        case .createViaChat:
            return Self.createViaChatPrompt
        case .template(let template):
            return template.draftPrompt
        }
    }

    public static let createViaChatPrompt = "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run"
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
