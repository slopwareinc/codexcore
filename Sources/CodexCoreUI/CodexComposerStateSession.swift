import Foundation
import CodexCore

public struct CodexComposerSubmission: Equatable, Sendable {
    public var prompt: String
    public var referencedFiles: [CodexReferencedFile]
    public var skills: [CodexSlashCommand]
    public var mentions: [CodexInput]
    public var clientID: String
    public var threadID: String?

    public init(
        prompt: String,
        referencedFiles: [CodexReferencedFile] = [],
        skills: [CodexSlashCommand] = [],
        mentions: [CodexInput] = [],
        clientID: String = UUID().uuidString,
        threadID: String? = nil
    ) {
        self.prompt = prompt
        self.referencedFiles = referencedFiles
        self.skills = skills
        self.mentions = mentions
        self.clientID = clientID
        self.threadID = threadID
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
        } + mentions + [.text(CodexFileReferencePromptCodec.encode(files: referencedFiles, request: prompt))]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prompt == rhs.prompt
            && lhs.referencedFiles == rhs.referencedFiles
            && lhs.skills == rhs.skills
            && lhs.mentions == rhs.mentions
            && lhs.threadID == rhs.threadID
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
    private static let unassignedDraftKey = "__codex_unassigned_draft__"

    private var activeThreadID: String?
    private var draftByThreadID: [String: String]
    private var referencedFilesByThreadID: [String: [CodexReferencedFile]]

    public var draft: String {
        get { draft(for: activeThreadID) }
        set { setDraft(newValue, for: activeThreadID) }
    }

    public var referencedFiles: [CodexReferencedFile] {
        get { referencedFiles(for: activeThreadID) }
        set { setReferencedFiles(newValue, for: activeThreadID) }
    }

    public var sideChatDraft: String
    public var followUpBehavior: CodexFollowUpBehavior
    public var queuedFollowUps: [String] {
        queuedFollowUpSubmissions(for: activeThreadID).map(\.prompt)
    }
    public private(set) var mentionResults: [FuzzyFileSearchResult]
    public private(set) var attachedSkills: [CodexSlashCommand]
    private var selectedMentionsByName: [String: FuzzyFileSearchResult]
    private var queuedFollowUpSubmissionsByThreadID: [String: [CodexComposerSubmission]]

    public init(
        draft: String = "",
        sideChatDraft: String = "",
        followUpBehavior: CodexFollowUpBehavior = .steer,
        queuedFollowUps: [String] = [],
        mentionResults: [FuzzyFileSearchResult] = [],
        attachedSkills: [CodexSlashCommand] = [],
        selectedMentionsByName: [String: FuzzyFileSearchResult] = [:],
        activeThreadID: String? = nil,
        draftByThreadID: [String: String] = [:],
        referencedFilesByThreadID: [String: [CodexReferencedFile]] = [:]
    ) {
        self.activeThreadID = Self.normalizedThreadID(activeThreadID)
        var drafts = draftByThreadID
        let initialKey = Self.draftKey(for: self.activeThreadID)
        if !draft.isEmpty {
            drafts[initialKey] = draft
        }
        self.draftByThreadID = drafts
        self.referencedFilesByThreadID = referencedFilesByThreadID
        self.sideChatDraft = sideChatDraft
        self.followUpBehavior = followUpBehavior
        self.mentionResults = mentionResults
        self.attachedSkills = attachedSkills
        self.selectedMentionsByName = selectedMentionsByName
        self.queuedFollowUpSubmissionsByThreadID = [:]
        if !queuedFollowUps.isEmpty {
            self.queuedFollowUpSubmissionsByThreadID[Self.draftKey(for: self.activeThreadID)] = queuedFollowUps.map {
                CodexComposerSubmission(prompt: $0, threadID: self.activeThreadID)
            }
        }
    }

    public var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func draft(for threadID: String?) -> String {
        draftByThreadID[Self.draftKey(for: threadID)] ?? ""
    }

    public func trimmedDraft(for threadID: String?) -> String {
        draft(for: threadID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func referencedFiles(for threadID: String?) -> [CodexReferencedFile] {
        referencedFilesByThreadID[Self.draftKey(for: threadID)] ?? []
    }

    public mutating func setReferencedFiles(_ files: [CodexReferencedFile], for threadID: String?) {
        let key = Self.draftKey(for: threadID)
        print("[DEBUG-FILE-DROP] state set key=\(key) incoming=\(files.map(\.path))")
        let deduplicated = files.reduce(into: [CodexReferencedFile]()) { result, file in
            guard !result.contains(where: { $0.path == file.path }) else { return }
            result.append(file)
        }
        if deduplicated.isEmpty {
            referencedFilesByThreadID.removeValue(forKey: key)
        } else {
            referencedFilesByThreadID[key] = deduplicated
        }
        print("[DEBUG-FILE-DROP] state stored key=\(key) files=\(referencedFilesByThreadID[key]?.map(\.path) ?? [])")
    }

    @discardableResult
    public mutating func addReferencedFiles(_ files: [CodexReferencedFile], for threadID: String?) -> [CodexReferencedFile] {
        let existing = referencedFiles(for: threadID)
        let merged = existing + files
        setReferencedFiles(merged, for: threadID)
        return referencedFiles(for: threadID)
    }

    public mutating func removeReferencedFile(id: String, for threadID: String?) {
        setReferencedFiles(referencedFiles(for: threadID).filter { $0.id != id }, for: threadID)
    }

    public mutating func setDraft(_ draft: String, for threadID: String?) {
        let key = Self.draftKey(for: threadID)
        if draft.isEmpty {
            draftByThreadID.removeValue(forKey: key)
        } else {
            draftByThreadID[key] = draft
        }
    }

    public mutating func setActiveThreadID(_ threadID: String?) {
        activeThreadID = Self.normalizedThreadID(threadID)
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

    public mutating func consumeDraftForFollowUp() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        let files = referencedFiles
        guard !prompt.isEmpty || !files.isEmpty else { return nil }
        let submission = CodexComposerSubmission(prompt: prompt, referencedFiles: files, threadID: activeThreadID)
        draft = ""
        referencedFiles = []
        return submission
    }

    public mutating func consumeDraftForTurn() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        let files = referencedFiles
        guard !prompt.isEmpty || !files.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            referencedFiles: files,
            skills: attachedSkills,
            mentions: mentionInputs(for: prompt),
            threadID: activeThreadID
        )
        draft = ""
        referencedFiles = []
        attachedSkills = []
        selectedMentionsByName = [:]
        mentionResults = []
        return submission
    }

    public mutating func consumeDraftForGoal() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        let files = referencedFiles
        guard !prompt.isEmpty || !files.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            referencedFiles: files,
            skills: attachedSkills,
            threadID: activeThreadID
        )
        draft = ""
        referencedFiles = []
        attachedSkills = []
        return submission
    }

    public mutating func restore(_ submission: CodexComposerSubmission) {
        let targetThreadID = submission.threadID
        let existingDraft = draft(for: targetThreadID)
        let restoredDraft = if existingDraft.isEmpty || existingDraft == submission.prompt {
            submission.prompt
        } else if submission.prompt.isEmpty {
            existingDraft
        } else {
            submission.prompt + "\n\n" + existingDraft
        }
        setDraft(restoredDraft, for: targetThreadID)
        setReferencedFiles(
            submission.referencedFiles + referencedFiles(for: targetThreadID),
            for: targetThreadID
        )
        attachedSkills = submission.skills + attachedSkills
    }

    public mutating func enqueueFollowUp(_ prompt: String) {
        enqueueFollowUp(CodexComposerSubmission(prompt: prompt, threadID: activeThreadID))
    }

    public mutating func enqueueFollowUp(_ submission: CodexComposerSubmission) {
        let threadID = submission.threadID ?? activeThreadID
        let key = Self.draftKey(for: threadID)
        var queue = queuedFollowUpSubmissionsByThreadID[key] ?? []
        var ownedSubmission = submission
        ownedSubmission.threadID = threadID
        queue.append(ownedSubmission)
        queuedFollowUpSubmissionsByThreadID[key] = queue
    }

    public mutating func dequeueQueuedFollowUp(isSending: Bool) -> String? {
        dequeueQueuedFollowUpSubmission(isSending: isSending)?.prompt
    }

    public mutating func dequeueQueuedFollowUpSubmission(isSending: Bool) -> CodexComposerSubmission? {
        guard !isSending else { return nil }
        let key = Self.draftKey(for: activeThreadID)
        guard var queue = queuedFollowUpSubmissionsByThreadID[key], !queue.isEmpty else { return nil }
        let submission = queue.removeFirst()
        if queue.isEmpty {
            queuedFollowUpSubmissionsByThreadID.removeValue(forKey: key)
        } else {
            queuedFollowUpSubmissionsByThreadID[key] = queue
        }
        return submission
    }

    public mutating func requeueFollowUp(_ prompt: String) {
        requeueFollowUp(CodexComposerSubmission(prompt: prompt, threadID: activeThreadID))
    }

    public mutating func requeueFollowUp(_ submission: CodexComposerSubmission) {
        let threadID = submission.threadID ?? activeThreadID
        let key = Self.draftKey(for: threadID)
        var queue = queuedFollowUpSubmissionsByThreadID[key] ?? []
        var ownedSubmission = submission
        ownedSubmission.threadID = threadID
        queue.insert(ownedSubmission, at: 0)
        queuedFollowUpSubmissionsByThreadID[key] = queue
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

    public mutating func discardThreadState(for threadID: String) {
        let key = Self.draftKey(for: threadID)
        draftByThreadID.removeValue(forKey: key)
        referencedFilesByThreadID.removeValue(forKey: key)
        queuedFollowUpSubmissionsByThreadID.removeValue(forKey: key)
    }

    public func queuedFollowUpSubmissions(for threadID: String?) -> [CodexComposerSubmission] {
        queuedFollowUpSubmissionsByThreadID[Self.draftKey(for: threadID)] ?? []
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

    private static func draftKey(for threadID: String?) -> String {
        normalizedThreadID(threadID) ?? unassignedDraftKey
    }

    private static func normalizedThreadID(_ threadID: String?) -> String? {
        let trimmed = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
