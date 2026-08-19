import Foundation
import CodexCore

public struct CodexComposerSubmission: Equatable, Sendable {
    public var prompt: String
    public var referencedFiles: [CodexReferencedFile]
    public var responseAnnotations: [CodexResponseTextAnnotation]
    public var skills: [CodexSlashCommand]
    public var mentions: [CodexInput]
    public var clientID: String
    public var threadID: String?

    public init(
        prompt: String,
        referencedFiles: [CodexReferencedFile] = [],
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        skills: [CodexSlashCommand] = [],
        mentions: [CodexInput] = [],
        clientID: String = UUID().uuidString,
        threadID: String? = nil
    ) {
        self.prompt = prompt
        self.referencedFiles = referencedFiles
        self.responseAnnotations = responseAnnotations
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
        } + mentions + [.text(CodexComposerPromptCodec.encode(
            files: referencedFiles,
            responseAnnotations: responseAnnotations,
            request: prompt
        ))]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prompt == rhs.prompt
            && lhs.referencedFiles == rhs.referencedFiles
            && lhs.responseAnnotations == rhs.responseAnnotations
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
    case forkCurrentChat
    case compactCurrentChat
    case enableGoalPursuit
    case enablePlanMode
    case presentStatus
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

/// FIFO storage for follow-up submissions. Dequeueing advances a head index
/// instead of shifting every remaining submission with `removeFirst()`.
private struct CodexComposerSubmissionQueue: Equatable, Sendable {
    private var storage: [CodexComposerSubmission?] = []
    private var head = 0

    var isEmpty: Bool { head >= storage.count }
    var elements: [CodexComposerSubmission] {
        guard head < storage.count else { return [] }
        return storage[head...].compactMap { $0 }
    }

    func firstIndex(
        where predicate: (CodexComposerSubmission) -> Bool
    ) -> Int? {
        guard head < storage.count else { return nil }
        for (index, submission) in storage[head...].enumerated() {
            if let submission, predicate(submission) { return index }
        }
        return nil
    }

    mutating func append(_ submission: CodexComposerSubmission) {
        storage.append(submission)
    }

    mutating func prepend(_ submission: CodexComposerSubmission) {
        if head > 0 {
            head -= 1
            storage[head] = submission
        } else {
            storage.insert(submission, at: 0)
        }
    }

    mutating func removeFirst() -> CodexComposerSubmission? {
        guard head < storage.count else { return nil }
        let submission = storage[head]
        storage[head] = nil
        head += 1
        reclaimConsumedPrefix()
        return submission
    }

    mutating func remove(at index: Int) -> CodexComposerSubmission? {
        let storageIndex = head + index
        guard index >= 0, storageIndex < storage.count else { return nil }
        let submission = storage.remove(at: storageIndex)
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }
        return submission
    }

    private mutating func reclaimConsumedPrefix() {
        guard head > 0 else { return }
        // Amortize compaction so repeated dequeues stay constant-time.
        if head != storage.count && (head < 64 || head * 2 < storage.count) { return }
        storage.removeSubrange(0..<head)
        head = 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elements == rhs.elements
    }
}

public struct CodexComposerStateSession: Equatable, Sendable {
    private static let unassignedDraftKey = "__codex_unassigned_draft__"

    private var activeThreadID: String?
    private var draftByThreadID: [String: String]
    private var referencedFilesByThreadID: [String: [CodexReferencedFile]]
    private var responseAnnotationsByThreadID: [String: [CodexResponseTextAnnotation]]

    public var draft: String {
        get { draft(for: activeThreadID) }
        set { setDraft(newValue, for: activeThreadID) }
    }

    public var referencedFiles: [CodexReferencedFile] {
        get { referencedFiles(for: activeThreadID) }
        set { setReferencedFiles(newValue, for: activeThreadID) }
    }

    public var responseAnnotations: [CodexResponseTextAnnotation] {
        get { responseAnnotations(for: activeThreadID) }
        set { setResponseAnnotations(newValue, for: activeThreadID) }
    }

    public var sideChatDraft: String
    public var followUpBehavior: CodexFollowUpBehavior
    public var queuedFollowUps: [String] {
        queuedFollowUpSubmissions(for: activeThreadID).map(\.prompt)
    }
    public private(set) var mentionResults: [FuzzyFileSearchResult]
    public private(set) var attachedSkills: [CodexSlashCommand]
    private var selectedMentionsByName: [String: FuzzyFileSearchResult]
    private var queuedFollowUpSubmissionsByThreadID: [String: CodexComposerSubmissionQueue]

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
        referencedFilesByThreadID: [String: [CodexReferencedFile]] = [:],
        responseAnnotationsByThreadID: [String: [CodexResponseTextAnnotation]] = [:]
    ) {
        self.activeThreadID = Self.normalizedThreadID(activeThreadID)
        var drafts = draftByThreadID
        let initialKey = Self.draftKey(for: self.activeThreadID)
        if !draft.isEmpty {
            drafts[initialKey] = draft
        }
        self.draftByThreadID = drafts
        self.referencedFilesByThreadID = referencedFilesByThreadID
        self.responseAnnotationsByThreadID = responseAnnotationsByThreadID
        self.sideChatDraft = sideChatDraft
        self.followUpBehavior = followUpBehavior
        self.mentionResults = mentionResults
        self.attachedSkills = attachedSkills
        self.selectedMentionsByName = selectedMentionsByName
        self.queuedFollowUpSubmissionsByThreadID = [:]
        if !queuedFollowUps.isEmpty {
            var queue = CodexComposerSubmissionQueue()
            for prompt in queuedFollowUps {
                queue.append(CodexComposerSubmission(prompt: prompt, threadID: self.activeThreadID))
            }
            self.queuedFollowUpSubmissionsByThreadID[Self.draftKey(for: self.activeThreadID)] = queue
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
        var seenPaths = Set<String>(minimumCapacity: files.count)
        var deduplicated: [CodexReferencedFile] = []
        deduplicated.reserveCapacity(files.count)
        for file in files where seenPaths.insert(file.path).inserted {
            deduplicated.append(file)
        }
        if deduplicated.isEmpty {
            referencedFilesByThreadID.removeValue(forKey: key)
        } else {
            referencedFilesByThreadID[key] = deduplicated
        }
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

    public func responseAnnotations(for threadID: String?) -> [CodexResponseTextAnnotation] {
        responseAnnotationsByThreadID[Self.draftKey(for: threadID)] ?? []
    }

    public mutating func setResponseAnnotations(
        _ annotations: [CodexResponseTextAnnotation],
        for threadID: String?
    ) {
        let key = Self.draftKey(for: threadID)
        if annotations.isEmpty {
            responseAnnotationsByThreadID.removeValue(forKey: key)
        } else {
            responseAnnotationsByThreadID[key] = annotations
        }
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
            return canSendFollowUp && !queuedFollowUps.isEmpty
                ? "\(queuedFollowUps.count) queued"
                : nil
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
        let annotations = responseAnnotations
        guard !prompt.isEmpty || !files.isEmpty || !annotations.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            referencedFiles: files,
            responseAnnotations: annotations,
            threadID: activeThreadID
        )
        draft = ""
        referencedFiles = []
        responseAnnotations = []
        return submission
    }

    public mutating func consumeDraftForTurn() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        let files = referencedFiles
        let annotations = responseAnnotations
        guard !prompt.isEmpty || !files.isEmpty || !annotations.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            referencedFiles: files,
            responseAnnotations: annotations,
            skills: attachedSkills,
            mentions: mentionInputs(for: prompt),
            threadID: activeThreadID
        )
        draft = ""
        referencedFiles = []
        responseAnnotations = []
        attachedSkills = []
        selectedMentionsByName = [:]
        mentionResults = []
        return submission
    }

    public mutating func consumeDraftForGoal() -> CodexComposerSubmission? {
        let prompt = trimmedDraft
        let files = referencedFiles
        let annotations = responseAnnotations
        guard !prompt.isEmpty || !files.isEmpty || !annotations.isEmpty else { return nil }
        let submission = CodexComposerSubmission(
            prompt: prompt,
            referencedFiles: files,
            responseAnnotations: annotations,
            skills: attachedSkills,
            threadID: activeThreadID
        )
        draft = ""
        referencedFiles = []
        responseAnnotations = []
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
        var restoredAnnotations = submission.responseAnnotations
        restoredAnnotations.append(contentsOf: responseAnnotations(for: targetThreadID).filter { current in
            !restoredAnnotations.contains(where: { $0.id == current.id })
        })
        setResponseAnnotations(restoredAnnotations, for: targetThreadID)
        attachedSkills = submission.skills + attachedSkills
    }

    public mutating func enqueueFollowUp(_ prompt: String) {
        enqueueFollowUp(CodexComposerSubmission(prompt: prompt, threadID: activeThreadID))
    }

    public mutating func enqueueFollowUp(_ submission: CodexComposerSubmission) {
        let threadID = submission.threadID ?? activeThreadID
        let key = Self.draftKey(for: threadID)
        var queue = queuedFollowUpSubmissionsByThreadID[key] ?? CodexComposerSubmissionQueue()
        var ownedSubmission = submission
        ownedSubmission.threadID = threadID
        queue.append(ownedSubmission)
        queuedFollowUpSubmissionsByThreadID[key] = queue
    }

    public mutating func takeQueuedFollowUpSubmission(
        clientID: String,
        threadID: String? = nil
    ) -> CodexComposerSubmission? {
        let key = Self.draftKey(for: threadID ?? activeThreadID)
        guard var queue = queuedFollowUpSubmissionsByThreadID[key],
              let index = queue.firstIndex(where: { $0.clientID == clientID }) else {
            return nil
        }
        let submission = queue.remove(at: index)
        if queue.isEmpty {
            queuedFollowUpSubmissionsByThreadID.removeValue(forKey: key)
        } else {
            queuedFollowUpSubmissionsByThreadID[key] = queue
        }
        return submission
    }

    public mutating func dequeueQueuedFollowUp(isSending: Bool) -> String? {
        dequeueQueuedFollowUpSubmission(isSending: isSending)?.prompt
    }

    public mutating func dequeueQueuedFollowUpSubmission(isSending: Bool) -> CodexComposerSubmission? {
        guard !isSending else { return nil }
        let key = Self.draftKey(for: activeThreadID)
        guard var queue = queuedFollowUpSubmissionsByThreadID[key], !queue.isEmpty,
              let submission = queue.removeFirst() else { return nil }
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
        var queue = queuedFollowUpSubmissionsByThreadID[key] ?? CodexComposerSubmissionQueue()
        var ownedSubmission = submission
        ownedSubmission.threadID = threadID
        queue.prepend(ownedSubmission)
        queuedFollowUpSubmissionsByThreadID[key] = queue
    }

    public mutating func attachSkill(_ command: CodexSlashCommand) {
        if trimmedDraft.isEmpty, let draftText = command.draftText {
            draft = draftText
        }
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
            return CodexComposerSlashCommandRoute(hostActions: [.openSideChat])
        case "fast":
            return CodexComposerSlashCommandRoute(hostActions: [.applyFastMode])
        case "reasoning":
            return CodexComposerSlashCommandRoute(hostActions: [.openReasoningSelector])
        case "model":
            return CodexComposerSlashCommandRoute(hostActions: [.openModelSelector])
        case "status":
            return CodexComposerSlashCommandRoute(hostActions: [.presentStatus])
        case "fork":
            return CodexComposerSlashCommandRoute(hostActions: [.forkCurrentChat])
        case "compact":
            return CodexComposerSlashCommandRoute(hostActions: [.compactCurrentChat])
        case "goal":
            return CodexComposerSlashCommandRoute(hostActions: [.enableGoalPursuit])
        case "plan":
            return CodexComposerSlashCommandRoute(hostActions: [.enablePlanMode])
        case "mcp":
            return CodexComposerSlashCommandRoute(hostActions: [.refreshMCPServers])
        default:
            if let draftText = command.draftText {
                if trimmedDraft.isEmpty {
                    draft = draftText
                }
                return route(activityTitle: "Slash command", detail: "Prepared \(command.title)")
            }
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
        responseAnnotationsByThreadID.removeValue(forKey: key)
        queuedFollowUpSubmissionsByThreadID.removeValue(forKey: key)
    }

    public func queuedFollowUpSubmissions(for threadID: String?) -> [CodexComposerSubmission] {
        queuedFollowUpSubmissionsByThreadID[Self.draftKey(for: threadID)]?.elements ?? []
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
