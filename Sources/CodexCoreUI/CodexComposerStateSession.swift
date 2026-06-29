import Foundation
import CodexCore

public struct CodexComposerSubmission: Equatable, Sendable {
    public var prompt: String
    public var skills: [CodexSlashCommand]
    public var mentions: [CodexInput]

    public init(prompt: String, skills: [CodexSlashCommand] = [], mentions: [CodexInput] = []) {
        self.prompt = prompt
        self.skills = skills
        self.mentions = mentions
    }

    public var skillDetail: String? {
        skills.isEmpty ? nil : "Skills: \(skills.map(\.title).joined(separator: ", "))"
    }

    public var goalDetail: String {
        skills.isEmpty ? "Goal" : "Goal · Skills: \(skills.map(\.title).joined(separator: ", "))"
    }

    public var turnInput: [CodexInput] {
        skills.compactMap { command -> CodexInput? in
            guard let name = command.skillName, let path = command.skillPath else { return nil }
            return .skill(name: name, path: path)
        } + mentions + [.text(prompt)]
    }
}

public enum CodexComposerSlashCommandHostAction: Equatable, Sendable {
    case openSideChat
    case applyFastMode
    case cycleReasoning
    case openModelSelector
    case openReasoningSelector
    case showCurrentStatus
    case forkCurrentChat
    case compactCurrentChat
    case presentMCPStatus
    case refreshMCPServers
}

public struct CodexComposerSlashCommandRoute: Equatable, Sendable {
    public var activities: [CodexActivity]
    public var hostActions: [CodexComposerSlashCommandHostAction]

    public init(
        activities: [CodexActivity] = [],
        hostActions: [CodexComposerSlashCommandHostAction] = []
    ) {
        self.activities = activities
        self.hostActions = hostActions
    }
}

public struct CodexComposerStateSession: Equatable, Sendable {
    public var draft: String
    public var sideChatDraft: String
    public var followUpBehavior: CodexFollowUpBehavior
    public private(set) var queuedFollowUps: [String]
    public private(set) var mentionResults: [FuzzyFileSearchResult]
    public private(set) var attachedSkills: [CodexSlashCommand]
    private var selectedMentionsByName: [String: FuzzyFileSearchResult]

    public init(
        draft: String = "",
        sideChatDraft: String = "",
        followUpBehavior: CodexFollowUpBehavior = .steer,
        queuedFollowUps: [String] = [],
        mentionResults: [FuzzyFileSearchResult] = [],
        attachedSkills: [CodexSlashCommand] = [],
        selectedMentionsByName: [String: FuzzyFileSearchResult] = [:]
    ) {
        self.draft = draft
        self.sideChatDraft = sideChatDraft
        self.followUpBehavior = followUpBehavior
        self.queuedFollowUps = queuedFollowUps
        self.mentionResults = mentionResults
        self.attachedSkills = attachedSkills
        self.selectedMentionsByName = selectedMentionsByName
    }

    public var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedSideChatDraft: String {
        sideChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func followUpHint(isSending: Bool, canSendFollowUp: Bool) -> String? {
        guard isSending else {
            return queuedFollowUps.isEmpty ? nil : "\(queuedFollowUps.count) queued"
        }
        let queuedSuffix = queuedFollowUps.isEmpty ? "" : " · \(queuedFollowUps.count) queued"
        switch followUpBehavior {
        case .steer:
            return canSendFollowUp ? "↩ steers the current turn\(queuedSuffix)" : nil
        case .queue:
            return canSendFollowUp ? "↩ queues for the next turn\(queuedSuffix)" : nil
        }
    }

    public mutating func clearDraft() {
        draft = ""
    }

    public mutating func clearSideChatDraft() {
        sideChatDraft = ""
    }

    public mutating func consumeDraftForFollowUp() -> String? {
        let prompt = trimmedDraft
        guard !prompt.isEmpty else { return nil }
        draft = ""
        return prompt
    }

    public mutating func consumeDraftForTurn() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        guard !prompt.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            skills: attachedSkills,
            mentions: mentionInputs(for: prompt)
        )
        draft = ""
        attachedSkills = []
        selectedMentionsByName = [:]
        mentionResults = []
        return submission
    }

    public mutating func consumeDraftForGoal() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        guard !prompt.isEmpty else { return nil }
        let submission = CodexComposerSubmission(prompt: prompt, skills: attachedSkills)
        draft = ""
        attachedSkills = []
        return submission
    }

    public mutating func restore(_ submission: CodexComposerSubmission) {
        draft = submission.prompt
        attachedSkills = submission.skills + attachedSkills
    }

    public mutating func enqueueFollowUp(_ prompt: String) {
        queuedFollowUps.append(prompt)
    }

    public mutating func dequeueQueuedFollowUp(isSending: Bool) -> String? {
        guard !queuedFollowUps.isEmpty, !isSending else { return nil }
        return queuedFollowUps.removeFirst()
    }

    public mutating func requeueFollowUp(_ prompt: String) {
        queuedFollowUps.insert(prompt, at: 0)
    }

    public mutating func attachSkill(_ command: CodexSlashCommand) {
        draft = command.draftText ?? ""
        guard let skillName = command.skillName, let skillPath = command.skillPath else { return }
        if !attachedSkills.contains(where: { $0.skillName == skillName && $0.skillPath == skillPath }) {
            attachedSkills.append(command)
        }
    }

    public mutating func routeSlashCommand(_ command: CodexSlashCommand) -> CodexComposerSlashCommandRoute {
        if command.skillName != nil, command.skillPath != nil {
            attachSkill(command)
            return route(activityTitle: "Skill attached", detail: command.title)
        }

        switch command.id {
        case "side":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.openSideChat])
        case "fast":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.applyFastMode])
        case "reasoning":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.openReasoningSelector])
        case "model":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.openModelSelector])
        case "status":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.showCurrentStatus])
        case "fork":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.forkCurrentChat])
        case "compact":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.compactCurrentChat])
        case "mcp":
            clearDraft()
            return CodexComposerSlashCommandRoute(hostActions: [.refreshMCPServers])
        case "pet":
            clearDraft()
            return route(activityTitle: "Pet", detail: "Pet controls are not available in this example yet")
        default:
            if let draftText = command.draftText {
                draft = draftText
                return route(activityTitle: "Slash command", detail: "Prepared \(command.title)")
            }
            clearDraft()
            return route(activityTitle: "Slash command", detail: command.title)
        }
    }

    public mutating func setMentionResults(_ results: [FuzzyFileSearchResult]) {
        mentionResults = results
    }

    public mutating func clearMentionResults() {
        mentionResults = []
    }

    public mutating func selectMention(_ result: FuzzyFileSearchResult) {
        selectedMentionsByName[result.fileName] = result
        mentionResults = []
    }

    public mutating func clearThreadState() {
        sideChatDraft = ""
        attachedSkills = []
    }

    private func mentionInputs(for prompt: String) -> [CodexInput] {
        selectedMentionsByName.values
            .filter { prompt.contains("@\($0.fileName)") }
            .map { CodexInput.mention(name: $0.fileName, path: $0.absolutePath) }
    }

    private func route(activityTitle title: String, detail: String) -> CodexComposerSlashCommandRoute {
        CodexComposerSlashCommandRoute(activities: [
            CodexActivity(kind: .notice, title: title, detail: detail)
        ])
    }
}
