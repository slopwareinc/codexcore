import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexSubagentCanonicalPresentationTests {
    @Test func parentDiscoveryIsAStableReplacementSet() throws {
        let snapshot = parentSnapshot()
        var store = CodexSubagentStoreV2()

        let first = store.applyParentSnapshot(snapshot, parentThreadID: "parent")
        let second = store.applyParentSnapshot(snapshot, parentThreadID: "parent")

        #expect(first.map(\.threadID) == ["child"])
        #expect(second == first)
        let child = try #require(store.agent(threadID: "child"))
        #expect(child.parentThreadID == "parent")
        #expect(child.prompt == "Inspect the repository")
    }

    @Test func lightweightIndexAddsIdentityWithoutCopyingTranscript() throws {
        var store = CodexSubagentStoreV2()
        let populated = CanonicalThreadIndexSnapshot(
            revision: StateRevision(2),
            threads: [indexChild()]
        )

        let first = store.applyThreadIndex(populated, parentThreadID: "parent")
        let second = store.applyThreadIndex(populated, parentThreadID: "parent")
        let removed = store.applyThreadIndex(
            .init(revision: StateRevision(3), threads: []),
            parentThreadID: "parent"
        )

        #expect(first.map(\.threadID) == ["child"])
        #expect(second == first)
        #expect(removed.isEmpty)
        let child = try #require(store.agent(threadID: "child"))
        #expect(child.nickname == "Scout")
        #expect(child.role == "explorer")
        #expect(child.agentPath == "/root/scout")
        #expect(child.transcript.turns.isEmpty)
    }

    @Test func childSnapshotProjectsNonEmptyTranscriptAndExactStatus() throws {
        var store = CodexSubagentStoreV2()
        _ = store.applyParentSnapshot(parentSnapshot(), parentThreadID: "parent")

        let didChange = store.applyChildSnapshot(childSnapshot(), threadID: "child")
        #expect(didChange)
        let child = try #require(store.agent(threadID: "child"))
        #expect(child.transcript.turns.count == 1)
        #expect(child.transcript.turns.first?.finalAnswer?.text == "Found it")
        guard case .completed(let duration) = child.status else {
            Issue.record("Expected canonical terminal status")
            return
        }
        #expect(duration == 2_000)
    }

    @Test func childProjectionRetainsPreviousPresentationUntilTranscriptEviction() throws {
        var store = CodexSubagentStoreV2()
        let snapshot = childFileChangeSnapshot()

        let applied = store.applyChildSnapshot(snapshot, threadID: "child")
        #expect(applied)
        let retainedBytes = store.retainedPreparedUTF8ByteCount(threadID: "child")
        #expect(retainedBytes > 0)
        #expect(store.retainedPreparedUTF8ByteCount == retainedBytes)

        // The same canonical revision is accepted through the incremental
        // projection seam and leaves one retained preparation, not another copy.
        let reapplied = store.applyChildSnapshot(snapshot, threadID: "child")
        #expect(reapplied)
        #expect(store.retainedPreparedUTF8ByteCount == retainedBytes)

        store.evictTranscript(threadID: "child")
        #expect(store.agent(threadID: "child")?.transcript.turns.isEmpty == true)
        #expect(store.retainedPreparedUTF8ByteCount == 0)
    }

    @Test func childProjectionCommitRejectsStaleOrMismatchedResults() throws {
        var store = CodexSubagentStoreV2()
        let current = childFileChangeSnapshot(revision: 4)
        #expect(store.applyChildSnapshot(current, threadID: "child"))
        let expectedTranscript = try #require(store.agent(threadID: "child")?.transcript)
        let expectedBytes = store.retainedPreparedUTF8ByteCount

        let stale = childFileChangeSnapshot(revision: 3)
        let staleResult = CodexSubagentStoreV2.projectChildSnapshot(
            stale,
            threadID: "child",
            previous: nil
        )
        #expect(!store.applyChildProjection(
            staleResult,
            threadID: "child",
            expectedRevision: StateRevision(3)
        ))

        let wrongThread = childFileChangeSnapshot(
            threadID: "other",
            revision: 5
        )
        let wrongThreadResult = CodexSubagentStoreV2.projectChildSnapshot(
            wrongThread,
            threadID: "other",
            previous: nil
        )
        #expect(!store.applyChildProjection(
            wrongThreadResult,
            threadID: "child",
            expectedRevision: StateRevision(5)
        ))
        #expect(!store.applyChildProjection(
            staleResult,
            threadID: "child",
            expectedRevision: StateRevision(4)
        ))

        #expect(store.agent(threadID: "child")?.transcript == expectedTranscript)
        #expect(store.retainedPreparedUTF8ByteCount == expectedBytes)
    }

    @Test func mapperUsesCanonicalCompositeIdentityAcrossRefreshes() throws {
        let parent = parentSnapshot()
        var store = CodexSubagentStoreV2()
        _ = store.applyParentSnapshot(parent, parentThreadID: "parent")
        _ = store.applyChildSnapshot(childSnapshot(), threadID: "child")
        var mapper = CodexAgentStateMapper()

        let firstRefreshChanged = mapper.applyCanonicalSnapshot(
            parent,
            parentThreadID: "parent",
            projectedChildren: store.agents
        )
        #expect(firstRefreshChanged)
        let firstID = try #require(mapper.lifecycleEvents.first?.id)
        #expect(mapper.subagents.first?.id == "child")
        #expect(mapper.subagents.first?.transcript.turns.first?.finalAnswer?.text == "Found it")

        let secondRefreshChanged = mapper.applyCanonicalSnapshot(
            parent,
            parentThreadID: "parent",
            projectedChildren: store.agents
        )
        #expect(!secondRefreshChanged)
        #expect(mapper.lifecycleEvents.first?.id == firstID)
    }

    @Test func closeAgentRemainsClosedAfterChildRefresh() throws {
        var store = CodexSubagentStoreV2()
        _ = store.applyParentSnapshot(closedParentSnapshot(), parentThreadID: "parent")
        _ = store.applyChildSnapshot(childSnapshot(), threadID: "child")

        let child = try #require(store.agent(threadID: "child"))
        guard case .closed = child.status else {
            Issue.record("A canonical closeAgent completion must dominate later child snapshots")
            return
        }
    }

    @Test func sideChatCompletesOnlyItsExactCanonicalTurn() {
        var sideChat = CodexSideChatSession()
        _ = sideChat.open(createdAt: Date(timeIntervalSince1970: 1))
        sideChat.start(turnID: "side-turn", threadID: "side")

        #expect(sideChat.applyCanonicalSnapshot(
            childSnapshot(threadID: "other", turnID: "side-turn"),
            threadID: "side"
        ) == nil)
        #expect(sideChat.isSending)
        #expect(sideChat.applyCanonicalSnapshot(
            childSnapshot(threadID: "side", turnID: "side-turn")
        )?.activity?.title == "Side chat complete")
        #expect(!sideChat.isSending)
    }
}

private extension CodexSubagentCanonicalPresentationTests {
    func parentSnapshot(close: Bool = false) -> CanonicalStateSnapshot {
        let threadID: ThreadID = "parent"
        let turnID: TurnID = "parent-turn"
        let itemID: ItemID = close ? "close" : "spawn"
        let item = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: .collabAgentToolCall,
            payload: [
                "type": .string("collabAgentToolCall"),
                "id": .string(itemID.rawValue),
                "tool": .string(close ? "closeAgent" : "spawnAgent"),
                "status": .string("completed"),
                "receiverThreadIds": .array([.string("child")]),
                "prompt": close ? .null : .string("Inspect the repository"),
                "agentsStates": .dictionary([:]),
            ],
            authority: .completed,
            completedAt: ProtocolMilliseconds(1_700_000_000_000),
            consistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            itemOrder: [itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        return CanonicalStateSnapshot(
            revision: StateRevision(1),
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [turnID],
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: StateRevision(1)
            )],
            turns: [turn.key: turn],
            items: [item.key: item]
        )
    }

    func closedParentSnapshot() -> CanonicalStateSnapshot { parentSnapshot(close: true) }

    func childFileChangeSnapshot(
        threadID: ThreadID = "child",
        revision rawRevision: UInt64 = 4
    ) -> CanonicalStateSnapshot {
        let turnID: TurnID = "child-turn"
        let itemID: ItemID = "patch"
        let revision = StateRevision(rawRevision)
        let item = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: .fileChange,
            payload: [
                "status": .string("completed"),
                "changes": .array([.dictionary([
                    "path": .string("Sources/Child.swift"),
                    "kind": .dictionary(["type": .string("update")]),
                    "diff": .string("@@ -1 +1 @@\n-let child = false\n+let child = true"),
                ])]),
            ],
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: revision
        )
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            itemOrder: [itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: revision
        )
        return CanonicalStateSnapshot(
            revision: revision,
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [turnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: revision
            )],
            turns: [turn.key: turn],
            items: [item.key: item]
        )
    }

    func childSnapshot(
        threadID: ThreadID = "child",
        turnID: TurnID = "child-turn"
    ) -> CanonicalStateSnapshot {
        let itemID: ItemID = "answer"
        let item = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: .agentMessage,
            payload: [
                "type": .string("agentMessage"),
                "id": .string(itemID.rawValue),
                "phase": .string("final_answer"),
                "text": .string("Found it"),
            ],
            authority: .completed,
            completedAt: ProtocolMilliseconds(1_700_000_002_000),
            consistency: .authoritative,
            lastChangedRevision: StateRevision(4)
        )
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            startedAt: ProtocolSeconds(1_700_000_000),
            completedAt: ProtocolSeconds(1_700_000_002),
            duration: DurationMilliseconds(2_000),
            itemOrder: [itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(4)
        )
        let metadata = CanonicalThreadMetadata(
            agentNickname: "Scout",
            agentRole: "explorer",
            createdAt: ProtocolSeconds(1_700_000_000),
            parentThreadID: "parent",
            path: "/root/scout",
            updatedAt: ProtocolSeconds(1_700_000_002)
        )
        return CanonicalStateSnapshot(
            revision: StateRevision(4),
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                metadata: metadata,
                status: .idle,
                turnOrder: [turnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: StateRevision(4)
            )],
            turns: [turn.key: turn],
            items: [item.key: item]
        )
    }

    func indexChild() -> CanonicalThreadIndexSummary {
        CanonicalThreadIndexSummary(
            id: "child",
            order: 1,
            status: .active(flags: []),
            latestTurnID: "child-turn",
            latestTurnStatus: .inProgress,
            isArchived: false,
            isLoaded: true,
            name: nil,
            preview: nil,
            cwd: nil,
            parentThreadID: "parent",
            agentNickname: "Scout",
            agentRole: "explorer",
            path: "/root/scout",
            updatedAt: ProtocolSeconds(1_700_000_000),
            lastChangedRevision: StateRevision(2),
            attentionRevision: StateRevision(2),
            hasPendingServerRequest: false
        )
    }
}
