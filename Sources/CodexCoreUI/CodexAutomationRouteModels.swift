import Foundation

public enum CodexAutomationRouteAction: Equatable, Sendable {
    case createViaChat
    case template(CodexAutomationTemplate)
    case addForChat(threadID: String, threadTitle: String, workspacePath: String)
    case save(CodexAutomation)
    case toggle(id: String)
    case delete(id: String)
    case runNow(id: String)
    case learnMore

    public var title: String {
        switch self {
        case .createViaChat: "Create via chat"
        case .template(let template): template.title
        case .addForChat: "Add automation"
        case .save: "Save automation"
        case .toggle: "Enable or disable automation"
        case .delete: "Delete automation"
        case .runNow: "Run automation now"
        case .learnMore: "Learn more"
        }
    }

    public var draftPrompt: String? { draftRequest?.prompt }

    public var draftRequest: CodexAutomationDraftRequest? {
        switch self {
        case .createViaChat:
            CodexAutomationDraftRequest(
                prompt: Self.createViaChatPrompt,
                activityTitle: "Automation draft",
                activityDetail: "Prepared automation chat",
                startsNewChat: true
            )
        case .template(let template):
            template.draftPrompt.map {
                CodexAutomationDraftRequest(
                    prompt: $0,
                    activityTitle: "Automation draft",
                    activityDetail: "Prepared \(template.title)",
                    startsNewChat: true
                )
            }
        case .addForChat(let threadID, let threadTitle, let workspacePath):
            CodexAutomationDraftRequest(
                prompt: CodexThreadLifecycleActionModel.addAutomationDraftPrompt(
                    threadID: threadID,
                    threadTitle: threadTitle,
                    workspacePath: workspacePath
                ),
                activityTitle: "Automation draft",
                activityDetail: "Prepared automation draft for \(threadTitle)",
                startsNewChat: false
            )
        case .save, .toggle, .delete, .runNow, .learnMore:
            nil
        }
    }

    public static let createViaChatPrompt = "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run"
}

public struct CodexAutomationDraftRequest: Equatable, Sendable {
    public var prompt: String
    public var activityTitle: String
    public var activityDetail: String
    public var startsNewChat: Bool

    public init(prompt: String, activityTitle: String, activityDetail: String, startsNewChat: Bool) {
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
    public var title: String { self == .viewTemplates ? "View templates" : "Create via chat" }
}

public enum CodexAutomationFrequency: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case daily
    case weekdays
    case weekly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekly: "Every week"
        }
    }
}

public struct CodexAutomationSchedule: Codable, Equatable, Sendable {
    public var frequency: CodexAutomationFrequency
    public var hour: Int
    public var minute: Int
    /// Calendar weekday (1 = Sunday ... 7 = Saturday), used for weekly schedules.
    public var weekday: Int

    public init(frequency: CodexAutomationFrequency = .weekdays, hour: Int = 9, minute: Int = 0, weekday: Int = 2) {
        self.frequency = frequency
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
    }

    public var rrule: String {
        let time = "BYHOUR=\(hour);BYMINUTE=\(minute)"
        switch frequency {
        case .daily: return "FREQ=DAILY;\(time)"
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;\(time)"
        case .weekly:
            let day = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][weekday - 1]
            return "FREQ=WEEKLY;BYDAY=\(day);\(time)"
        }
    }

    public init(rrule: String) {
        let values = Dictionary(uniqueKeysWithValues: rrule.split(separator: ";").compactMap { component -> (String, String)? in
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        hour = Int(values["BYHOUR"] ?? "9") ?? 9
        minute = Int(values["BYMINUTE"] ?? "0") ?? 0
        let days = values["BYDAY"] ?? ""
        if days == "MO,TU,WE,TH,FR" {
            frequency = .weekdays
            weekday = 2
        } else if values["FREQ"] == "WEEKLY", let index = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].firstIndex(of: days) {
            frequency = .weekly
            weekday = index + 1
        } else {
            frequency = .daily
            weekday = 2
        }
    }

    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        switch frequency {
        case .daily:
            break
        case .weekdays:
            for offset in 0...7 {
                guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { continue }
                let weekday = calendar.component(.weekday, from: candidateDay)
                guard (2...6).contains(weekday) else { continue }
                var dayComponents = calendar.dateComponents([.year, .month, .day], from: candidateDay)
                dayComponents.hour = hour
                dayComponents.minute = minute
                if let candidate = calendar.date(from: dayComponents), candidate > date {
                    return candidate
                }
            }
            return nil
        case .weekly:
            components.weekday = weekday
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    public var summary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let time = Calendar.current.date(from: components).map(formatter.string) ?? String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .daily: return "Daily at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            let day = Calendar.current.weekdaySymbols[weekday - 1]
            return "Every \(day) at \(time)"
        }
    }
}

public enum CodexAutomationStatus: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case running
    case failed

    public var label: String {
        switch self {
        case .enabled: "Scheduled"
        case .disabled: "Paused"
        case .running: "Running"
        case .failed: "Needs attention"
        }
    }
}

public struct CodexAutomation: Identifiable, Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: CodexAutomationSchedule
    public var status: CodexAutomationStatus
    public var targetThreadID: String?
    public var createdAt: Date
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastError: String?

    public init(
        version: Int = 1,
        id: String = UUID().uuidString.lowercased(),
        name: String,
        prompt: String,
        schedule: CodexAutomationSchedule = CodexAutomationSchedule(),
        status: CodexAutomationStatus = .enabled,
        targetThreadID: String? = nil,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.status = status
        self.targetThreadID = targetThreadID
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt ?? (status == .disabled ? nil : schedule.nextDate(after: createdAt))
        self.lastError = lastError
    }

    public var statusLabel: String { status.label }
    public var isEnabled: Bool { status != .disabled }
}

public struct CodexAutomationRouteState: Equatable, Sendable {
    public var mode: CodexAutomationRouteMode
    public var automations: [CodexAutomation]
    public var templates: [CodexAutomationTemplate]

    public init(mode: CodexAutomationRouteMode = .viewTemplates, automations: [CodexAutomation] = [], templates: [CodexAutomationTemplate] = CodexAutomationTemplate.allCases) {
        self.mode = mode
        self.automations = automations
        self.templates = templates
    }

    public var headerTitle: String { "Automations" }
    public var description: String { "Run chats on a schedule or whenever you need them." }
    public var learnMoreTitle: String { "Learn more" }
    public var emptyTitle: String { "Create your first automation" }
    public var newAutomationOptionsTitle: String { "New automation" }
    public var showsEmptyState: Bool { automations.isEmpty }
    public var selectedModeTitle: String { mode.title }
}

public struct CodexAutomationRouteSession: Equatable, Sendable {
    public private(set) var state: CodexAutomationRouteState
    public private(set) var lastDraftRequest: CodexAutomationDraftRequest?

    public init(state: CodexAutomationRouteState = CodexAutomationRouteState()) {
        self.state = state
    }

    @discardableResult
    public mutating func perform(_ action: CodexAutomationRouteAction) -> CodexAutomationDraftRequest? {
        if case .createViaChat = action { state.mode = .createViaChat }
        lastDraftRequest = action.draftRequest
        return lastDraftRequest
    }

    public mutating func viewTemplates() {
        state.mode = .viewTemplates
        lastDraftRequest = nil
    }
}

public struct CodexAutomationLifecycle: Equatable, Sendable {
    public private(set) var automations: [CodexAutomation]

    public init(automations: [CodexAutomation] = []) {
        self.automations = automations.map { automation in
            var recovered = automation
            if recovered.status == .running {
                recovered.status = .enabled
            }
            return recovered
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public mutating func save(_ automation: CodexAutomation, now: Date = Date()) {
        var automation = automation
        if automation.status == .running { automation.status = .enabled }
        automation.nextRunAt = automation.status == .disabled ? nil : automation.schedule.nextDate(after: now)
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[index] = automation
        } else {
            automations.append(automation)
        }
    }

    @discardableResult
    public mutating func toggle(id: String, now: Date = Date()) -> CodexAutomation? {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return nil }
        if automations[index].status == .disabled {
            automations[index].status = .enabled
            automations[index].nextRunAt = automations[index].schedule.nextDate(after: now)
        } else {
            automations[index].status = .disabled
            automations[index].nextRunAt = nil
        }
        return automations[index]
    }

    public mutating func delete(id: String) { automations.removeAll { $0.id == id } }

    public mutating func beginRun(id: String, now: Date = Date()) -> CodexAutomation? {
        guard let index = automations.firstIndex(where: { $0.id == id }), automations[index].status != .running else { return nil }
        automations[index].status = .running
        automations[index].lastError = nil
        automations[index].nextRunAt = automations[index].schedule.nextDate(after: now)
        return automations[index]
    }

    public mutating func finishRun(id: String, threadID: String?, error: String?, now: Date = Date()) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].lastRunAt = now
        automations[index].targetThreadID = threadID ?? automations[index].targetThreadID
        automations[index].lastError = error
        automations[index].status = error == nil ? .enabled : .failed
        automations[index].nextRunAt = automations[index].schedule.nextDate(after: now)
    }

    public func due(at date: Date = Date()) -> [CodexAutomation] {
        automations.filter { automation in
            guard automation.status == .enabled || automation.status == .failed,
                  let nextRunAt = automation.nextRunAt else { return false }
            return nextRunAt <= date
        }
    }
}

public enum CodexAutomationTemplate: String, CaseIterable, Equatable, Sendable, Identifiable {
    case dailyBrief
    case weeklyReview
    case projectMonitor

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dailyBrief: "Daily brief"
        case .weeklyReview: "Weekly review"
        case .projectMonitor: "Project monitor"
        }
    }
    public var systemImage: String {
        switch self {
        case .dailyBrief: "sun.max"
        case .weeklyReview: "calendar"
        case .projectMonitor: "eye"
        }
    }
    public var description: String {
        switch self {
        case .dailyBrief: "Start the day with priorities and updates"
        case .weeklyReview: "Summarize progress and plan the week ahead"
        case .projectMonitor: "Watch a project for changes that need attention"
        }
    }
    public var draftPrompt: String? {
        switch self {
        case .dailyBrief: "Set up an automation that gives me a morning brief each weekday; what's on my calendar, important unread emails, and anything that needs my attention today."
        case .weeklyReview: "Set up a weekly review automation that summarizes what changed in my active projects, calls out unfinished work, and helps me plan next week."
        case .projectMonitor: "Set up an automation that monitors this project for important changes, failures, or blocked work and tells me when something needs my attention."
        }
    }
    public var isDraftBacked: Bool { draftPrompt != nil }
}
