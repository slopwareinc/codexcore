import Foundation
import Testing
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
@Suite("Thread feature workflows")
struct CodexThreadFeatureControllerTests {
    @Test("Durable attachments follow cursors, replace duplicates, and remove by exact identity")
    func attachmentPagination() async {
        let first = attachment("a", title: "Old")
        let updated = attachment("a", title: "New")
        let second = attachment("b", title: "Second")
        let provider = ThreadFeatureFixtureProvider(attachmentPages: [
            .init(data: [first], nextCursor: "page-2"),
            .init(data: [updated, second]),
            .init(data: [second]),
        ])
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "thread-a")
        await controller.activate(.attachments)
        await controller.loadMore()
        #expect(controller.attachments.map(\.id) == ["a", "b"])
        #expect(controller.attachments.first?.payload == updated.payload)
        #expect(controller.attachmentCursor == nil)
        await controller.removeAttachment(updated)
        #expect(await provider.requests.contains(.removeAttachment(.init(attachmentType: "link", identityKey: "https://example.com/a", threadID: "thread-a"))))
        #expect(controller.attachments.map(\.id) == ["b"])
    }

    @Test("Resources validate paths, credential-free HTTP links, and pull request identities")
    func resourceValidation() throws {
        let link = try CodexThreadResourceDraft(kind: .link, title: "Docs", location: "HTTPS://EXAMPLE.COM/docs#page").parameters(threadID: "t")
        #expect(link.identityKey == "https://example.com/docs")
        #expect(link.payload.objectValue?["title"] == .string("Docs"))
        let file = try CodexThreadResourceDraft(kind: .file, location: "/tmp/one/../two").parameters(threadID: "t")
        #expect(file.identityKey == "/tmp/two")
        let pr = try CodexThreadResourceDraft(kind: .pullRequest, location: "https://github.com/org/repo/pull/23?diff=1#files").parameters(threadID: "t")
        #expect(pr.attachmentType == "pull_request")
        #expect(pr.identityKey == "https://github.com/org/repo/pull/23")
        for bad in ["javascript:alert(1)", "file:///tmp/a", "https://name:secret@example.com", "https://example.com/\npath"] {
            #expect(throws: (any Error).self) {
                try CodexThreadResourceDraft(kind: .link, location: bad).parameters(threadID: "t")
            }
        }
        #expect(throws: (any Error).self) { try CodexThreadResourceDraft(kind: .file, location: "relative/path").parameters(threadID: "t") }
        #expect(throws: (any Error).self) { try CodexThreadResourceDraft(kind: .pullRequest, location: "https://github.com/org/repo/issues/23").parameters(threadID: "t") }
    }

    @Test("Invalid resource drafts never send a mutation")
    func rejectsInvalidResourceBeforeRPC() async {
        let provider = ThreadFeatureFixtureProvider()
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "thread-a")
        controller.resourceDraft = .init(kind: .link, location: "javascript:bad")
        #expect(await controller.addResource() == false)
        #expect(await provider.requests.isEmpty)
        #expect(controller.errorMessage != nil)
    }

    @Test("Switching chats ignores a delayed attachment response")
    func ignoresStaleRead() async {
        let provider = ThreadFeatureFixtureProvider(attachmentPages: [.init(data: [attachment("old")])], holdsAttachmentReads: true)
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "old-thread")
        let read = Task { await controller.activate(.attachments) }
        await provider.waitForHeldRead()
        controller.bind(provider: ThreadFeatureFixtureProvider(), threadID: "new-thread")
        await provider.releaseHeldRead()
        await read.value
        #expect(controller.threadID == "new-thread")
        #expect(controller.attachments.isEmpty)
        #expect(controller.isLoading == false)
    }

    @Test("A failed refresh preserves loaded resources and displays the error")
    func preservesDataAfterFailure() async {
        let provider = ThreadFeatureFixtureProvider(attachmentPages: [.init(data: [attachment("a")])])
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.attachments)
        await provider.failNext()
        await controller.refresh()
        #expect(controller.attachments.map(\.id) == ["a"])
        #expect(controller.errorMessage != nil)
        #expect(!controller.isLoading)
    }

    @Test("Memory mode uses the exact thread, then rereads authoritative mode and global readiness")
    func memoryMode() async {
        let provider = ThreadFeatureFixtureProvider()
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.memory)
        #expect(controller.memoryMode == nil)
        #expect(controller.memoryStatus?.v2ConsolidatedThreads == 4)
        await controller.setMemoryMode(.disabled)
        #expect(controller.memoryMode == .disabled)
        #expect(await provider.requests.contains(.memoryMode(.init(mode: .disabled, threadID: "t"))))
        await controller.resetMemoryConfirmed()
        #expect(await provider.requests.contains(.resetMemory))
    }

    @Test("Queue ordering sends the complete authoritative permutation and explicit start ID")
    func queueActions() async {
        let provider = ThreadFeatureFixtureProvider(queue: [queued("a"), queued("b"), queued("c")])
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.queue)
        await controller.moveQueuedSubmission(id: "b", offset: -1)
        #expect(await provider.requests.contains(.reorderQueue(.init(queuedSubmissionIDs: ["b", "a", "c"], threadID: "t"))))
        #expect(controller.queue.map(\.id) == ["b", "a", "c"])
        await controller.startQueuedSubmission(id: "b")
        #expect(await provider.requests.contains(.startQueue(.init(queuedSubmissionID: "b", threadID: "t"))))
        #expect(controller.queue.map(\.id) == ["a", "c"])
    }

    @Test("History is paginated and revert reloads canonical host history only after success")
    func historyRevert() async {
        let provider = ThreadFeatureFixtureProvider()
        let controller = CodexThreadFeatureController()
        var reconciled: [String] = []
        controller.onHistoryChanged = { reconciled.append($0) }
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.history)
        #expect(controller.turns.map(\.id) == ["turn-1"])
        await provider.failNext()
        await controller.revertConfirmed(beforeTurnID: "turn-1")
        #expect(reconciled.isEmpty)
        await controller.revertConfirmed(beforeTurnID: "turn-1")
        #expect(reconciled == ["t"])
        #expect(await provider.requests.contains(.revert(.init(beforeTurnID: "turn-1", threadID: "t"))))
    }

    @Test("Delete notifies the exact host scope after success and clears inspector state")
    func threadDeletion() async {
        let controller = CodexThreadFeatureController()
        var deleted: [String] = []
        controller.onThreadDeleted = { deleted.append($0) }
        controller.bind(provider: ThreadFeatureFixtureProvider(), threadID: "t")
        await controller.deleteThreadConfirmed()
        #expect(deleted == ["t"])
        #expect(controller.threadID == nil)
    }

    @Test("Settings keep omitted fields distinct from explicit plugin reset and metadata changes")
    func settingsAndMetadata() async {
        let provider = ThreadFeatureFixtureProvider()
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.settings)
        controller.settingsDraft = .init(model: "gpt-new", effort: "high", personality: "friendly", serviceTier: "fast", daybreak: "enabled", projectID: "project-1", updatesDisabledPlugins: true)
        await controller.saveSettings()
        #expect(await provider.requests.contains(.settings(.init(disabledPluginIDs: [], effort: CodexSchemaReasoningEffort(.string("high")), model: "gpt-new", personality: .friendly, serviceTier: "fast", threadID: "t"))))
        controller.settingsDraft.daybreak = "enabled"
        controller.settingsDraft.projectID = "project-1"
        await controller.saveMetadata()
        #expect(await provider.requests.contains(.metadata(.init(daybreakEnabled: true, projectID: "project-1", threadID: "t"))))
    }

    @Test("Goal edits validate budgets, preserve paused state, and route explicit pause/resume/clear")
    func goals() async throws {
        let provider = ThreadFeatureFixtureProvider()
        let controller = CodexThreadFeatureController()
        controller.bind(provider: provider, threadID: "t")
        await controller.activate(.goal)
        #expect(controller.goal == nil)
        controller.goalDraft = .init(objective: "Complete the feature stack", tokenBudget: "12000")
        await controller.saveGoal()
        #expect(controller.goal?.tokenBudget == 12_000)
        await controller.setGoalPaused(true)
        #expect(controller.goal?.status == .paused)
        await controller.setGoalPaused(false)
        #expect(controller.goal?.status == .active)
        await controller.clearGoalConfirmed()
        #expect(controller.goal == nil)
        for invalid in ["0", "-1", "1.5", "99999999999999999999999999"] {
            #expect(throws: (any Error).self) { try CodexThreadGoalDraft(objective: "Goal", tokenBudget: invalid).parameters(threadID: "t") }
        }
        #expect(try CodexThreadGoalDraft(objective: "Goal", tokenBudget: "").parameters(threadID: "t").tokenBudget == nil)
    }

    private func attachment(_ id: String, title: String = "Resource") -> CodexSchemaThreadAttachment {
        .init(attachmentType: "link", createdAt: 0, id: id, identityKey: "https://example.com/\(id)", payload: .dictionary(["title": .string(title)]))
    }
    private func queued(_ id: String) -> CodexSchemaQueuedSubmission {
        .init(clientUserMessageID: "client-\(id)", id: id, input: [CodexSchemaUserInput(.dictionary(["type": .string("text"), "text": .string(id)]))])
    }
}

private actor ThreadFeatureFixtureProvider: CodexThreadFeatureProvider {
    private(set) var requests: [CodexThreadFeatureRequest] = []
    private var attachmentPages: [CodexSchemaThreadAttachmentListResponse]
    private var queue: [CodexSchemaQueuedSubmission]
    private var currentSettings: [String: CodexJSONValue] = [:]
    private var currentGoal: CodexSchemaThreadGoal?
    private var shouldFail = false
    private let holdsAttachmentReads: Bool
    private var heldRead: CheckedContinuation<Void, Never>?

    init(attachmentPages: [CodexSchemaThreadAttachmentListResponse] = [], queue: [CodexSchemaQueuedSubmission] = [], holdsAttachmentReads: Bool = false) {
        self.attachmentPages = attachmentPages
        self.queue = queue
        self.holdsAttachmentReads = holdsAttachmentReads
    }

    func failNext() { shouldFail = true }
    func waitForHeldRead() async { while heldRead == nil { await Task.yield() } }
    func releaseHeldRead() { heldRead?.resume(); heldRead = nil }
    func settings(threadID: String) async -> [String: CodexJSONValue]? { currentSettings }

    func perform(_ request: CodexThreadFeatureRequest) async throws -> CodexThreadFeatureResponse {
        requests.append(request)
        if shouldFail { shouldFail = false; throw CodexThreadFeatureError.invalidSettings("Fixture failure") }
        switch request {
        case .attachments:
            if holdsAttachmentReads { await withCheckedContinuation { heldRead = $0 } }
            return .attachments(attachmentPages.isEmpty ? .init(data: []) : attachmentPages.removeFirst())
        case .memoryStatus: return .memory(.init(v2ConsolidatedThreads: 4, v2Ready: false))
        case .memoryMode(let params): currentSettings["memoryMode"] = .string(params.mode.rawValue); return .mutation
        case .queue: return .queue(.init(data: queue))
        case .reorderQueue(let params):
            queue = params.queuedSubmissionIDs.compactMap { id in queue.first { $0.id == id } }
            return .mutation
        case .startQueue(let params):
            queue.removeAll { $0.id == params.queuedSubmissionID }
            return .turn(.init(id: "started", items: [], status: .inProgress))
        case .timeline: return .timeline(.init(data: [CodexSchemaThreadTimelineEntry(.dictionary(["id": .string("event-1"), "type": .string("turn"), "turnId": .string("turn-1")]))]))
        case .turns: return .turns(.init(data: [.init(id: "turn-1", items: [], status: .completed)]))
        case .read, .metadata, .revert: return .thread(try fixtureThread())
        case .goal: return .goal(currentGoal)
        case .setGoal(let params):
            currentGoal = .init(createdAt: 0, objective: params.objective ?? currentGoal?.objective ?? "Goal", status: params.status ?? currentGoal?.status ?? .active, threadID: params.threadID, timeUsedSeconds: 0, tokenBudget: params.tokenBudget ?? currentGoal?.tokenBudget, tokensUsed: 0, updatedAt: 0)
            return .goal(currentGoal)
        case .clearGoal: currentGoal = nil; return .mutation
        default: return .mutation
        }
    }

    private func fixtureThread() throws -> CodexSchemaThread {
        try CodexJSONValue.dictionary([
            "id": .string("t"), "cliVersion": .string("0.160.0"), "createdAt": .int(0), "updatedAt": .int(0),
            "cwd": .string("/tmp"), "ephemeral": .bool(false), "modelProvider": .string("openai"),
            "projectId": .null, "preview": .string("Fixture"), "sessionId": .string("s"), "source": .string("appServer"),
            "status": .dictionary(["type": .string("idle")]), "turns": .array([]), "historyMode": .string("paginated"),
        ]).decode(CodexSchemaThread.self)
    }
}

@MainActor
@Suite("Live turn settings")
struct CodexLiveTurnSettingsControllerTests {
    @Test("Picker updates serialize and coalesce the complete desired selection")
    func serializesUpdates() async throws {
        let provider = LiveSettingsFixtureProvider(hold: true)
        let controller = CodexLiveTurnSettingsController()
        controller.bind(provider: provider, target: .init(threadID: .init("t"), turnID: .init("turn")))
        controller.submit(model: "model-a", effort: CodexSchemaReasoningEffort(.string("low")), serviceTier: .value("fast"))
        await provider.waitForRequestCount(1)
        controller.submit(model: "model-b", effort: CodexSchemaReasoningEffort(.string("medium")), serviceTier: .value("fast"))
        controller.submit(model: "model-c", effort: CodexSchemaReasoningEffort(.string("high")), serviceTier: .null)
        await provider.release()
        await provider.waitForRequestCount(2)
        await provider.release()
        await controller.waitUntilIdle()
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[0]["model"] == .string("model-a"))
        #expect(requests[1]["model"] == .string("model-c"))
        #expect(requests[1]["serviceTier"] == .null)
        #expect(requests[1]["turnId"] == .string("turn"))
        #expect(!controller.isUpdating)
    }

    @Test("An ended turn never redirects the update to a replacement turn")
    func unavailableTarget() async {
        let provider = LiveSettingsFixtureProvider(status: "targetUnavailable")
        let controller = CodexLiveTurnSettingsController()
        controller.bind(provider: provider, target: .init(threadID: .init("t"), turnID: .init("old")))
        controller.submit(model: "model", effort: CodexSchemaReasoningEffort(.string("high")), serviceTier: .omitted)
        await controller.waitUntilIdle()
        #expect(await provider.requests.count == 1)
        #expect(controller.message?.contains("next turn") == true)
        #expect(controller.errorMessage == nil)
    }

    @Test("Changing target seals delayed completions and retains no pending update")
    func switchesTargetSafely() async {
        let provider = LiveSettingsFixtureProvider(hold: true)
        let controller = CodexLiveTurnSettingsController()
        controller.bind(provider: provider, target: .init(threadID: .init("old"), turnID: .init("turn")))
        controller.submit(model: "model", effort: CodexSchemaReasoningEffort(.string("high")), serviceTier: .null)
        await provider.waitForRequestCount(1)
        controller.bind(provider: nil, target: nil)
        await provider.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.message == nil)
        #expect(controller.errorMessage == nil)
        #expect(!controller.isUpdating)
    }
}

private actor LiveSettingsFixtureProvider: CodexAppRuntimeProviding {
    private(set) var requests: [[String: CodexJSONValue]] = []
    private var gate: CheckedContinuation<Void, Never>?
    private let hold: Bool
    private let status: String
    init(hold: Bool = false, status: String = "applied") { self.hold = hold; self.status = status }
    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        requests.append(try request.encodeParameters()?.objectValue ?? [:])
        if hold { await withCheckedContinuation { gate = $0 } }
        return try CodexJSONValue.dictionary(["status": .string(status)]).decode(Response.self)
    }
    func waitForRequestCount(_ count: Int) async { while requests.count < count { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
}
