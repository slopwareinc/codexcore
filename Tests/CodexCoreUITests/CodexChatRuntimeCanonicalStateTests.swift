@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexChatRuntimeCanonicalStateTests {
    @Test func mainAndSideChatUseIndependentCanonicalPresentationStores() {
        let runtime = CodexChatRuntimeSession()

        runtime.selectThread("main")
        runtime.startSideChat(id: "side-turn", threadID: "side")

        #expect(runtime.presentationStore.selectedThreadID == "main")
        #expect(runtime.sideChatPresentationStore.selectedThreadID == "side")
        #expect(runtime.activeSideChatTurnID == "side-turn")

        runtime.presentationStore.updateScrollState(
            threadID: "main",
            rawOffset: 120,
            isPinnedToBottom: false
        )
        runtime.sideChatPresentationStore.updateScrollState(
            threadID: "side",
            rawOffset: 45,
            isPinnedToBottom: true
        )

        #expect(runtime.presentationStore.localState(for: "main")?.rawScrollOffset == 120)
        #expect(runtime.sideChatPresentationStore.localState(for: "side")?.rawScrollOffset == 45)
    }

    @Test func canonicalSnapshotProjectsTurnChromeWithoutNotificationRouting() {
        let runtime = CodexChatRuntimeSession()
        runtime.selectThread("thread")

        runtime.applyCanonicalSnapshot(snapshot(status: .inProgress, threadStatus: .active(flags: [])))

        #expect(runtime.isSending)
        #expect(runtime.currentPlan == [TurnPlanStep(step: "Inspect", status: .inProgress)])
        #expect(runtime.currentPlanExplanation == "Reading canonical state")
        #expect(runtime.currentDiff == "diff --git a/a b/a")
        #expect(runtime.activeGoal?.objective == "Finish migration")
        #expect(runtime.activeGoal?.status == .active)

        runtime.applyCanonicalSnapshot(snapshot(status: .completed, threadStatus: .idle))
        #expect(!runtime.isSending)
    }

    @Test func canonicalSnapshotSkipsMissingTrailingTurnReferences() {
        let runtime = CodexChatRuntimeSession()
        runtime.selectThread("thread")

        runtime.applyCanonicalSnapshot(snapshot(
            status: .inProgress,
            threadStatus: .active(flags: []),
            turnOrder: ["turn", "missing"]
        ))

        #expect(runtime.currentPlan == [TurnPlanStep(step: "Inspect", status: .inProgress)])
        #expect(runtime.currentPlanExplanation == "Reading canonical state")
    }

    @Test func optimisticLifecycleFinishesOnlyTheMatchingTurnAndFlushesQueue() throws {
        let runtime = CodexChatRuntimeSession()
        _ = runtime.beginMainTurnSubmission(.init(prompt: "Hello"))
        runtime.startMainTurn(id: "turn")

        #expect(runtime.activeTurnID == "turn")
        #expect(runtime.canSendFollowUp(canSteer: true))
        #expect(runtime.finishMainTurn(id: "other") == nil)

        let update = try #require(runtime.finishMainTurn(id: "turn"))
        #expect(update.actions.contains(.flushQueuedFollowUps))
        #expect(runtime.activeTurnID == nil)
    }

    @Test func queuedFollowUpsDrainOneAtATimeInFIFOOrderDespiteStaleCanonicalState() throws {
        let runtime = CodexChatRuntimeSession()
        runtime.selectThread("thread")
        runtime.applyCanonicalSnapshot(snapshot(status: .inProgress, threadStatus: .active(flags: [])))

        var composer = CodexComposerStateSession(activeThreadID: "thread")
        let first = CodexComposerSubmission(prompt: "first", clientID: "first", threadID: "thread")
        let second = CodexComposerSubmission(prompt: "second", clientID: "second", threadID: "thread")
        composer.enqueueFollowUp(first)
        composer.enqueueFollowUp(second)

        _ = runtime.beginMainTurnSubmission(.init(prompt: "running"))
        runtime.startMainTurn(id: "turn-1")
        _ = try #require(runtime.finishMainTurn(id: "turn-1"))

        // The canonical projection intentionally still says the completed turn
        // is active. Queue serialization follows the matching local lifecycle.
        #expect(runtime.isSending)
        #expect(!runtime.isMainTurnPendingOrRunning)

        let firstQueued = try #require(runtime.dequeueQueuedFollowUp(
            composerSession: &composer,
            isSending: runtime.isMainTurnPendingOrRunning
        ))
        #expect(firstQueued.submission.clientID == first.clientID)
        #expect(runtime.isMainTurnPendingOrRunning)
        #expect(composer.queuedFollowUpSubmissions(for: "thread").map(\.clientID) == [second.clientID])

        // A second drain attempt cannot start a concurrent turn.
        #expect(runtime.dequeueQueuedFollowUp(
            composerSession: &composer,
            isSending: runtime.isMainTurnPendingOrRunning
        ) == nil)

        runtime.startMainTurn(id: "turn-2")
        _ = try #require(runtime.finishMainTurn(id: "turn-2"))
        let secondQueued = try #require(runtime.dequeueQueuedFollowUp(
            composerSession: &composer,
            isSending: runtime.isMainTurnPendingOrRunning
        ))
        #expect(secondQueued.submission.clientID == second.clientID)
        #expect(composer.queuedFollowUpSubmissions(for: "thread").isEmpty)
    }

    private func snapshot(
        status: CanonicalTurnStatus,
        threadStatus: CanonicalThreadStatus,
        turnOrder: [TurnID] = ["turn"]
    ) -> CodexSessionStateSnapshot {
        let revision = StateRevision(1)
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let goal = CanonicalThreadGoal(
            threadID: threadID,
            objective: "Finish migration",
            status: .active,
            tokenBudget: 1_000,
            tokensUsed: 50,
            timeUsedSeconds: 10,
            createdAt: .init(rawValue: 1),
            updatedAt: .init(rawValue: 2)
        )
        let thread = CanonicalThread(
            id: threadID,
            status: threadStatus,
            turnOrder: turnOrder,
            goal: goal,
            consistency: .authoritative,
            lastChangedRevision: revision
        )
        let turn = CanonicalTurn(
            key: turnKey,
            status: status,
            plan: [.init(step: "Inspect", status: .inProgress)],
            planExplanation: "Reading canonical state",
            diff: "diff --git a/a b/a",
            lastChangedRevision: revision
        )
        let canonical = CanonicalStateSnapshot(
            revision: revision,
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: [turnKey: turn]
        )
        return CodexSessionStateSnapshot(
            stateRevision: revision,
            canonical: canonical,
            serverRequests: .init(revision: revision, requests: []),
            lifecycle: .ready(connectionEpoch: 1)
        )
    }
}
