import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexNativeChatActionTests {
    @Test func delayedForkReleasesUnusedSubscriptionAndPreservesNewSelection() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        await fixture.transport.hold("thread/fork")
        await fixture.transport.hold("thread/unsubscribe", threadID: "fork")
        model.draft = "Source draft"
        let fork = Task { await model.forkCurrentChat() }
        await fixture.transport.waitForHeldRequest("thread/fork")

        await model.resumeChat(id: "replacement")
        let replacement = try #require(model.currentThreadLease)
        model.draft = "Replacement draft"
        try await fixture.transport.release("thread/fork")
        await fork.value
        await fixture.transport.waitForHeldRequest("thread/unsubscribe", threadID: "fork")

        #expect(model.currentThreadLease === replacement)
        #expect(!replacement.isClosed)
        #expect(model.currentThreadID == "replacement")
        #expect(model.draft == "Replacement draft")
        try await fixture.transport.release("thread/unsubscribe", threadID: "fork")
        #expect(await fixture.transport.unsubscribedThreadIDs.contains("fork"))
        #expect(model.chatActionError == nil)
        await model.disconnect()
    }

    @Test func failedForkRetainsSourceDraftAndDisplaysActionError() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        let source = try #require(model.currentThreadLease)
        model.draft = "Unfinished source draft"
        await fixture.transport.fail("thread/fork", message: "Fork request rejected.")

        await model.forkCurrentChat()

        #expect(model.currentThreadLease === source)
        #expect(!source.isClosed)
        #expect(model.currentThreadID == "source")
        #expect(model.draft == "Unfinished source draft")
        #expect(model.chatActionError?.contains("Fork request rejected.") == true)
        model.clearChatActionError()
        #expect(model.chatActionError == nil)
        await model.disconnect()
    }

    @Test func staleForkFailureCannotDisplayAnErrorInTheReplacementChat() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        await fixture.transport.hold("thread/fork")
        let fork = Task { await model.forkCurrentChat() }
        await fixture.transport.waitForHeldRequest("thread/fork")
        await model.resumeChat(id: "replacement")
        model.draft = "Replacement draft"
        await fixture.transport.fail("thread/fork", message: "Old fork failed.")

        try await fixture.transport.release("thread/fork")
        await fork.value

        #expect(model.currentThreadID == "replacement")
        #expect(model.draft == "Replacement draft")
        #expect(model.chatActionError == nil)
        await model.disconnect()
    }

    @Test func selectedTurnBoundaryIsSentToTheForkRequest() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model

        await model.forkChat(from: .init(threadID: "source", lastTurnID: "earlier-turn"))

        let params = try #require(await fixture.transport.lastParameters(for: "thread/fork"))
        #expect(params["threadId"] == .string("source"))
        #expect(params["lastTurnId"] == .string("earlier-turn"))
        #expect(model.currentThreadID == "fork")
        #expect(model.chatActionError == nil)
        await model.disconnect()
    }

    @Test func staleOrUnknownNativeTurnRequestsCannotForkTheCurrentChat() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        let source = try #require(model.currentThreadLease)
        model.draft = "Unfinished draft"

        await model.forkChat(from: .init(threadID: "replacement", lastTurnID: "earlier-turn"))
        await model.forkChat(from: .init(threadID: "source", lastTurnID: "unknown-turn"))

        #expect(await fixture.transport.lastParameters(for: "thread/fork") == nil)
        #expect(model.currentThreadLease === source)
        #expect(!source.isClosed)
        #expect(model.draft == "Unfinished draft")
        await model.disconnect()
    }

    @Test func failedStopKeepsTheRunningTurnAndDisplaysActionError() async throws {
        let fixture = try await connectedFixture(runningTurn: true)
        let model = fixture.model
        let turn = try #require(model.activeTurnLease)
        await fixture.transport.fail("turn/interrupt", message: "Stop request rejected.")

        await model.interrupt()

        let params = try #require(await fixture.transport.lastParameters(for: "turn/interrupt"))
        #expect(params["threadId"] == .string("source"))
        #expect(params["turnId"] == .string("latest-turn"))
        #expect(model.activeTurnLease?.key == turn.key)
        #expect(model.isSending)
        #expect(model.chatActionError?.contains("Stop request rejected.") == true)
        await model.disconnect()
    }

    @Test func failedReviewPreservesTheDraftAndDisplaysActionError() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        model.draft = "Unfinished draft"
        await fixture.transport.fail("review/start", message: "Review request rejected.")

        await model.startCodeReview(.baseBranch("main"))

        let params = try #require(await fixture.transport.lastParameters(for: "review/start"))
        #expect(params["threadId"] == .string("source"))
        #expect(params["delivery"] == .string("inline"))
        #expect(params["target"]?.objectValue?["branch"] == .string("main"))
        #expect(model.currentThreadID == "source")
        #expect(model.draft == "Unfinished draft")
        #expect(model.chatActionError?.contains("Review request rejected.") == true)
        await model.disconnect()
    }

    @Test func staleReviewFailureCannotOverwriteNewerActionFeedback() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        await fixture.transport.hold("review/start")
        let review = Task { await model.startCodeReview(.uncommittedChanges) }
        await fixture.transport.waitForHeldRequest("review/start")
        await model.resumeChat(id: "replacement")
        await fixture.transport.fail("thread/fork", message: "Replacement fork rejected.")
        await model.forkCurrentChat()
        let replacementError = try #require(model.chatActionError)
        await fixture.transport.fail("review/start", message: "Old review failed.")

        try await fixture.transport.release("review/start")
        await review.value

        #expect(model.currentThreadID == "replacement")
        #expect(model.chatActionError == replacementError)
        await model.disconnect()
    }

    @Test func selectingRecoveredNativeDraftRestoresItsWorkspaceBeforeResuming() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        let workspaceA = "/private/tmp/project-a"
        let workspaceB = "/private/tmp/project-b"
        model.workspacePath = workspaceA
        model.isProjectlessDraft = false
        model.sidebarNavigationSession.selectProject("project-a", workspacePath: workspaceA)
        let recoveredID = CodexComposerDraftID(rawValue: "draft:recovered-project-b")
        let recoveredRecord = CodexComposerDraftSnapshot(
            draftID: recoveredID, threadID: "recovered-thread", workspacePath: workspaceB,
            projectID: "project-b", prompt: "Recovered project B draft"
        )
        let restored = try CodexComposerStateSession(restoring: .init(
            activeDraftID: recoveredID, drafts: [recoveredRecord]
        ))
        model.composerSession.mergeDrafts(from: restored)
        let resumeCount = await fixture.transport.requestCount(for: "thread/resume")

        await model.selectComposerDraft(recoveredID)

        let params = try #require(await fixture.transport.lastParameters(for: "thread/resume"))
        #expect(params["threadId"] == .string("recovered-thread"))
        #expect(params["cwd"] == .string(workspaceB))
        #expect(params["runtimeWorkspaceRoots"] == .array([.string(workspaceB)]))
        #expect(await fixture.transport.requestCount(for: "thread/resume") == resumeCount + 1)
        #expect(await fixture.transport.requestCount(for: "thread/start") == 0)
        #expect(await fixture.transport.requestCount(for: "turn/start") == 0)
        #expect(model.currentThreadID == "recovered-thread")
        #expect(model.workspacePath == workspaceB)
        #expect(model.sidebarNavigationSession.selectedProjectID == "project-b")
        #expect(!model.isProjectlessDraft)
        #expect(model.composerSession.activeDraftID == recoveredID)
        #expect(model.draft == "Recovered project B draft")
        let selected = try #require(model.composerDraftRecords.first { $0.draftID == recoveredID })
        #expect(selected.workspacePath == workspaceB)
        #expect(selected.projectID == "project-b")
        #expect(selected.threadID == "recovered-thread")
        await model.disconnect()
    }

    @Test func repeatedForkWhileItsRequestIsPendingCreatesOnlyOneThread() async throws {
        let fixture = try await connectedFixture()
        await fixture.transport.hold("thread/fork")
        let first = Task { await fixture.model.forkCurrentChat() }
        await fixture.transport.waitForHeldRequest("thread/fork")
        await fixture.model.forkCurrentChat()
        #expect(await fixture.transport.heldRequestCount("thread/fork") == 1)
        try await fixture.transport.release("thread/fork")
        await first.value
        #expect(await fixture.transport.requestCount(for: "thread/fork") == 1)
        #expect(fixture.model.currentThreadID == "fork")
        await fixture.model.disconnect()
    }

    @Test func lateStopFailureCannotReplaceNewerFeedbackInTheSameChat() async throws {
        let fixture = try await connectedFixture(runningTurn: true)
        await fixture.transport.hold("turn/interrupt")
        let stop = Task { await fixture.model.interrupt() }
        await fixture.transport.waitForHeldRequest("turn/interrupt")
        await fixture.transport.fail("review/start", message: "New review rejected.")
        await fixture.model.startCodeReview(.uncommittedChanges)
        let latestError = try #require(fixture.model.chatActionError)
        await fixture.transport.fail("turn/interrupt", message: "Old Stop rejected.")
        try await fixture.transport.release("turn/interrupt")
        await stop.value
        #expect(fixture.model.chatActionError == latestError)
        await fixture.model.disconnect()
    }

    private func connectedFixture(runningTurn: Bool = false) async throws -> (
        model: CodexCoreAppModel, transport: NativeChatActionTransport
    ) {
        let transport = NativeChatActionTransport(runningTurn: runningTurn)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: transport.homePath))
        )
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
        model.codex = codex
        await model.resumeChat(id: "source")
        #expect(model.currentThreadID == "source")
        return (model, transport)
    }
}

private actor NativeChatActionTransport: CodexFrameTransport {
    nonisolated let homePath = "/private/tmp/codexcore-native-actions-\(UUID().uuidString)"
    private let runningTurn: Bool
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var heldKeys: Set<String> = []
    private var heldFrames: [String: [Data]] = [:]
    private var heldWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var failures: [String: String] = [:]
    private var parametersByMethod: [String: [String: CodexJSONValue]] = [:]
    private var requestCounts: [String: Int] = [:]
    private(set) var unsubscribedThreadIDs: [String] = []

    init(runningTurn: Bool) { self.runningTurn = runningTurn }

    func hold(_ method: String, threadID: String? = nil) {
        heldKeys.insert(key(method, threadID: threadID))
    }

    func fail(_ method: String, message: String) { failures[method] = message }

    func lastParameters(for method: String) -> [String: CodexJSONValue]? {
        parametersByMethod[method]
    }

    func requestCount(for method: String) -> Int { requestCounts[method, default: 0] }

    func heldRequestCount(_ method: String) -> Int { heldFrames[key(method, threadID: nil), default: []].count }

    func waitForHeldRequest(_ method: String, threadID: String? = nil) async {
        let requestKey = key(method, threadID: threadID)
        if !(heldFrames[requestKey] ?? []).isEmpty { return }
        await withCheckedContinuation { heldWaiters[requestKey, default: []].append($0) }
    }

    func release(_ method: String, threadID: String? = nil) throws {
        let requestKey = key(method, threadID: threadID)
        heldKeys.remove(requestKey)
        let frames = heldFrames.removeValue(forKey: requestKey) ?? []
        for frame in frames { try write(frame) }
    }

    func open() -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func write(_ frame: Data) throws {
        let request = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard let fields = request.objectValue,
              case .string(let method)? = fields["method"], let rawID = fields["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let params = fields["params"]?.objectValue ?? [:]
        parametersByMethod[method] = params
        let threadID = CodexJSONCoercion.string(from: params["threadId"]) ?? "source"
        let requestKey = heldKeys.contains(key(method, threadID: threadID))
            ? key(method, threadID: threadID) : key(method, threadID: nil)
        if heldKeys.contains(requestKey) {
            heldFrames[requestKey, default: []].append(frame)
            for waiter in heldWaiters.removeValue(forKey: requestKey) ?? [] { waiter.resume() }
            return
        }
        requestCounts[method, default: 0] += 1
        if let message = failures[method] {
            continuation?.yield(try CodexJSONRPCCodec.encodeError(
                id: id, error: .init(code: -32000, message: message)
            ))
            return
        }
        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(homePath), "platformFamily": .string("unix"),
                "platformOs": .string("macos"), "userAgent": .string("codex/native-actions-test"),
            ])
        case "account/gatewayOAuth/read":
            result = try CodexJSONValue(encoding: CodexSchemaGatewayOAuthReadResponse(
                providerID: "openai", providerName: "OpenAI", required: false
            ))
        case "thread/read":
            result = .dictionary(["thread": thread(threadID)])
        case "thread/resume", "thread/fork":
            result = .dictionary([
                "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
                "cwd": .string("/private/tmp"), "model": .string("test-model"),
                "modelProvider": .string("openai"), "sandbox": .dictionary(["type": .string("readOnly")]),
                "thread": thread(method == "thread/fork" ? "fork" : threadID),
            ])
        case "thread/unsubscribe":
            unsubscribedThreadIDs.append(threadID)
            result = try CodexJSONValue(encoding: CodexSchemaThreadUnsubscribeResponse(status: .unsubscribed))
        case "thread/backgroundTerminals/list":
            result = try CodexJSONValue(encoding: CodexSchemaThreadBackgroundTerminalsListResponse(data: []))
        case "thread/queue/list":
            result = try CodexJSONValue(encoding: CodexSchemaThreadQueueListResponse(data: []))
        case "thread/goal/get":
            result = try CodexJSONValue(encoding: CodexSchemaThreadGoalGetResponse())
        case "thread/list", "project/list":
            result = .dictionary(["data": .array([])])
        case "review/start":
            result = .dictionary(["reviewThreadId": .string(threadID), "turn": turn("review-turn", running: true)])
        default:
            result = .dictionary([:])
        }
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    private func key(_ method: String, threadID: String?) -> String {
        threadID.map { "\(method):\($0)" } ?? method
    }

    private func thread(_ id: String) -> CodexJSONValue {
        .dictionary([
            "cliVersion": .string("0.160.0"), "createdAt": .int(1), "cwd": .string("/private/tmp"),
            "ephemeral": .bool(false), "historyMode": .string("legacy"), "id": .string(id),
            "modelProvider": .string("openai"), "preview": .string("Native action test"),
            "sessionId": .string("native-action-session"), "source": .string("cli"),
            "status": .dictionary(["type": .string("idle")]),
            "turns": .array([
                turn("earlier-turn", running: false),
                turn("latest-turn", running: runningTurn && id == "source"),
            ]),
            "updatedAt": .int(1),
        ])
    }

    private func turn(_ id: String, running: Bool) -> CodexJSONValue {
        .dictionary([
            "id": .string(id), "items": .array([]),
            "status": .string(running ? "inProgress" : "completed"),
        ])
    }

    func close() {
        continuation?.finish()
        continuation = nil
        try? FileManager.default.removeItem(atPath: homePath)
    }
}
