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
    /// Local composer ownership; never used as a native protocol thread identifier.
    public var draftID: CodexComposerDraftID?
    public var queueID: String?
    public var queuedInput: [CodexInput]?

    public init(
        prompt: String,
        referencedFiles: [CodexReferencedFile] = [],
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        skills: [CodexSlashCommand] = [],
        mentions: [CodexInput] = [],
        clientID: String = UUID().uuidString,
        threadID: String? = nil,
        queueID: String? = nil,
        queuedInput: [CodexInput]? = nil,
        draftID: CodexComposerDraftID? = nil
    ) {
        self.prompt = prompt
        self.referencedFiles = referencedFiles
        self.responseAnnotations = responseAnnotations
        self.skills = skills
        self.mentions = mentions
        self.clientID = clientID
        self.threadID = threadID
        self.draftID = draftID
        self.queueID = queueID
        self.queuedInput = queuedInput
    }

    public var skillDetail: String? {
        skills.isEmpty ? nil : "Skills: \(skills.map(\.title).joined(separator: ", "))"
    }

    public var goalDetail: String {
        skills.isEmpty ? "Goal" : "Goal · Skills: \(skills.map(\.title).joined(separator: ", "))"
    }

    public var turnInput: [CodexInput] {
        if let queuedInput { return queuedInput }
        return skills.compactMap { command -> CodexInput? in
            guard let name = command.skillName, let path = command.skillPath else { return nil }
            return .skill(name: name, path: path)
        } + mentions + [.text(CodexComposerPromptCodec.encode(
            files: referencedFiles,
            responseAnnotations: responseAnnotations,
            request: prompt
        ))] + referencedFiles.filter(\.isImage).map { .localImage(path: $0.path) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prompt == rhs.prompt
            && lhs.referencedFiles == rhs.referencedFiles
            && lhs.responseAnnotations == rhs.responseAnnotations
            && lhs.skills == rhs.skills
            && lhs.mentions == rhs.mentions
            && lhs.threadID == rhs.threadID
            && lhs.draftID == rhs.draftID
            && lhs.queueID == rhs.queueID
            && lhs.queuedInput == rhs.queuedInput
    }

    public init(
        queuedSubmission: CodexSchemaQueuedSubmission,
        threadID: String
    ) {
        let input = queuedSubmission.input.map { CodexInput(jsonValue: $0.rawValue) }
        let rawText = input.compactMap { value -> String? in
            guard case .text(let text, _) = value else { return nil }
            return text
        }.last ?? ""
        let decoded = CodexComposerPromptCodec.decode(rawText)
        let skills = input.compactMap { value -> CodexSlashCommand? in
            guard case .skill(let name, let path) = value else { return nil }
            return CodexSlashCommand(
                id: "queued-skill:\(path)",
                title: name,
                detail: path,
                systemImage: "shippingbox",
                section: "Skills",
                skillName: name,
                skillPath: path
            )
        }
        self.init(
            prompt: decoded?.request ?? rawText,
            referencedFiles: decoded?.files ?? [],
            skills: skills,
            mentions: input.filter {
                if case .mention = $0 { true } else { false }
            },
            clientID: queuedSubmission.clientUserMessageID,
            threadID: threadID,
            queueID: queuedSubmission.id,
            queuedInput: input
        )
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

    public private(set) var activeThreadID: String?
    public private(set) var activeDraftID: CodexComposerDraftID
    private var draftIDByThreadID: [String: CodexComposerDraftID]
    private var threadIDByDraftID: [String: String]
    private var workspacePathByDraftID: [String: String]
    private var projectIDByDraftID: [String: String]
    private var projectlessDraftIDs: Set<CodexComposerDraftID>
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
    private var skillsByDraftID: [String: [CodexSlashCommand]]
    private var mentionsByDraftID: [String: [String: FuzzyFileSearchResult]]
    public private(set) var attachedSkills: [CodexSlashCommand] {
        get { skillsByDraftID[activeDraftID.rawValue] ?? [] }
        set { skillsByDraftID[activeDraftID.rawValue] = newValue.isEmpty ? nil : newValue }
    }
    private var selectedMentionsByName: [String: FuzzyFileSearchResult] {
        get { mentionsByDraftID[activeDraftID.rawValue] ?? [:] }
        set { mentionsByDraftID[activeDraftID.rawValue] = newValue.isEmpty ? nil : newValue }
    }
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
        responseAnnotationsByThreadID: [String: [CodexResponseTextAnnotation]] = [:],
        activeDraftID: CodexComposerDraftID? = nil
    ) {
        self.activeThreadID = Self.normalizedThreadID(activeThreadID)
        self.activeDraftID = activeDraftID ?? self.activeThreadID.map(CodexComposerDraftID.thread) ?? .unassigned
        self.draftIDByThreadID = [:]
        self.threadIDByDraftID = [:]
        self.workspacePathByDraftID = [:]
        self.projectIDByDraftID = [:]
        self.projectlessDraftIDs = []
        self.draftByThreadID = [:]
        self.referencedFilesByThreadID = [:]
        self.responseAnnotationsByThreadID = [:]
        self.skillsByDraftID = [:]
        self.mentionsByDraftID = [:]
        self.sideChatDraft = sideChatDraft
        self.followUpBehavior = followUpBehavior
        self.mentionResults = mentionResults
        for key in Set(draftByThreadID.keys).union(referencedFilesByThreadID.keys).union(responseAnnotationsByThreadID.keys) {
            let id: CodexComposerDraftID = key == Self.unassignedDraftKey ? .unassigned : .thread(key)
            self.draftByThreadID[id.rawValue] = draftByThreadID[key]
            self.referencedFilesByThreadID[id.rawValue] = referencedFilesByThreadID[key]
            self.responseAnnotationsByThreadID[id.rawValue] = responseAnnotationsByThreadID[key]
            if key != Self.unassignedDraftKey {
                self.draftIDByThreadID[key] = id
                self.threadIDByDraftID[id.rawValue] = key
            }
        }
        if let threadID = self.activeThreadID {
            self.draftIDByThreadID[threadID] = self.activeDraftID
            self.threadIDByDraftID[self.activeDraftID.rawValue] = threadID
        }
        if !draft.isEmpty { self.draftByThreadID[self.activeDraftID.rawValue] = draft }
        self.skillsByDraftID[self.activeDraftID.rawValue] = attachedSkills.isEmpty ? nil : attachedSkills
        self.mentionsByDraftID[self.activeDraftID.rawValue] = selectedMentionsByName.isEmpty ? nil : selectedMentionsByName
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
        draftByThreadID[draftID(for: threadID).rawValue] ?? ""
    }

    public func trimmedDraft(for threadID: String?) -> String {
        draft(for: threadID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func referencedFiles(for threadID: String?) -> [CodexReferencedFile] {
        referencedFilesByThreadID[draftID(for: threadID).rawValue] ?? []
    }

    public mutating func setReferencedFiles(_ files: [CodexReferencedFile], for threadID: String?) {
        let key = registeredDraftID(for: threadID).rawValue
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
        responseAnnotationsByThreadID[draftID(for: threadID).rawValue] ?? []
    }

    public mutating func setResponseAnnotations(
        _ annotations: [CodexResponseTextAnnotation],
        for threadID: String?
    ) {
        let key = registeredDraftID(for: threadID).rawValue
        if annotations.isEmpty {
            responseAnnotationsByThreadID.removeValue(forKey: key)
        } else {
            responseAnnotationsByThreadID[key] = annotations
        }
    }

    public mutating func setDraft(_ draft: String, for threadID: String?) {
        let key = registeredDraftID(for: threadID).rawValue
        if draft.isEmpty {
            draftByThreadID.removeValue(forKey: key)
        } else {
            draftByThreadID[key] = draft
        }
    }

    public mutating func setActiveThreadID(_ threadID: String?) {
        let threadID = Self.normalizedThreadID(threadID)
        if let threadID {
            let id = draftIDByThreadID[threadID] ?? .thread(threadID)
            setActiveDraftID(id, threadID: threadID)
        } else if activeThreadID != nil {
            setActiveDraftID(.unassigned)
        }
    }

    /// Selects a local draft independently of native thread creation.
    public mutating func setActiveDraftID(
        _ draftID: CodexComposerDraftID,
        threadID: String? = nil,
        workspacePath: String? = nil,
        projectID: String? = nil,
        isProjectless: Bool? = nil
    ) {
        let nativeThreadID = Self.normalizedThreadID(threadID) ?? threadIDByDraftID[draftID.rawValue]
        let selectionChanged = activeDraftID != draftID || activeThreadID != nativeThreadID
        activeDraftID = draftID
        activeThreadID = nativeThreadID
        if let threadID = activeThreadID {
            if let existingID = draftIDByThreadID[threadID], existingID != draftID {
                promoteDraft(draftID, to: threadID)
            }
            if let previousThreadID = threadIDByDraftID[draftID.rawValue], previousThreadID != threadID {
                draftIDByThreadID.removeValue(forKey: previousThreadID)
            }
            draftIDByThreadID[threadID] = draftID
            threadIDByDraftID[draftID.rawValue] = threadID
        }
        if let workspacePath { workspacePathByDraftID[draftID.rawValue] = workspacePath }
        if let projectID { projectIDByDraftID[draftID.rawValue] = projectID }
        if let isProjectless {
            if isProjectless { projectlessDraftIDs.insert(draftID) }
            else { projectlessDraftIDs.remove(draftID) }
        }
        if selectionChanged { mentionResults = [] }
    }

    @discardableResult
    public mutating func newDraft(
        workspacePath: String? = nil,
        projectID: String? = nil,
        isProjectless: Bool = false
    ) -> CodexComposerDraftID {
        let id = CodexComposerDraftID()
        setActiveDraftID(id, workspacePath: workspacePath, projectID: projectID, isProjectless: isProjectless)
        return id
    }

    /// Binds a successful launch to its native thread without consuming text typed during launch.
    /// Promotion of an inactive draft leaves the user's current composer selection unchanged.
    public mutating func promoteDraft(_ draftID: CodexComposerDraftID, to threadID: String) {
        guard let threadID = Self.normalizedThreadID(threadID) else { return }
        let destinationID = draftIDByThreadID[threadID] ?? .thread(threadID)
        if destinationID != draftID {
            let destinationText = draft(for: destinationID)
            let sourceText = draft(for: draftID)
            if !destinationText.isEmpty, destinationText != sourceText {
                setDraft(sourceText.isEmpty ? destinationText : sourceText + "\n\n" + destinationText, for: draftID)
            }
            setReferencedFiles(referencedFiles(for: draftID) + referencedFiles(for: destinationID), for: draftID)
            var annotations = responseAnnotations(for: draftID)
            annotations.append(contentsOf: responseAnnotations(for: destinationID).filter { candidate in
                !annotations.contains(where: { $0.id == candidate.id })
            })
            setResponseAnnotations(annotations, for: draftID)
            var skills = skillsByDraftID[draftID.rawValue] ?? []
            for skill in skillsByDraftID[destinationID.rawValue] ?? [] where !skills.contains(where: {
                $0.skillName == skill.skillName && $0.skillPath == skill.skillPath
            }) { skills.append(skill) }
            skillsByDraftID[draftID.rawValue] = skills.isEmpty ? nil : skills
            let destinationMentions = mentionsByDraftID[destinationID.rawValue] ?? [:]
            var mentions = mentionsByDraftID[draftID.rawValue] ?? [:]
            for (name, mention) in destinationMentions where mentions[name] == nil { mentions[name] = mention }
            mentionsByDraftID[draftID.rawValue] = mentions.isEmpty ? nil : mentions
            removeDraftStorage(destinationID)
        }
        if let oldThread = threadIDByDraftID[draftID.rawValue], oldThread != threadID {
            draftIDByThreadID.removeValue(forKey: oldThread)
        }
        threadIDByDraftID[draftID.rawValue] = threadID
        draftIDByThreadID[threadID] = draftID
        if activeDraftID == draftID || activeDraftID == destinationID {
            activeDraftID = draftID
            activeThreadID = threadID
        }
    }

    public func draft(for draftID: CodexComposerDraftID) -> String {
        draftByThreadID[draftID.rawValue] ?? ""
    }

    public mutating func setDraft(_ draft: String, for draftID: CodexComposerDraftID) {
        draftByThreadID[draftID.rawValue] = draft.isEmpty ? nil : draft
    }

    public func referencedFiles(for draftID: CodexComposerDraftID) -> [CodexReferencedFile] {
        referencedFilesByThreadID[draftID.rawValue] ?? []
    }

    public mutating func setReferencedFiles(_ files: [CodexReferencedFile], for draftID: CodexComposerDraftID) {
        var seen: Set<String> = []
        let files = files.filter { seen.insert($0.path).inserted }
        referencedFilesByThreadID[draftID.rawValue] = files.isEmpty ? nil : files
    }

    public func responseAnnotations(for draftID: CodexComposerDraftID) -> [CodexResponseTextAnnotation] {
        responseAnnotationsByThreadID[draftID.rawValue] ?? []
    }

    public mutating func setResponseAnnotations(
        _ annotations: [CodexResponseTextAnnotation],
        for draftID: CodexComposerDraftID
    ) {
        responseAnnotationsByThreadID[draftID.rawValue] = annotations.isEmpty ? nil : annotations
    }

    /// The active draft's content and context without projecting every stored draft.
    public var activeDraftRecord: CodexComposerDraftSnapshot {
        makeDraftRecord(key: activeDraftID.rawValue)
    }

    /// Returns an owned draft, including empty contexts omitted from sidebar records.
    public func draftRecord(for draftID: CodexComposerDraftID) -> CodexComposerDraftSnapshot? {
        let key = draftID.rawValue
        guard draftID == activeDraftID || draftByThreadID[key] != nil || referencedFilesByThreadID[key] != nil
            || responseAnnotationsByThreadID[key] != nil || skillsByDraftID[key] != nil || mentionsByDraftID[key] != nil
            || threadIDByDraftID[key] != nil || workspacePathByDraftID[key] != nil || projectIDByDraftID[key] != nil
            || projectlessDraftIDs.contains(draftID) else { return nil }
        return makeDraftRecord(key: key)
    }

    /// Updates host context without selecting the draft or changing its content.
    public mutating func setDraftContext(
        workspacePath: String?, projectID: String?, isProjectless: Bool, for draftID: CodexComposerDraftID
    ) {
        workspacePathByDraftID[draftID.rawValue] = workspacePath
        projectIDByDraftID[draftID.rawValue] = projectID
        if isProjectless { projectlessDraftIDs.insert(draftID) }
        else { projectlessDraftIDs.remove(draftID) }
    }

    private func makeDraftRecord(key: String) -> CodexComposerDraftSnapshot {
        CodexComposerDraftSnapshot(
            draftID: .init(rawValue: key), threadID: threadIDByDraftID[key],
            workspacePath: workspacePathByDraftID[key], projectID: projectIDByDraftID[key],
            isProjectless: projectlessDraftIDs.contains(.init(rawValue: key)),
            prompt: draftByThreadID[key] ?? "", referencedFiles: referencedFilesByThreadID[key] ?? [],
            responseAnnotations: responseAnnotationsByThreadID[key] ?? [], attachedSkills: skillsByDraftID[key] ?? [],
            selectedMentions: (mentionsByDraftID[key] ?? [:]).values.sorted { $0.fileName < $1.fileName }
        )
    }

    /// Stable records for host restoration and a local draft picker.
    public var draftRecords: [CodexComposerDraftSnapshot] {
        let keys = Set(draftByThreadID.keys)
            .union(referencedFilesByThreadID.keys).union(responseAnnotationsByThreadID.keys)
            .union(skillsByDraftID.keys).union(mentionsByDraftID.keys)
            .union(threadIDByDraftID.keys).union(workspacePathByDraftID.keys).union(projectIDByDraftID.keys)
            .union(projectlessDraftIDs.map(\.rawValue)).union([activeDraftID.rawValue])
        return keys.sorted().map { makeDraftRecord(key: $0) }
            .filter { !$0.isEmpty || $0.draftID == activeDraftID }
    }

    public func draftSnapshot() throws -> CodexComposerDraftsSnapshot {
        let snapshot = try CodexComposerDraftsSnapshot(activeDraftID: activeDraftID, drafts: draftRecords)
        _ = try snapshot.encoded()
        return snapshot
    }

    public init(
        restoring snapshot: CodexComposerDraftsSnapshot,
        followUpBehavior: CodexFollowUpBehavior = .steer
    ) throws {
        try snapshot.validate()
        _ = try snapshot.encoded()
        self.init(followUpBehavior: followUpBehavior, activeDraftID: snapshot.activeDraftID)
        for record in snapshot.drafts {
            let key = record.draftID.rawValue
            setDraft(record.prompt, for: record.draftID)
            setReferencedFiles(record.referencedFiles, for: record.draftID)
            setResponseAnnotations(record.responseAnnotations, for: record.draftID)
            skillsByDraftID[key] = record.attachedSkills.isEmpty ? nil : record.attachedSkills
            let mentions = Dictionary(uniqueKeysWithValues: record.selectedMentions.map { ($0.fileName, $0) })
            mentionsByDraftID[key] = mentions.isEmpty ? nil : mentions
            if let threadID = record.threadID {
                threadIDByDraftID[key] = threadID
                draftIDByThreadID[threadID] = record.draftID
            }
            workspacePathByDraftID[key] = record.workspacePath
            projectIDByDraftID[key] = record.projectID
            if record.isProjectless { projectlessDraftIDs.insert(record.draftID) }
        }
        setActiveDraftID(snapshot.activeDraftID)
    }

    /// Hydrates durable drafts without replacing live queue, search, policy, or newer typing.
    /// Existing native thread bindings retain their local identity when restoration used another ID.
    public mutating func mergeDrafts(
        from restored: CodexComposerStateSession,
        activateRestoredDraft: Bool = false
    ) {
        let canActivate = activateRestoredDraft && activeDraftID == .unassigned
            && activeThreadID == nil && draftRecords.allSatisfy(\.isEmpty)
        let liveMentionResults = mentionResults
        var importedIDs: [CodexComposerDraftID: CodexComposerDraftID] = [:]
        for record in restored.draftRecords {
            var targetID = record.threadID.flatMap { draftIDByThreadID[$0] } ?? record.draftID
            if let incomingThreadID = record.threadID,
               let currentBinding = threadIDByDraftID[targetID.rawValue], currentBinding != incomingThreadID {
                targetID = .thread(incomingThreadID)
                if let binding = threadIDByDraftID[targetID.rawValue], binding != incomingThreadID {
                    targetID = .init()
                }
            }
            importedIDs[record.draftID] = targetID
            let key = targetID.rawValue
            let currentText = draft(for: targetID)
            let incomingText = record.prompt
            let replacesBootstrapMetadata = targetID == .unassigned && currentText.isEmpty
                && referencedFiles(for: targetID).isEmpty && responseAnnotations(for: targetID).isEmpty
                && (skillsByDraftID[key] ?? []).isEmpty && (mentionsByDraftID[key] ?? [:]).isEmpty
            // Repeated hydration must not prepend a paragraph that was already imported.
            let alreadyContainsText = incomingText.isEmpty || currentText == incomingText
                || currentText.hasPrefix(incomingText + "\n\n")
                || currentText.hasSuffix("\n\n" + incomingText)
                || currentText.contains("\n\n" + incomingText + "\n\n")
            if !alreadyContainsText {
                setDraft(currentText.isEmpty ? incomingText : incomingText + "\n\n" + currentText, for: targetID)
            }
            setReferencedFiles(referencedFiles(for: targetID) + record.referencedFiles, for: targetID)
            var annotations = responseAnnotations(for: targetID)
            for annotation in record.responseAnnotations where !annotations.contains(where: { $0.id == annotation.id }) {
                annotations.append(annotation)
            }
            setResponseAnnotations(annotations, for: targetID)
            var skills = skillsByDraftID[key] ?? []
            for skill in record.attachedSkills where !skills.contains(where: {
                $0.skillName == skill.skillName && $0.skillPath == skill.skillPath
            }) { skills.append(skill) }
            skillsByDraftID[key] = skills.isEmpty ? nil : skills
            var mentions = mentionsByDraftID[key] ?? [:]
            for mention in record.selectedMentions where mentions[mention.fileName] == nil {
                mentions[mention.fileName] = mention
            }
            mentionsByDraftID[key] = mentions.isEmpty ? nil : mentions
            if let threadID = record.threadID, threadIDByDraftID[key] == nil {
                threadIDByDraftID[key] = threadID
                draftIDByThreadID[threadID] = targetID
            }
            let hasHostMetadata = workspacePathByDraftID[key] != nil || projectIDByDraftID[key] != nil
                || projectlessDraftIDs.contains(targetID)
            if replacesBootstrapMetadata {
                workspacePathByDraftID[key] = record.workspacePath
                projectIDByDraftID[key] = record.projectID
                if record.isProjectless { projectlessDraftIDs.insert(targetID) }
                else { projectlessDraftIDs.remove(targetID) }
            } else {
                if workspacePathByDraftID[key] == nil { workspacePathByDraftID[key] = record.workspacePath }
                if projectIDByDraftID[key] == nil { projectIDByDraftID[key] = record.projectID }
                if !hasHostMetadata, record.isProjectless { projectlessDraftIDs.insert(targetID) }
            }
        }
        if canActivate {
            setActiveDraftID(importedIDs[restored.activeDraftID] ?? restored.activeDraftID)
        }
        mentionResults = liveMentionResults
    }

    public mutating func discardDraft(_ draftID: CodexComposerDraftID) {
        removeDraftStorage(draftID)
        if activeDraftID == draftID { setActiveDraftID(.unassigned) }
    }

    private mutating func removeDraftStorage(_ draftID: CodexComposerDraftID) {
        let key = draftID.rawValue
        draftByThreadID.removeValue(forKey: key)
        referencedFilesByThreadID.removeValue(forKey: key)
        responseAnnotationsByThreadID.removeValue(forKey: key)
        skillsByDraftID.removeValue(forKey: key)
        mentionsByDraftID.removeValue(forKey: key)
        workspacePathByDraftID.removeValue(forKey: key)
        projectIDByDraftID.removeValue(forKey: key)
        projectlessDraftIDs.remove(draftID)
        if let threadID = threadIDByDraftID.removeValue(forKey: key), draftIDByThreadID[threadID] == draftID {
            draftIDByThreadID.removeValue(forKey: threadID)
        }
    }

    private func draftID(for threadID: String?) -> CodexComposerDraftID {
        if let threadID = Self.normalizedThreadID(threadID) {
            return draftIDByThreadID[threadID] ?? .thread(threadID)
        }
        return activeThreadID == nil ? activeDraftID : .unassigned
    }

    private mutating func registeredDraftID(for threadID: String?) -> CodexComposerDraftID {
        let id = draftID(for: threadID)
        if let threadID = Self.normalizedThreadID(threadID) {
            threadIDByDraftID[id.rawValue] = threadID
            draftIDByThreadID[threadID] = id
        }
        return id
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
            skills: attachedSkills,
            mentions: mentionInputs(for: prompt),
            threadID: activeThreadID,
            draftID: activeDraftID
        )
        draft = ""
        referencedFiles = []
        responseAnnotations = []
        attachedSkills = []
        selectedMentionsByName = [:]
        mentionResults = []
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
            threadID: activeThreadID,
            draftID: activeDraftID
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
            mentions: mentionInputs(for: prompt),
            threadID: activeThreadID,
            draftID: activeDraftID
        )
        draft = ""
        referencedFiles = []
        responseAnnotations = []
        attachedSkills = []
        selectedMentionsByName = [:]
        mentionResults = []
        return submission
    }

    public mutating func restore(_ submission: CodexComposerSubmission) {
        let targetID = submission.draftID ?? submission.threadID.map { draftID(for: $0) } ?? .unassigned
        let key = targetID.rawValue
        if let threadID = Self.normalizedThreadID(submission.threadID),
           threadIDByDraftID[key] == nil,
           draftIDByThreadID[threadID] == nil || draftIDByThreadID[threadID] == targetID {
            threadIDByDraftID[key] = threadID
            draftIDByThreadID[threadID] = targetID
        }
        let existingDraft = draft(for: targetID)
        let restoredDraft = if existingDraft.isEmpty || existingDraft == submission.prompt {
            submission.prompt
        } else if submission.prompt.isEmpty {
            existingDraft
        } else {
            submission.prompt + "\n\n" + existingDraft
        }
        setDraft(restoredDraft, for: targetID)
        setReferencedFiles(submission.referencedFiles + referencedFiles(for: targetID), for: targetID)
        var restoredAnnotations = submission.responseAnnotations
        restoredAnnotations.append(contentsOf: responseAnnotations(for: targetID).filter { current in
            !restoredAnnotations.contains(where: { $0.id == current.id })
        })
        setResponseAnnotations(restoredAnnotations, for: targetID)
        var skills = skillsByDraftID[key] ?? []
        for skill in submission.skills.reversed() where !skills.contains(where: {
            $0.skillName == skill.skillName && $0.skillPath == skill.skillPath
        }) { skills.insert(skill, at: 0) }
        skillsByDraftID[key] = skills.isEmpty ? nil : skills
        var mentions = mentionsByDraftID[key] ?? [:]
        for input in submission.mentions {
            guard case .mention(let name, let path) = input, mentions[name] == nil else { continue }
            mentions[name] = FuzzyFileSearchResult(fileName: name, matchType: .file, path: path, root: "", score: 0)
        }
        mentionsByDraftID[key] = mentions.isEmpty ? nil : mentions
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

    public mutating func replaceQueuedFollowUps(
        _ submissions: [CodexComposerSubmission],
        for threadID: String
    ) {
        let key = Self.draftKey(for: threadID)
        guard !submissions.isEmpty else {
            queuedFollowUpSubmissionsByThreadID.removeValue(forKey: key)
            return
        }
        var queue = CodexComposerSubmissionQueue()
        for submission in submissions { queue.append(submission) }
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
        mentionResults = []
    }

    public mutating func discardThreadState(for threadID: String) {
        discardDraft(draftID(for: threadID))
        queuedFollowUpSubmissionsByThreadID.removeValue(forKey: Self.draftKey(for: threadID))
    }

    public func queuedFollowUpSubmissions(for threadID: String?) -> [CodexComposerSubmission] {
        queuedFollowUpSubmissionsByThreadID[Self.draftKey(for: threadID)]?.elements ?? []
    }

    private func mentionInputs(for prompt: String) -> [CodexInput] {
        selectedMentionsByName.values
            .sorted { $0.fileName < $1.fileName }
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
