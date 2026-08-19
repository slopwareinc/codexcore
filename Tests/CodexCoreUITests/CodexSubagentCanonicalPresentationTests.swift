import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexSubagentCanonicalPresentationTests {
    @Test func logicalAgentPathPrecedesGeneratedNicknameForDisplay() {
        let agent = CodexSubagentV2(
            threadID: "child",
            agentPath: "/root/extra_subagent_4",
            nickname: "Cicero"
        )
        #expect(agent.displayName == "Extra Subagent 4")

        let nicknameOnly = CodexSubagentV2(
            threadID: "child",
            nickname: "Cicero"
        )
        #expect(nicknameOnly.displayName == "Cicero")

        let rollout = CodexSubagentV2(
            threadID: "child",
            agentPath: "/Users/test/.codex/sessions/rollout-2026-08-19.jsonl",
            nickname: "Cicero"
        )
        #expect(rollout.displayName == "Cicero")
    }

    @Test func graphProjectionRegistersRecursiveDescendantsWithExactLifecycle() throws {
        let root = CodexThreadGraphKey(hostID: "host-a", threadID: "root")
        let child = CodexThreadGraphKey(hostID: "host-a", threadID: "child")
        let grandchild = CodexThreadGraphKey(hostID: "host-a", threadID: "grandchild")
        let graph = CodexThreadGraphSnapshot(
            revision: StateRevision(4),
            nodes: [
                root: .init(key: root, children: [child], depth: 0),
                child: .init(
                    key: child,
                    parent: root,
                    children: [grandchild],
                    depth: 1,
                    lifecycle: .running,
                    agentNickname: "Scout"
                ),
                grandchild: .init(
                    key: grandchild,
                    parent: child,
                    depth: 2,
                    lifecycle: .notFound,
                    errorMessage: "agent vanished"
                ),
            ],
            edges: [],
            actions: [],
            roots: [root]
        )
        var store = CodexSubagentStoreV2()

        let discoveries = store.applyGraphSnapshot(graph, root: root)

        #expect(discoveries.map(\.threadID) == ["child", "grandchild"])
        let projectedChild = try #require(store.agent(threadID: "child"))
        #expect(projectedChild.nickname == "Scout")
        #expect(projectedChild.collaborationLifecycle == .running)
        let projectedGrandchild = try #require(store.agent(threadID: "grandchild"))
        #expect(projectedGrandchild.parentThreadID == "child")
        #expect(projectedGrandchild.depth == 2)
        #expect(projectedGrandchild.collaborationLifecycle == .notFound)
        #expect(projectedGrandchild.statusMessage == "agent vanished")
        guard case .failed(let message) = projectedGrandchild.status else {
            Issue.record("Expected notFound to remain exact and present as failed")
            return
        }
        #expect(message == "agent vanished")
    }

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
        #expect(child.agentPath == nil)
        #expect(child.displayName == "Scout")
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

    @Test func staleIndexCannotRegressAnAuthoritativeCompletedChild() throws {
        var store = CodexSubagentStoreV2()
        _ = store.applyParentSnapshot(parentSnapshot(), parentThreadID: "parent")
        _ = store.applyChildSnapshot(childSnapshot(), threadID: "child")

        let root = CodexThreadGraphKey(hostID: "local", threadID: "parent")
        let child = CodexThreadGraphKey(hostID: "local", threadID: "child")
        _ = store.applyGraphSnapshot(
            .init(
                revision: StateRevision(5),
                nodes: [
                    root: .init(key: root, children: [child]),
                    child: .init(key: child, parent: root, lifecycle: .running),
                ],
                edges: [],
                actions: [],
                roots: [root]
            ),
            root: root
        )
        guard case .completed = store.agent(threadID: "child")?.status else {
            Issue.record("A graph refresh without newer lifecycle evidence must not regress completion")
            return
        }

        _ = store.applyThreadIndex(
            .init(
                revision: StateRevision(2),
                threads: [indexChild(revision: StateRevision(2))]
            ),
            parentThreadID: "parent"
        )
        guard case .completed = store.agent(threadID: "child")?.status else {
            Issue.record("A stale active index must not regress an authoritative completion")
            return
        }

        _ = store.applyThreadIndex(
            .init(
                revision: StateRevision(4),
                threads: [indexChild(revision: StateRevision(4))]
            ),
            parentThreadID: "parent"
        )
        guard case .completed = store.agent(threadID: "child")?.status else {
            Issue.record("An equal-revision index must not outrank the exact child snapshot")
            return
        }

        _ = store.applyThreadIndex(
            .init(
                revision: StateRevision(5),
                threads: [indexChild(
                    revision: StateRevision(5),
                    latestTurnStatus: .completed
                )]
            ),
            parentThreadID: "parent"
        )
        guard case .completed = store.agent(threadID: "child")?.status else {
            Issue.record("An active thread must not override its terminal latest turn")
            return
        }

        _ = store.applyThreadIndex(
            .init(
                revision: StateRevision(6),
                threads: [indexChild(
                    revision: StateRevision(6),
                    latestTurnID: "new-turn"
                )]
            ),
            parentThreadID: "parent"
        )
        guard case .working = store.agent(threadID: "child")?.status else {
            Issue.record("A newer in-progress turn must reactivate the child")
            return
        }
    }

    @Test func childMetadataSummaryUsesExactOrderedLatestTurn() throws {
        let threadID: ThreadID = "child"
        let olderTurnID: TurnID = "older"
        let missingLatestTurnID: TurnID = "latest"
        let olderTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: olderTurnID),
            status: .completed,
            completedAt: ProtocolSeconds(123),
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(2),
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .active(flags: []),
                turnOrder: [olderTurnID, missingLatestTurnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: StateRevision(2)
            )],
            turns: [olderTurn.key: olderTurn]
        )

        let summary = try #require(CodexSubagentChildSnapshotSummary(
            snapshot: snapshot,
            threadID: threadID
        ))
        #expect(summary.latestTurn == nil)
        #expect(!CodexSubagentStoreV2.isTerminalAndHydrated(
            snapshot,
            summary: summary
        ))

        var store = CodexSubagentStoreV2()
        let didApplyMetadata = store.applyChildSnapshotMetadata(summary)
        #expect(didApplyMetadata)
        let child = try #require(store.agent(threadID: threadID.rawValue))
        guard case .working = child.status else {
            Issue.record("Missing ordered latest turn must not reuse an older terminal turn")
            return
        }
        #expect(child.completedAt == nil)
    }

    @Test func detachedChildHydrationPreservesFullHistoryCheck() throws {
        let threadID: ThreadID = "child"
        let olderTurnID: TurnID = "older"
        let latestTurnID: TurnID = "latest"
        let olderTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: olderTurnID),
            status: .completed,
            itemsCoverage: .summary,
            itemsConsistency: .partial,
            lastChangedRevision: StateRevision(1)
        )
        let latestTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: latestTurnID),
            status: .completed,
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(2)
        )
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(2),
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .idle,
                turnOrder: [olderTurnID, latestTurnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: StateRevision(2)
            )],
            turns: [
                olderTurn.key: olderTurn,
                latestTurn.key: latestTurn,
            ]
        )

        let summary = try #require(CodexSubagentChildSnapshotSummary(
            snapshot: snapshot,
            threadID: threadID
        ))
        #expect(summary.latestTurn?.key.turnID == latestTurnID)
        #expect(!CodexSubagentStoreV2.isTerminalAndHydrated(
            snapshot,
            summary: summary
        ))
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

    @Test func mapperPrioritizesFailedAgentStatusWithoutBuildingStatusArray() throws {
        var mapper = CodexAgentStateMapper()
        _ = mapper.applyCanonicalSnapshot(
            parentSnapshot(agentStatuses: ["shutdown", "errored"]),
            parentThreadID: "parent",
            projectedChildren: []
        )

        let event = try #require(mapper.lifecycleEvents.first)
        #expect(event.status == .failed)
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

    @Test func selectedDisplayCostOnlyWeighsUpsertedTurns() throws {
        let oldTurnID: TurnID = "old-turn"
        let currentTurnID: TurnID = "current-turn"
        let projector = CodexCanonicalTranscriptProjector()
        let previousSnapshot = displayCostSnapshot(
            currentRevision: StateRevision(1),
            currentText: "first"
        )
        let previous = try projector.project(
            snapshot: previousSnapshot,
            threadID: "child",
            previous: nil
        ).presentation
        let currentSnapshot = displayCostSnapshot(
            currentRevision: StateRevision(2),
            currentText: "current"
        )
        let limit = 1 * 1_024 * 1_024
        let incremental = try projector.projectSelectedChild(
            snapshot: currentSnapshot,
            threadID: "child",
            previous: previous,
            displayCostLimit: limit
        )

        let incrementalCost = CodexTranscriptDisplayCostWeigher.update(
            output: incremental,
            stoppingAfter: limit
        )
        #expect(!incrementalCost.exceedsDisplayLimit)
        #expect(incremental.projection.update.upsertedTurns.map(\.id)
            == [currentTurnID.rawValue])
        #expect(
            Set(incremental.upsertedTurnDisplayCosts.keys)
                == Set([currentTurnID])
        )

        var ledger = CodexTranscriptDisplayCostLedger()
        ledger.apply(.init(
            upsertedTurnBytes: [oldTurnID: 128],
            removedTurnIDs: [],
            orderByteCount: 512,
            requestByteCount: 0,
            isFullRebuild: true,
            exceedsDisplayLimit: false
        ))
        ledger.apply(incrementalCost)
        #expect(ledger.turnBytesByID[oldTurnID] == 128)
        #expect(ledger.turnBytesByID[currentTurnID] != nil)

        let fullRebuild = try projector.projectSelectedChild(
            snapshot: currentSnapshot,
            threadID: "child",
            previous: nil,
            displayCostLimit: limit
        )
        let fullCost = CodexTranscriptDisplayCostWeigher.update(
            output: fullRebuild,
            stoppingAfter: limit
        )
        #expect(fullRebuild.upsertedTurnDisplayCosts[oldTurnID]?.exceedsLimit == true)
        #expect(fullRebuild.projection.update.upsertedTurns.map(\.id)
            == [oldTurnID.rawValue])
        #expect(fullCost.exceedsDisplayLimit)
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
    func displayCostSnapshot(
        currentRevision: StateRevision,
        currentText: String
    ) -> CanonicalStateSnapshot {
        let threadID: ThreadID = "child"
        let oldTurnID: TurnID = "old-turn"
        let currentTurnID: TurnID = "current-turn"
        let oldItemID: ItemID = "deep-tool"
        let currentItemID: ItemID = "current-message"
        var nested: CodexJSONValue = .null
        for _ in 0..<256 { nested = .array([nested]) }

        let oldItem = CanonicalItem(
            key: .init(
                threadID: threadID,
                turnID: oldTurnID,
                itemID: oldItemID
            ),
            kind: .dynamicToolCall,
            payload: [
                "tool": .string("deep"),
                "arguments": nested,
                "contentItems": .array([]),
                "success": .bool(true),
            ],
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        let currentItem = CanonicalItem(
            key: .init(
                threadID: threadID,
                turnID: currentTurnID,
                itemID: currentItemID
            ),
            kind: .agentMessage,
            payload: [
                "phase": .string("commentary"),
                "text": .string(currentText),
            ],
            authority: .started,
            consistency: .authoritative,
            lastChangedRevision: currentRevision
        )
        let oldTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: oldTurnID),
            status: .completed,
            itemOrder: [oldItemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        let currentTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: currentTurnID),
            status: .inProgress,
            itemOrder: [currentItemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: currentRevision
        )
        return CanonicalStateSnapshot(
            revision: currentRevision,
            threadOrder: [threadID],
            threads: [threadID: CanonicalThread(
                id: threadID,
                status: .active(flags: []),
                turnOrder: [oldTurnID, currentTurnID],
                history: .init(turnsCoverage: .full),
                isLoaded: true,
                consistency: .authoritative,
                lastChangedRevision: currentRevision
            )],
            turns: [
                oldTurn.key: oldTurn,
                currentTurn.key: currentTurn,
            ],
            items: [
                oldItem.key: oldItem,
                currentItem.key: currentItem,
            ]
        )
    }

    func parentSnapshot(
        close: Bool = false,
        agentStatuses: [String] = []
    ) -> CanonicalStateSnapshot {
        let threadID: ThreadID = "parent"
        let turnID: TurnID = "parent-turn"
        let itemID: ItemID = close ? "close" : "spawn"
        let agentStates = Dictionary(uniqueKeysWithValues: agentStatuses.enumerated().map { index, status in
            ("agent-\(index)", CodexJSONValue.dictionary(["status": .string(status)]))
        })
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
                "agentsStates": .dictionary(agentStates),
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
            path: "/Users/test/.codex/sessions/rollout-child.jsonl",
            source: .dictionary([
                "thread_spawn": .dictionary([
                    "agent_path": .string("/root/scout"),
                ]),
            ]),
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

    func indexChild(
        revision: StateRevision = StateRevision(2),
        latestTurnID: TurnID = "child-turn",
        latestTurnStatus: CanonicalTurnStatus = .inProgress
    ) -> CanonicalThreadIndexSummary {
        CanonicalThreadIndexSummary(
            id: "child",
            order: 1,
            status: .active(flags: []),
            latestTurnID: latestTurnID,
            latestTurnStatus: latestTurnStatus,
            isArchived: false,
            isLoaded: true,
            name: nil,
            preview: nil,
            cwd: nil,
            parentThreadID: "parent",
            agentNickname: "Scout",
            agentRole: "explorer",
            path: "/Users/test/.codex/sessions/rollout-child.jsonl",
            updatedAt: ProtocolSeconds(1_700_000_000),
            lastChangedRevision: revision,
            attentionRevision: revision,
            hasPendingServerRequest: false
        )
    }
}
