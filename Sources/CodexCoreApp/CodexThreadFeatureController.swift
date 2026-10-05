import Foundation
import Observation
import CodexCore
import CodexCoreUI

/// On-demand inspector state. Changing chats cancels reads and invalidates all
/// completions; successful mutations reconcile through app-server state.
@MainActor
@Observable
final class CodexThreadFeatureController {
    private(set) var threadID: String?
    private(set) var section: CodexThreadFeatureSection = .attachments
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var activityMessage: String?
    private(set) var attachments: [CodexSchemaThreadAttachment] = []
    private(set) var attachmentCursor: String?
    private(set) var memoryStatus: CodexSchemaMemoryStatusResponse?
    private(set) var memoryMode: CodexSchemaThreadMemoryMode?
    private(set) var timeline: [CodexThreadTimelineRow] = []
    private(set) var timelineCursor: String?
    private(set) var turns: [CodexSchemaTurn] = []
    private(set) var turnsCursor: String?
    private(set) var queue: [CodexSchemaQueuedSubmission] = []
    private(set) var queueIsComplete = false
    private(set) var thread: CodexSchemaThread?
    private(set) var currentSettings: [String: CodexJSONValue] = [:]
    private(set) var goal: CodexSchemaThreadGoal?
    var settingsDraft = CodexThreadSettingsDraft()
    var resourceDraft = CodexThreadResourceDraft()
    var goalDraft = CodexThreadGoalDraft()
    var searchDraft = ""
    private(set) var searchQuery = ""
    private(set) var occurrences: [CodexSchemaThreadSearchOccurrence] = []
    private(set) var occurrenceCursor: String?
    private(set) var loadedThreadIDs: [String] = []
    private(set) var loadedCursor: String?
    private(set) var isLoadingLoaded = false
    private(set) var deniedReviews: [CodexGuardianDeniedReview] = []

    @ObservationIgnored var onHistoryChanged: (@MainActor (String) async -> Void)?
    @ObservationIgnored var onOpenOccurrence: (@MainActor (String, CodexSchemaThreadSearchOccurrence) async -> Void)?
    @ObservationIgnored var onThreadDeleted: (@MainActor (String) async -> Void)?
    @ObservationIgnored private var provider: (any CodexThreadFeatureProvider)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Bool, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentCursors: Set<String> = []
    @ObservationIgnored private var timelineCursors: Set<String> = []
    @ObservationIgnored private var turnCursors: Set<String> = []
    @ObservationIgnored private var occurrenceCursors: Set<String> = []
    @ObservationIgnored private var loadedCursors: Set<String> = []
    @ObservationIgnored private var approvedReviewIDs: Set<String> = []
    @ObservationIgnored private var searchGeneration = 0
    var contextVersion: Int { generation }

    func bind(provider: (any CodexThreadFeatureProvider)?, threadID: String?) {
        generation &+= 1
        readTask?.cancel()
        mutationTask?.cancel()
        observationTask?.cancel()
        readTask = nil
        mutationTask = nil
        observationTask = nil
        self.provider = provider
        self.threadID = threadID
        isLoading = false
        isMutating = false
        errorMessage = nil
        activityMessage = nil
        attachments = []
        attachmentCursor = nil
        memoryStatus = nil
        memoryMode = nil
        timeline = []
        timelineCursor = nil
        turns = []
        turnsCursor = nil
        queue = []; queueIsComplete = false
        thread = nil
        currentSettings = [:]
        goal = nil
        settingsDraft = .init()
        resourceDraft = .init()
        goalDraft = .init()
        attachmentCursors = []
        timelineCursors = []
        turnCursors = []
        searchGeneration &+= 1
        searchDraft = ""; searchQuery = ""; occurrences = []; occurrenceCursor = nil
        occurrenceCursors = []; loadedCursors = []; loadedThreadIDs = []; loadedCursor = nil; isLoadingLoaded = false
        approvedReviewIDs = []; deniedReviews = []
        startObservationIfNeeded()
    }

    private func startObservationIfNeeded() {
        guard observationTask == nil, let provider, let threadID else { return }
        let binding = generation
        observationTask = Task { [weak self] in
            do {
                let changes = try await provider.changes(threadID: threadID)
                for await change in changes {
                    guard !Task.isCancelled, let self, generation == binding else { return }
                    if isMutating { continue } // Every successful mutation refreshes once.
                    switch (change, section) {
                    case (.settings, .settings):
                        activityMessage = "Chat settings changed. Refresh to inspect the current defaults."
                    case (.attachments, .attachments), (.settings, .memory), (.queue, .queue), (.guardian, .approvals):
                        await refresh()
                    default: break
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, generation == binding else { return }
                errorMessage = CodexErrorFormat.localizedDescription(error)
            }
        }
    }

    func activate(_ section: CodexThreadFeatureSection) async {
        self.section = section
        startObservationIfNeeded()
        await refresh()
    }

    func dismiss() {
        readTask?.cancel()
        observationTask?.cancel()
        readTask = nil
        observationTask = nil
        isLoading = false
    }

    func refresh() async { await load(append: false) }
    func loadMore() async { await load(append: true) }

    private func load(append: Bool) async {
        guard let provider, let threadID else {
            errorMessage = CodexThreadFeatureError.disconnected.localizedDescription
            return
        }
        readTask?.cancel()
        let binding = generation
        let loadingSection = section
        let searchVersion = searchGeneration, query = searchQuery
        isLoading = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                switch loadingSection {
                case .attachments:
                    let cursor = append ? attachmentCursor : nil
                    if append && cursor == nil { break }
                    let result = try await provider.perform(.attachments(.init(cursor: cursor, limit: 50, threadID: threadID)))
                    guard valid(binding, section: loadingSection) else { return }
                    guard case .attachments(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    if !append { attachments = []; attachmentCursors = [] }
                    if let cursor { attachmentCursors.insert(cursor) }
                    var byID = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    var order = attachments.map(\.id)
                    for item in page.data {
                        if byID[item.id] == nil { order.append(item.id) }
                        byID[item.id] = item
                    }
                    attachments = order.compactMap { byID[$0] }
                    attachmentCursor = nil
                    attachmentCursor = try nextCursor(page.nextCursor, seen: attachmentCursors)
                case .memory:
                    let result = try await provider.perform(.memoryStatus(.init()))
                    let settings = await provider.settings(threadID: threadID)
                    guard valid(binding, section: loadingSection) else { return }
                    guard case .memory(let status) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    memoryStatus = status
                    if case .string(let mode)? = settings?["memoryMode"] {
                        memoryMode = CodexSchemaThreadMemoryMode(rawValue: mode)
                    } else { memoryMode = nil }
                case .history:
                    let cursor = append ? timelineCursor : nil
                    if append && cursor == nil { break }
                    let result = try await provider.perform(.timeline(.init(cursor: cursor, limit: 50, threadID: threadID)))
                    guard valid(binding, section: loadingSection) else { return }
                    guard case .timeline(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    if !append { timeline = []; timelineCursors = [] }
                    if let cursor { timelineCursors.insert(cursor) }
                    var seen = Set(timeline.map(\.id))
                    let offset = timeline.count
                    for (index, value) in page.data.enumerated() {
                        let row = CodexThreadTimelineRow(value: value, ordinal: offset + index)
                        if seen.insert(row.id).inserted { timeline.append(row) }
                    }
                    timelineCursor = nil
                    timelineCursor = try nextCursor(page.nextCursor, seen: timelineCursors)
                    if !append { try await loadTurns(provider: provider, threadID: threadID, binding: binding, append: false) }
                case .settings:
                    let result = try await provider.perform(.read(.init(includeTurns: false, threadID: threadID)))
                    let settings = await provider.settings(threadID: threadID)
                    guard valid(binding, section: loadingSection) else { return }
                    guard case .thread(let value) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    thread = value
                    currentSettings = settings ?? [:]
                    settingsDraft = .init()
                    settingsDraft.model = value.model ?? scalar("model")
                    settingsDraft.effort = CodexJSONCoercion.string(from: value.reasoningEffort?.rawValue)
                        ?? scalar("effort").nilIfBlank ?? scalar("reasoningEffort")
                    settingsDraft.personality = scalar("personality")
                    settingsDraft.serviceTier = scalar("serviceTier")
                    settingsDraft.daybreak = value.daybreakEnabled.map { $0 ? "enabled" : "disabled" } ?? ""
                    settingsDraft.projectID = value.projectID ?? ""
                    if case .array(let values)? = currentSettings["disabledPluginIds"] {
                        settingsDraft.disabledPluginIDs = Set(values.compactMap { if case .string(let id) = $0 { id } else { nil } })
                    }
                case .queue:
                    queueIsComplete = false
                    if let completeQueue = try await loadQueue(provider: provider, threadID: threadID, binding: binding) {
                        queue = completeQueue
                        queueIsComplete = true
                    }
                case .search:
                    guard !query.isEmpty else { break }
                    let cursor = append ? occurrenceCursor : nil
                    if append && cursor == nil { break }
                    let result = try await provider.perform(.occurrences(.init(cursor: cursor, limit: 50, searchTerm: query, threadID: threadID)))
                    guard valid(binding, section: loadingSection), searchGeneration == searchVersion else { return }
                    guard case .occurrences(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    if !append { occurrences = []; occurrenceCursors = [] }
                    if let cursor { occurrenceCursors.insert(cursor) }
                    var byID = Dictionary(occurrences.map { (CodexThreadOccurrenceIdentity($0), $0) }, uniquingKeysWith: { _, last in last })
                    var order = occurrences.map(CodexThreadOccurrenceIdentity.init)
                    for value in page.data {
                        let id = CodexThreadOccurrenceIdentity(value)
                        if byID[id] == nil { order.append(id) }
                        byID[id] = value
                    }
                    occurrences = order.compactMap { byID[$0] }
                    occurrenceCursor = nil
                    occurrenceCursor = try nextCursor(page.nextCursor, seen: occurrenceCursors)
                case .approvals:
                    let reviews = await provider.deniedReviews(threadID: threadID)
                    guard valid(binding, section: loadingSection) else { return }
                    deniedReviews = reviews.filter { !approvedReviewIDs.contains($0.id) }
                case .goal:
                    let result = try await provider.perform(.goal(.init(threadID: threadID)))
                    guard valid(binding, section: loadingSection) else { return }
                    guard case .goal(let value) = result else { throw CodexThreadFeatureError.unexpectedResponse }
                    goal = value
                    goalDraft.objective = value?.objective ?? ""
                    goalDraft.tokenBudget = value?.tokenBudget.map(String.init) ?? ""
                }
            } catch {
                guard valid(binding, section: loadingSection) else { return }
                errorMessage = CodexErrorFormat.localizedDescription(error)
            }
            guard valid(binding, section: loadingSection) else { return }
            isLoading = false
        }
        readTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func findOccurrences(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 4_096 else {
            errorMessage = "Enter a search term under 4 KiB."; return
        }
        searchGeneration &+= 1
        searchDraft = query; searchQuery = query
        occurrences = []; occurrenceCursor = nil; occurrenceCursors = []
        await activate(.search)
    }

    func openOccurrence(_ value: CodexSchemaThreadSearchOccurrence) async {
        guard let threadID, occurrences.contains(value) else { return }
        await onOpenOccurrence?(threadID, value)
    }

    func loadLoadedThreads(append: Bool = false) async {
        guard !isLoadingLoaded, let provider else { return }
        let binding = generation, cursor = append ? loadedCursor : nil
        if append && cursor == nil { return }
        isLoadingLoaded = true
        defer { if generation == binding { isLoadingLoaded = false } }
        do {
            let result = try await provider.perform(.loaded(.init(cursor: cursor, limit: 50)))
            guard generation == binding else { return }
            guard case .loaded(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
            if !append { loadedThreadIDs = []; loadedCursors = [] }
            if let cursor { loadedCursors.insert(cursor) }
            var seen = Set(loadedThreadIDs)
            loadedThreadIDs.append(contentsOf: page.data.filter { seen.insert($0).inserted })
            loadedCursor = nil
            loadedCursor = try nextCursor(page.nextCursor, seen: loadedCursors)
        } catch { if generation == binding { errorMessage = CodexErrorFormat.localizedDescription(error) } }
    }

    /// Requires the exact retained denial and a separate human confirmation.
    func approveDeniedActionConfirmed(_ value: CodexGuardianDeniedReview) async {
        guard let threadID, let event = value.event, deniedReviews.contains(value), !isMutating else { return }
        let binding = generation
        guard await mutate(.approveGuardian(.init(event: event, threadID: threadID)),
                           message: "The exact reviewed action is permitted when Codex continues.", refreshAfter: false),
              generation == binding else { return }
        approvedReviewIDs.insert(value.id)
        await refresh()
    }

    func loadMoreTurns() async {
        guard section == .history, let provider, let threadID, turnsCursor != nil, !isLoading else { return }
        readTask?.cancel()
        let binding = generation
        isLoading = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await loadTurns(provider: provider, threadID: threadID, binding: binding, append: true) }
            catch {
                guard valid(binding, section: .history) else { return }
                errorMessage = CodexErrorFormat.localizedDescription(error)
            }
            guard valid(binding, section: .history) else { return }
            isLoading = false
        }
        readTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func loadTurns(provider: any CodexThreadFeatureProvider, threadID: String, binding: Int, append: Bool) async throws {
        let cursor = append ? turnsCursor : nil
        let result = try await provider.perform(.turns(.init(cursor: cursor, itemsView: .summary, limit: 50, sortDirection: .desc, threadID: threadID)))
        guard valid(binding, section: .history) else { return }
        guard case .turns(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
        if !append { turns = []; turnCursors = [] }
        if let cursor { turnCursors.insert(cursor) }
        var seen = Set(turns.map(\.id))
        for value in page.data where seen.insert(value.id).inserted { turns.append(value) }
        turnsCursor = nil
        turnsCursor = try nextCursor(page.nextCursor, seen: turnCursors)
    }

    private func loadQueue(provider: any CodexThreadFeatureProvider, threadID: String, binding: Int) async throws -> [CodexSchemaQueuedSubmission]? {
        var cursor: String?
        var seenCursors: Set<String> = [], seenIDs: Set<String> = []
        var complete: [CodexSchemaQueuedSubmission] = []
        repeat {
            let result = try await provider.perform(.queue(.init(cursor: cursor, limit: 100, threadID: threadID)))
            guard valid(binding, section: .queue) else { return nil }
            guard case .queue(let page) = result else { throw CodexThreadFeatureError.unexpectedResponse }
            if let cursor { seenCursors.insert(cursor) }
            for item in page.data {
                guard seenIDs.insert(item.id).inserted else { throw CodexThreadFeatureError.invalidQueue }
                complete.append(item)
            }
            guard complete.count <= 10_000, seenCursors.count < 1_000 else {
                throw CodexThreadFeatureError.invalidSettings("The queue is too large to edit here. Start pending messages and refresh.")
            }
            cursor = try nextCursor(page.nextCursor, seen: seenCursors)
        } while cursor != nil
        return complete
    }

    @discardableResult
    func addResource() async -> Bool {
        guard let threadID else { return false }
        do {
            let request = try resourceDraft.parameters(threadID: threadID)
            let succeeded = await mutate(.addAttachment(request), message: "Resource attached to this chat.")
            if succeeded { resourceDraft = .init() }
            return succeeded
        } catch { errorMessage = CodexErrorFormat.localizedDescription(error); return false }
    }

    func removeAttachment(_ item: CodexSchemaThreadAttachment) async {
        guard let threadID else { return }
        _ = await mutate(.removeAttachment(.init(attachmentType: item.attachmentType, identityKey: item.identityKey, threadID: threadID)), message: "Attachment removed.")
    }

    func setMemoryMode(_ mode: CodexSchemaThreadMemoryMode) async {
        guard let threadID else { return }
        _ = await mutate(.memoryMode(.init(mode: mode, threadID: threadID)), message: "Chat memory mode updated.")
    }

    /// Called only after the view's explicit global reset confirmation.
    func resetMemoryConfirmed() async { _ = await mutate(.resetMemory, message: "Codex memory reset.") }

    func saveSettings() async {
        guard let threadID else { return }
        do {
            let params = try settingsDraft.parameters(threadID: threadID)
            _ = await mutate(.settings(params), message: "Defaults for subsequent turns updated.")
        } catch { errorMessage = CodexErrorFormat.localizedDescription(error) }
    }

    func saveMetadata() async {
        guard let threadID else { return }
        let daybreak = settingsDraft.daybreak
        let projectID = settingsDraft.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectID.utf8.count <= 512 else { errorMessage = "Choose a valid project."; return }
        _ = await mutate(.metadata(.init(
            daybreakEnabled: daybreak.isEmpty ? nil : daybreak == "enabled",
            projectID: projectID.isEmpty ? nil : projectID,
            threadID: threadID
        )), message: "Chat metadata updated.")
    }

    func moveQueuedSubmission(id: String, offset: Int) async {
        guard queueIsComplete, !isLoading, let threadID, let index = queue.firstIndex(where: { $0.id == id }),
              queue.indices.contains(index + offset), abs(offset) == 1 else { return }
        var ids = queue.map(\.id)
        guard Set(ids).count == ids.count else { errorMessage = CodexThreadFeatureError.invalidQueue.localizedDescription; return }
        ids.swapAt(index, index + offset)
        _ = await mutate(.reorderQueue(.init(queuedSubmissionIDs: ids, threadID: threadID)), message: "Queue order updated.")
    }

    func startQueuedSubmission(id: String) async {
        guard let threadID, queue.contains(where: { $0.id == id }) else { return }
        _ = await mutate(.startQueue(.init(queuedSubmissionID: id, threadID: threadID)), message: "Queued message started.")
    }

    func saveGoal() async {
        guard let threadID else { return }
        do {
            _ = await mutate(.setGoal(try goalDraft.parameters(threadID: threadID)), message: "Goal updated.")
        } catch { errorMessage = CodexErrorFormat.localizedDescription(error) }
    }

    func setGoalPaused(_ paused: Bool) async {
        guard let threadID, goal != nil else { return }
        _ = await mutate(.setGoal(.init(status: paused ? .paused : .active, threadID: threadID)), message: paused ? "Goal paused." : "Goal resumed.")
    }

    func clearGoalConfirmed() async {
        guard let threadID else { return }
        _ = await mutate(.clearGoal(.init(threadID: threadID)), message: "Goal cleared.")
    }

    /// Called only after the view confirms the exact turn and thread scope.
    func revertConfirmed(beforeTurnID: String) async {
        guard let threadID, turns.contains(where: { $0.id == beforeTurnID }), !isMutating else { return }
        let binding = generation
        guard await mutate(.revert(.init(beforeTurnID: beforeTurnID, threadID: threadID)), message: "Chat history reverted.", refreshAfter: false),
              generation == binding else { return }
        await onHistoryChanged?(threadID)
        if generation == binding { await refresh() }
    }

    /// Called only after the view's permanent deletion confirmation.
    func deleteThreadConfirmed() async {
        guard let threadID, !isMutating else { return }
        let binding = generation
        guard await mutate(.delete(.init(threadID: threadID)), message: "Chat deleted.", refreshAfter: false),
              generation == binding else { return }
        await onThreadDeleted?(threadID)
        if generation == binding { bind(provider: nil, threadID: nil) }
    }

    private func mutate(_ request: CodexThreadFeatureRequest, message: String, refreshAfter: Bool = true) async -> Bool {
        guard !isMutating, let provider, threadID != nil else { return false }
        let binding = generation
        isMutating = true
        errorMessage = nil
        activityMessage = nil
        let task = Task { [weak self] in
            do {
                _ = try await provider.perform(request)
                guard !Task.isCancelled, let self, generation == binding else { return false }
                activityMessage = message
                isMutating = false
                if refreshAfter { await refresh() }
                return true
            } catch {
                guard !Task.isCancelled, let self, generation == binding else { return false }
                errorMessage = CodexErrorFormat.localizedDescription(error)
                isMutating = false
                return false
            }
        }
        mutationTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func valid(_ binding: Int, section: CodexThreadFeatureSection) -> Bool {
        !Task.isCancelled && generation == binding && self.section == section
    }

    private func nextCursor(_ cursor: String?, seen: Set<String>) throws -> String? {
        guard let cursor else { return nil }
        guard !seen.contains(cursor) else {
            throw CodexThreadFeatureError.invalidSettings("Codex repeated a pagination cursor. Refresh to continue safely.")
        }
        return cursor
    }

    private func scalar(_ key: String) -> String {
        if case .string(let value)? = currentSettings[key] { value } else { "" }
    }
}
