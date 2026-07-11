import XCTest
import SwiftUI
@testable import CodexCore
@testable import CodexCoreUI

final class CodexAgentUITests: XCTestCase {
    @MainActor
    func testChatStreamSessionOwnsTurnAndGlobalNotificationStreams() async {
        let session = CodexChatStreamSession()
        var mainContinuation: AsyncStream<CodexNotification>.Continuation!
        let mainStream = AsyncStream<CodexNotification> { continuation in
            mainContinuation = continuation
        }
        var globalContinuation: AsyncStream<CodexNotification>.Continuation!
        let globalStream = AsyncStream<CodexNotification> { continuation in
            globalContinuation = continuation
        }
        var receivedMainTurnIDs: [String] = []
        var finishedMainTurnIDs: [String] = []
        var receivedGlobalMethods: [String] = []
        let mainReceived = expectation(description: "main stream delivered notification")
        let mainFinished = expectation(description: "main stream finished")
        let globalReceived = expectation(description: "global stream delivered notification")

        session.consumeMainTurnStream(
            id: "turn-main",
            notifications: mainStream,
            onNotification: { notification in
                receivedMainTurnIDs.append(CodexNotificationMetadata.turnID(from: notification) ?? "")
                mainReceived.fulfill()
            },
            onFinish: { turnID in
                finishedMainTurnIDs.append(turnID)
                mainFinished.fulfill()
            }
        )
        session.consumeGlobalNotificationStream(globalStream) { notification in
            receivedGlobalMethods.append(notification.method)
            globalReceived.fulfill()
        }

        mainContinuation.yield(transcriptNotification(.turnStarted(TurnStartedNotification(
            threadId: "thread-1",
            turn: AppServerTurn(id: "turn-main", status: .inProgress)
        ))))
        mainContinuation.finish()
        globalContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))

        await fulfillment(of: [mainReceived, mainFinished, globalReceived], timeout: 1.0)
        XCTAssertEqual(receivedMainTurnIDs, ["turn-main"])
        XCTAssertEqual(finishedMainTurnIDs, ["turn-main"])
        XCTAssertEqual(receivedGlobalMethods, [CodexAppServerNotificationMethod.skillsChanged.rawValue])
        session.reset()
    }

    @MainActor
    func testChatStreamSessionAppliesRuntimeResultsAndSideChatUpdates() async {
        let session = CodexChatStreamSession()
        var mainContinuation: AsyncStream<CodexNotification>.Continuation!
        let mainStream = AsyncStream<CodexNotification> { continuation in
            mainContinuation = continuation
        }
        var sideContinuation: AsyncStream<CodexNotification>.Continuation!
        let sideStream = AsyncStream<CodexNotification> { continuation in
            sideContinuation = continuation
        }
        var mainActivities: [String] = []
        var sideActivities: [String] = []
        let mainNotificationApplied = expectation(description: "main notification result applied")
        let mainFinishApplied = expectation(description: "main finish result applied")
        let sideNotificationApplied = expectation(description: "side notification update applied")
        let sideFinishApplied = expectation(description: "side finish update applied")

        session.consumeMainTurnResultStream(
            id: "turn-main",
            notifications: mainStream,
            routeNotification: { notification in
                CodexChatNotificationPipelineResult(activities: [
                    CodexActivity(kind: .notice, title: "main", detail: notification.method)
                ])
            },
            finishTurn: { turnID in
                CodexChatNotificationPipelineResult(activities: [
                    CodexActivity(kind: .turn, title: "finished", detail: turnID)
                ])
            },
            applyResult: { result in
                mainActivities.append(contentsOf: result.activities.map(\.detail))
                if result.activities.contains(where: { $0.title == "main" }) {
                    mainNotificationApplied.fulfill()
                }
                if result.activities.contains(where: { $0.title == "finished" }) {
                    mainFinishApplied.fulfill()
                }
            }
        )

        session.consumeSideChatTurnUpdateStream(
            id: "turn-side",
            notifications: sideStream,
            routeNotification: { notification in
                CodexSideChatSessionUpdate(activity: CodexActivity(kind: .notice, title: "side", detail: notification.method))
            },
            finishTurn: { turnID in
                CodexSideChatSessionUpdate(activity: CodexActivity(kind: .turn, title: "side finished", detail: turnID))
            },
            applyUpdate: { update in
                guard let activity = update.activity else { return }
                sideActivities.append(activity.detail)
                if activity.title == "side" {
                    sideNotificationApplied.fulfill()
                }
                if activity.title == "side finished" {
                    sideFinishApplied.fulfill()
                }
            }
        )

        mainContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))
        sideContinuation.yield(transcriptNotification(.known(method: .warning, params: [:])))
        mainContinuation.finish()
        sideContinuation.finish()

        await fulfillment(
            of: [mainNotificationApplied, mainFinishApplied, sideNotificationApplied, sideFinishApplied],
            timeout: 1.0
        )
        XCTAssertEqual(mainActivities, [CodexAppServerNotificationMethod.skillsChanged.rawValue, "turn-main"])
        XCTAssertEqual(sideActivities, [CodexAppServerNotificationMethod.warning.rawValue, "turn-side"])
        session.reset()
    }

    @MainActor
    func testChatRuntimeSessionOwnsStoreBackedStreamBinding() async {
        let session = CodexChatRuntimeSession()
        var globalContinuation: AsyncStream<CodexNotification>.Continuation!
        let globalStream = AsyncStream<CodexNotification> { continuation in
            globalContinuation = continuation
        }
        var sideContinuation: AsyncStream<CodexNotification>.Continuation!
        let sideStream = AsyncStream<CodexNotification> { continuation in
            sideContinuation = continuation
        }
        var globalActions: [CodexChatNotificationPipelineAction] = []
        var sideActivities: [String] = []
        let globalApplied = expectation(description: "global runtime stream applied")
        let sideApplied = expectation(description: "side runtime stream applied")

        _ = session.openSideChat()
        session.consumeGlobalNotificationStream(
            globalStream,
            store: nil,
            currentThreadID: { "thread-1" },
            applyResult: { result in
                globalActions.append(contentsOf: result.actions)
                globalApplied.fulfill()
            }
        )
        session.consumeSideChatTurnStream(
            id: "side-turn-1",
            notifications: sideStream,
            currentThreadID: { "thread-1" },
            store: { nil },
            applyUpdate: { update in
                guard let activity = update.activity else { return }
                sideActivities.append(activity.title)
                if activity.title == "Side chat warning" {
                    sideApplied.fulfill()
                }
            }
        )

        globalContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))
        sideContinuation.yield(transcriptNotification(.known(method: .warning, params: [
            "message": .string("side note"),
            "turnId": .string("side-turn-1")
        ])))
        sideContinuation.finish()

        await fulfillment(of: [globalApplied, sideApplied], timeout: 1.0)
        XCTAssertEqual(globalActions, [.refreshSlashCommands(forceReload: true)])
        XCTAssertEqual(sideActivities, ["Side chat warning"])
        session.reset()
    }

    @MainActor
    func testChatRuntimeSessionOwnsSubmissionLifecycleActivities() async {
        let session = CodexChatRuntimeSession()
        let submission = CodexComposerSubmission(prompt: "Ship it")
        var mainActivities: [CodexActivity] = []
        var goalActivities: [CodexActivity] = []
        var sideActivities: [CodexActivity] = []

        let didStartMain = await session.submitMainTurn(
            submission,
            start: { throw NSError(domain: "CodexRuntimeSessionTests", code: 1) },
            currentThreadID: { "thread-1" },
            store: { nil },
            applyResult: { _ in },
            onActivity: { mainActivities.append($0) },
            errorMessage: { _ in "offline" }
        )
        XCTAssertFalse(didStartMain)
        XCTAssertEqual(mainActivities.map(\.title), ["You asked Codex", "Turn failed to start"])
        XCTAssertFalse(session.isSending)

        let goal = ThreadGoal(
            threadId: "thread-1",
            objective: "Ship it",
            status: .active,
            tokensUsed: 5,
            timeUsedSeconds: 1,
            createdAt: 1,
            updatedAt: 2
        )
        let didStartGoal = await session.submitGoal(
            submission,
            start: { goal },
            onActivity: { goalActivities.append($0) },
            errorMessage: { _ in "goal offline" }
        )
        XCTAssertTrue(didStartGoal)
        XCTAssertEqual(goalActivities.map(\.title), ["Pursuing goal", "Goal started"])
        XCTAssertEqual(session.activeGoal, goal)

        let didStartSideChat = await session.submitSideChat(
            prompt: "side quest",
            start: { throw NSError(domain: "CodexRuntimeSessionTests", code: 2) },
            currentThreadID: { "thread-1" },
            store: { nil },
            applyUpdate: { _ in },
            onActivity: { sideActivities.append($0) },
            errorMessage: { _ in "side offline" }
        )
        XCTAssertFalse(didStartSideChat)
        XCTAssertEqual(sideActivities.map(\.title), [
            "Opened side chat",
            "Side chat asked",
            "Side chat failed to start"
        ])
        XCTAssertFalse(session.isSideChatSending)
    }

    @MainActor
    func testChatRuntimeSessionPopulatesTranscriptV2AndReconcilesOptimisticUser() async throws {
        let session = CodexChatRuntimeSession()
        let submission = CodexComposerSubmission(
            prompt: "Inspect state",
            clientID: "client-user-1"
        )

        _ = await session.submitMainTurn(
            submission,
            start: { throw NSError(domain: "CodexRuntimeSessionTests", code: 1) },
            currentThreadID: { "thread-1" },
            store: { nil },
            applyResult: { _ in },
            onActivity: { _ in },
            errorMessage: { _ in "offline" }
        )

        XCTAssertEqual(session.transcriptV2.turns.count, 1)
        XCTAssertEqual(session.transcriptV2.turns[0].userMessage?.id, "local-client-user-1")
        XCTAssertTrue(session.transcriptV2.turns[0].userMessage?.isOptimistic == true)

        let userItem = try transcriptThreadItem([
            "id": .string("server-user-1"),
            "type": .string("userMessage"),
            "clientId": .string("client-user-1"),
            "content": .array([.dictionary(["type": .string("text"), "text": .string("Inspect state")])])
        ])
        let (stream, continuation) = AsyncStream<CodexNotification>.makeStream()
        session.consumeGlobalNotificationStream(
            stream,
            store: nil,
            currentThreadID: { "thread-1" },
            applyResult: { _ in }
        )
        continuation.yield(transcriptNotification(.turnStarted(.init(
            threadId: "thread-1",
            turn: .init(id: "turn-1", status: .inProgress)
        ))))
        continuation.yield(transcriptNotification(.itemStarted(.init(
            threadId: "thread-1",
            turnId: "turn-1",
            item: userItem
        ))))
        continuation.finish()

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.transcriptV2.turns.count, 1)
        XCTAssertEqual(session.transcriptV2.turns[0].id, "turn-1")
        XCTAssertEqual(session.transcriptV2.turns[0].userMessage?.id, "server-user-1")
        XCTAssertFalse(session.transcriptV2.turns[0].userMessage?.isOptimistic == true)
    }

    @MainActor
    func testChatStreamSessionCancelsReplacedTurnStreamsWithoutFinishingThem() async {
        let session = CodexChatStreamSession()
        var firstContinuation: AsyncStream<CodexNotification>.Continuation!
        let firstStream = AsyncStream<CodexNotification> { continuation in
            firstContinuation = continuation
        }
        var secondContinuation: AsyncStream<CodexNotification>.Continuation!
        let secondStream = AsyncStream<CodexNotification> { continuation in
            secondContinuation = continuation
        }
        var finishedTurnIDs: [String] = []
        let secondFinished = expectation(description: "second stream finished")

        session.consumeMainTurnStream(
            id: "turn-old",
            notifications: firstStream,
            onNotification: { _ in },
            onFinish: { turnID in
                finishedTurnIDs.append(turnID)
            }
        )
        session.consumeMainTurnStream(
            id: "turn-new",
            notifications: secondStream,
            onNotification: { _ in },
            onFinish: { turnID in
                finishedTurnIDs.append(turnID)
                secondFinished.fulfill()
            }
        )

        firstContinuation.finish()
        secondContinuation.finish()

        await fulfillment(of: [secondFinished], timeout: 1.0)
        XCTAssertEqual(finishedTurnIDs, ["turn-new"])
        session.reset()
    }

    @MainActor
    func testMentionSearchSessionOwnsDebouncedSearchAndClearLifecycle() async {
        let session = CodexMentionSearchSession()
        let result = FuzzyFileSearchResult(
            fileName: "Store.swift",
            matchType: .file,
            path: "Sources/CodexCore/Store/Store.swift",
            root: "/repo",
            score: 0.9
        )
        var receivedQueries: [String] = []
        var receivedResults: [[FuzzyFileSearchResult]] = []
        var clearCount = 0
        let searched = expectation(description: "mention search completed")

        session.updateQuery(
            "Sto",
            debounceNanoseconds: 0,
            search: { query in
                receivedQueries.append(query)
                return [result]
            },
            onResults: { files in
                receivedResults.append(files)
                searched.fulfill()
            },
            onClear: {
                clearCount += 1
            }
        )

        await fulfillment(of: [searched], timeout: 1.0)
        XCTAssertEqual(receivedQueries, ["Sto"])
        XCTAssertEqual(receivedResults, [[result]])

        session.updateQuery(
            nil,
            debounceNanoseconds: 0,
            search: { _ in [] },
            onResults: { _ in },
            onClear: {
                clearCount += 1
            }
        )
        XCTAssertEqual(clearCount, 1)
        session.reset()
    }

    func testFileChangeParsesPatchUpdatedNotificationShape() throws {
        let change = try XCTUnwrap(CodexChatMessage.fileChange(itemID: "patch-1", raw: [
            "changes": .array([
                .dictionary([
                    "path": .string("Sources/App.swift"),
                    "kind": .dictionary(["type": .string("update")]),
                    "diff": .string("""
                    --- a/Sources/App.swift
                    +++ b/Sources/App.swift
                    @@ -1 +1 @@
                    -old
                    +new
                    """)
                ])
            ]),
            "status": .string("running")
        ]))

        XCTAssertEqual(change.itemID, "patch-1")
        XCTAssertEqual(change.path, "Sources/App.swift")
        XCTAssertEqual(change.kind, "update")
        XCTAssertEqual(change.addedLineCount, 1)
        XCTAssertEqual(change.removedLineCount, 1)
        XCTAssertTrue(change.isStreaming)
    }

    func testFileChangeCountsChangedFilesInMultiFileDiff() throws {
        let change = CodexChatMessage.fileChange(
            itemID: "patch-2",
            path: nil,
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            diff --git a/Tests/AppTests.swift b/Tests/AppTests.swift
            --- a/Tests/AppTests.swift
            +++ b/Tests/AppTests.swift
            @@ -2 +2 @@
            -before
            +after
            """,
            status: "completed",
            isStreaming: false
        )

        XCTAssertEqual(change.changedFileCount, 2)
        XCTAssertEqual(change.addedLineCount, 2)
        XCTAssertEqual(change.removedLineCount, 2)
    }

    func testFileChangeUndoSessionOwnsGitCommandPolicy() throws {
        let modified = CodexChatMessage.fileChange(
            itemID: "patch-1",
            path: "/repo/Sources/App.swift",
            diff: "+new",
            kind: "update",
            status: "completed"
        )
        let added = CodexChatMessage.fileChange(
            itemID: "patch-2",
            path: "/repo/Sources/New.swift",
            diff: "+new",
            kind: "add",
            status: "completed"
        )

        let modifiedPlan = try XCTUnwrap(CodexFileChangeUndoSession.plan(for: modified, workspacePath: "/repo"))
        XCTAssertEqual(modifiedPlan.command, ["git", "checkout", "--", "Sources/App.swift"])
        XCTAssertEqual(modifiedPlan.cwd, "/repo")
        XCTAssertEqual(modifiedPlan.relativePath, "Sources/App.swift")

        let addedPlan = try XCTUnwrap(CodexFileChangeUndoSession.plan(for: added, workspacePath: "/repo/"))
        XCTAssertEqual(addedPlan.command, ["git", "clean", "-f", "--", "Sources/New.swift"])

        let unavailable = CodexChatMessage.fileChange(itemID: "patch-3", path: nil, diff: "+new", status: "completed")
        XCTAssertNil(CodexFileChangeUndoSession.plan(for: unavailable, workspacePath: "/repo"))
        XCTAssertEqual(CodexFileChangeUndoSession.unavailableActivity.title, "Undo unavailable")
        XCTAssertEqual(CodexFileChangeUndoSession.successActivity(relativePath: "Sources/App.swift").detail, "Sources/App.swift")
        XCTAssertEqual(CodexFileChangeUndoSession.failureActivity(message: "nope").detail, "nope")
    }

    func testPlanUpdateParsesTurnPlanUpdatedNotificationShape() throws {
        let plan = try XCTUnwrap(CodexChatMessage.planUpdate(itemID: "turn-plan-1", raw: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "explanation": .string("I will inspect, edit, and verify."),
            "plan": .array([
                .dictionary([
                    "step": .string("Inspect current transcript mapping"),
                    "status": .string("completed")
                ]),
                .dictionary([
                    "step": .string("Wire plan updates into the UI"),
                    "status": .string("inProgress")
                ]),
                .dictionary([
                    "step": .string("Run tests"),
                    "status": .string("pending")
                ])
            ])
        ]))

        XCTAssertEqual(plan.itemID, "turn-plan-1")
        XCTAssertEqual(plan.explanation, "I will inspect, edit, and verify.")
        XCTAssertEqual(plan.steps.map(\.step), [
            "Inspect current transcript mapping",
            "Wire plan updates into the UI",
            "Run tests"
        ])
        XCTAssertEqual(plan.completedStepCount, 1)
        XCTAssertEqual(plan.activeStepCount, 1)
        XCTAssertEqual(plan.summary, "1/3 complete")
        XCTAssertTrue(plan.copyText.contains("[inProgress] Wire plan updates into the UI"))
    }

    func testToolCallParsesMCPThreadItemShape() throws {
        let toolCall = try XCTUnwrap(CodexChatMessage.toolCall(itemID: "mcp-1", raw: [
            "type": .string("mcpToolCall"),
            "server": .string("filesystem"),
            "tool": .string("read_file"),
            "arguments": .dictionary(["path": .string("Package.swift")]),
            "status": .string("completed"),
            "durationMs": .int(42),
            "result": .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string("package contents")
                    ])
                ])
            ])
        ]))

        XCTAssertEqual(toolCall.displayName, "filesystem.read_file")
        XCTAssertEqual(toolCall.arguments, #"{"path":"Package.swift"}"#)
        XCTAssertEqual(toolCall.result, "package contents")
        XCTAssertEqual(toolCall.durationMilliseconds, 42)
        XCTAssertFalse(toolCall.isStreaming)
        XCTAssertTrue(toolCall.copyText.contains("Arguments:"))
    }

    func testNoticeParsesModelWarningAndAutoReviewNotificationShapes() throws {
        let reroute = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "reroute-1",
            method: .modelRerouted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "fromModel": .string("gpt-5.1-codex-max"),
                "toModel": .string("gpt-5.1-codex"),
                "reason": .string("highRiskCyberActivity")
            ]
        ))
        XCTAssertEqual(reroute.title, "Model rerouted")
        XCTAssertEqual(reroute.detail, "gpt-5.1-codex-max -> gpt-5.1-codex")
        XCTAssertEqual(reroute.metadata, ["Reason: high risk cyber activity"])
        XCTAssertEqual(reroute.severity, .warning)

        let configWarning = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "config-1",
            method: .configWarning,
            raw: [
                "summary": .string("Invalid sandbox value"),
                "details": .string("Use workspace-write or read-only."),
                "path": .string("/tmp/config.toml"),
                "range": .dictionary([
                    "start": .dictionary(["line": .int(7), "column": .int(4)]),
                    "end": .dictionary(["line": .int(7), "column": .int(18)])
                ])
            ]
        ))
        XCTAssertEqual(configWarning.title, "Config warning")
        XCTAssertEqual(configWarning.detail, "Invalid sandbox value")
        XCTAssertTrue(configWarning.metadata.contains("Location: 7:4"))

        let reviewStarted = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "review-auto-1",
            method: .itemAutoApprovalReviewStarted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "reviewId": .string("auto-1"),
                "startedAtMs": .int(1_000),
                "targetItemId": .string("cmd-1"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("swift test"),
                    "cwd": .string("/tmp/CodexCore"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("inProgress"),
                    "riskLevel": .string("low"),
                    "rationale": .string("Tests are safe to run.")
                ])
            ],
            isStreaming: true
        ))
        XCTAssertEqual(reviewStarted.title, "Auto review")
        XCTAssertEqual(reviewStarted.detail, "swift test")
        XCTAssertEqual(reviewStarted.status, "inProgress")
        XCTAssertTrue(reviewStarted.isStreaming)
        XCTAssertEqual(reviewStarted.severity, .info)

        let reviewCompleted = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "review-auto-1",
            method: .itemAutoApprovalReviewCompleted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "reviewId": .string("auto-1"),
                "startedAtMs": .int(1_000),
                "completedAtMs": .int(2_250),
                "decisionSource": .string("agent"),
                "targetItemId": .string("cmd-1"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("swift test"),
                    "cwd": .string("/tmp/CodexCore"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("approved"),
                    "riskLevel": .string("low"),
                    "rationale": .string("No risky behavior found.")
                ])
            ]
        ))
        XCTAssertEqual(reviewCompleted.title, "Auto review approved")
        XCTAssertEqual(reviewCompleted.severity, .success)
        XCTAssertFalse(reviewCompleted.isStreaming)
        XCTAssertTrue(reviewCompleted.metadata.contains("Duration: 1.2s"))
    }

    func testChatActionHandlersExposeHostWiredActions() {
        var didPinChat = false
        var didOpenSideChat = false
        var didCopyChat = false
        var didAddAutomation = false
        let actions = CodexChatActionHandlers(
            pinChat: { didPinChat = true },
            openSideChat: { didOpenSideChat = true },
            copyChat: { didCopyChat = true },
            addAutomation: { didAddAutomation = true }
        )

        XCTAssertNil(CodexChatActionHandlers().pinChat)
        XCTAssertNil(CodexChatActionHandlers().openSideChat)
        XCTAssertNil(CodexChatActionHandlers().copyChat)
        XCTAssertNil(CodexChatActionHandlers().addAutomation)
        XCTAssertTrue(CodexChatActionHandlers().menuItems.allSatisfy { !$0.isEnabled })

        XCTAssertEqual(actions.menuItems.map(\.id), [
            .pinChat,
            .renameChat,
            .archiveChat,
            .openSideChat,
            .copy,
            .fork,
            .addAutomation
        ])
        XCTAssertEqual(actions.menuItems.map(\.displayTitle), [
            "Pin chat ⌥⌘P",
            "Rename chat ⌥⌘R",
            "Archive chat ⇧⌘A",
            "Open side chat ⌥⌘S",
            "Copy",
            "Fork",
            "Add automation…"
        ])
        XCTAssertEqual(actions.menuItems.map(\.isEnabled), [
            true,
            false,
            false,
            true,
            true,
            false,
            true
        ])

        actions.perform(.pinChat)
        actions.perform(.openSideChat)
        actions.perform(.copy)
        actions.perform(.addAutomation)

        XCTAssertTrue(didPinChat)
        XCTAssertTrue(didOpenSideChat)
        XCTAssertTrue(didCopyChat)
        XCTAssertTrue(didAddAutomation)
        XCTAssertEqual(CodexSideChatState.defaultID, "side-chat")
        XCTAssertEqual(CodexSideChatState().id, CodexSideChatState.defaultID)
    }

    @MainActor
    func testEmptyTranscriptDefaultPromptsMatchObservedCodexBlankState() {
        XCTAssertEqual(CodexEmptyTranscriptView.defaultPrompts.map(\.prompt), [
            "Debug an issue",
            "Plan implementation",
            "Review a PR",
            "Connect your favorite apps to Codex"
        ])
        XCTAssertEqual(CodexEmptyTranscriptView.defaultPrompts.map(\.detail), [nil, nil, nil, nil])
    }

    func testSubagentRunSummaryCompletionWinsOverHistoricalRunningEvents() {
        let now = Date(timeIntervalSince1970: 2_000)
        let events = [
            CodexAgentLifecycleEvent(status: .spawning, title: "Spawning agent", createdAt: now),
            CodexAgentLifecycleEvent(status: .running, title: "Spawned Agent 1", agentNames: ["Agent 1"], createdAt: now.addingTimeInterval(1)),
            CodexAgentLifecycleEvent(status: .spawning, title: "Spawning agent", createdAt: now.addingTimeInterval(2)),
            CodexAgentLifecycleEvent(status: .running, title: "Spawned Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(3)),
            CodexAgentLifecycleEvent(status: .running, title: "Waiting for Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(4)),
            CodexAgentLifecycleEvent(status: .completed, title: "Finished waiting", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(5)),
            CodexAgentLifecycleEvent(status: .closed, title: "Closed Agent 1", agentNames: ["Agent 1"], createdAt: now.addingTimeInterval(6)),
            CodexAgentLifecycleEvent(status: .closed, title: "Closed Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(7))
        ]

        let summary = CodexSubagentRunSummary(events: events)

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.title, "Subagent run complete")
        XCTAssertEqual(summary.agentCountLabel, "2 agents")
        XCTAssertTrue(summary.detail.contains("finished"))
        XCTAssertFalse(summary.detail.contains("active"))
        XCTAssertEqual(summary.milestones.map(\.title), ["Spawned 2 agents", "Received agent output"])
    }

    func testSubagentRunSummaryInfersAgentCountFromWaitingTitle() {
        let summary = CodexSubagentRunSummary(events: [
            CodexAgentLifecycleEvent(status: .running, title: "Waiting for 2 agents")
        ])

        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.title, "Subagents running")
        XCTAssertEqual(summary.agentCountLabel, "2 agents")
        XCTAssertEqual(summary.milestones.map(\.title), ["Waiting for 2 agents"])
    }

    func testFloatingSummarySubagentRowsMatchObservedCodexLifecycle() {
        let running = CodexSubagentState(
            name: "Halley",
            title: "Slow repo cartographer",
            prompt: "Run read-only tools",
            status: .running
        )
        let completed = CodexSubagentState(
            name: "Newton",
            title: "Slow renderer",
            prompt: "Inspect UI",
            status: .completed
        )
        let closed = CodexSubagentState(
            name: "Parfit",
            title: "Slow runtime observer",
            prompt: "Check runtimes",
            status: .closed
        )

        XCTAssertTrue(running.isVisibleInFloatingSummary)
        XCTAssertEqual(running.floatingSummaryTitle, "Halley is working")
        XCTAssertTrue(completed.isVisibleInFloatingSummary)
        XCTAssertEqual(completed.floatingSummaryTitle, "Newton")
        XCTAssertFalse(closed.isVisibleInFloatingSummary)
    }
}

@discardableResult
func routeTranscriptNotification(
    _ payload: CodexNotificationPayload,
    to transcript: inout CodexChatTranscriptState,
    context: CodexChatTranscriptRouteContext = CodexChatTranscriptRouteContext()
) -> CodexChatTranscriptRouteResult? {
    CodexChatTranscriptNotificationRouter.apply(
        transcriptNotification(payload),
        to: &transcript,
        context: context
    )
}

func transcriptNotification(_ payload: CodexNotificationPayload) -> CodexNotification {
    CodexNotification(
        method: payload.knownMethod?.rawValue ?? "unknown",
        payload: payload,
        rawParams: payload.rawParams
    )
}

func transcriptThreadItem(_ raw: [String: CodexJSONValue]) throws -> ThreadItem {
    try CodexJSONValue.dictionary(raw).decode(ThreadItem.self)
}

private extension CodexNotificationPayload {
    var rawParams: [String: CodexJSONValue] {
        switch self {
        case .itemStarted(let payload), .itemCompleted(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "item": .dictionary(payload.item.raw)
            ]
        case .agentMessageDelta(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "itemId": .string(payload.itemId),
                "delta": .string(payload.delta)
            ]
        case .turnPlanUpdated(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "explanation": payload.explanation.map(CodexJSONValue.string) ?? .null,
                "plan": .array(payload.plan.map { step in
                    .dictionary([
                        "step": .string(step.step),
                        "status": .string(step.status.rawValue)
                    ])
                })
            ]
        case .turnDiffUpdated(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "diff": .string(payload.diff)
            ]
        case .known(_, let params), .unknown(_, let params):
            return params
        case .threadTokenUsageUpdated(let payload):
            var raw: [String: CodexJSONValue] = [
                "threadId": .string(payload.threadId),
                "tokenUsage": .dictionary(payload.tokenUsage.raw)
            ]
            if let turnId = payload.turnId { raw["turnId"] = .string(turnId) }
            return raw
        case .threadGoalUpdated(let payload):
            var raw: [String: CodexJSONValue] = [
                "threadId": .string(payload.threadId)
            ]
            if let turnId = payload.turnId { raw["turnId"] = .string(turnId) }
            return raw
        case .threadGoalCleared(let payload):
            return ["threadId": .string(payload.threadId)]
        case .turnStarted, .turnCompleted, .accountLoginCompleted:
            return [:]
        }
    }
}
