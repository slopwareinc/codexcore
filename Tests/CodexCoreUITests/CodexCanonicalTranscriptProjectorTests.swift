import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexCanonicalTranscriptProjectorTests {
    @Test func rebuildIsDeterministicAndPreservesTurnGrammar() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let items: [CanonicalItem] = [
            item(threadID, turnID, "user", .userMessage, [
                "content": .array([.dictionary(["type": .string("text"), "text": .string("Question")])])
            ]),
            item(threadID, turnID, "hook", .hookPrompt),
            item(threadID, turnID, "commentary", .agentMessage, [
                "phase": .string("commentary"), "text": .string("Checking")
            ]),
            item(threadID, turnID, "plan", .plan, ["text": .string("1. Inspect")]),
            item(threadID, turnID, "reasoning", .reasoning, [
                "summary": .array([.string("Done thinking")])
            ]),
            item(threadID, turnID, "command", .commandExecution, [
                "command": .string("pwd"), "status": .string("completed"), "exitCode": .int(0)
            ]),
            item(threadID, turnID, "file", .fileChange, [
                "changes": .array([.dictionary(["path": .string("A.swift")])])
            ]),
            item(threadID, turnID, "mcp", .mcpToolCall, [
                "server": .string("docs"), "tool": .string("search")
            ]),
            item(threadID, turnID, "dynamic", .dynamicToolCall, [
                "namespace": .string("product"), "tool": .string("show")
            ]),
            item(threadID, turnID, "collab", .collabAgentToolCall, [
                "tool": .string("spawnAgent"),
                "receiverThreadIds": .array([.string("child-thread")])
            ]),
            item(threadID, turnID, "subagent", .subAgentActivity, [
                "kind": .string("interacted"), "agentThreadId": .string("child-thread")
            ]),
            item(threadID, turnID, "web", .webSearch, ["query": .string("Swift actors")]),
            item(threadID, turnID, "view", .imageView),
            item(threadID, turnID, "sleep", .sleep),
            item(threadID, turnID, "image", .imageGeneration),
            item(threadID, turnID, "review-in", .enteredReviewMode),
            item(threadID, turnID, "review-out", .exitedReviewMode),
            item(threadID, turnID, "compact", .contextCompaction),
            item(threadID, turnID, "future", .unknown("alphaFuture")),
            item(threadID, turnID, "answer", .agentMessage, [
                "phase": .string("final_answer"), "text": .string("Answer")
            ])
        ]
        let snapshot = state(
            revision: 8,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: items.map(\.key.itemID), revision: 8)],
            items: items
        )

        let projector = CodexCanonicalTranscriptProjector()
        let first = projector.rebuild(snapshot: snapshot, threadID: threadID)
        let second = projector.rebuild(snapshot: snapshot, threadID: threadID)

        #expect(first == second)
        let projected = try #require(first.presentation.transcript.turns.first)
        #expect(projected.userMessage?.text == "Question")
        #expect(projected.finalAnswer?.text == "Answer")
        #expect(projected.finalAnswer?.isStreaming == false)
        #expect(projected.narrative.contains { $0.id == "commentary" })
        #expect(projected.narrative.contains { $0.id == "plan" })
        #expect(projected.narrative.contains { $0.id == "dynamic" })
        #expect(projected.narrative.contains { $0.id == "view" })
        #expect(projected.narrative.contains { $0.id == "sleep" })
        #expect(projected.narrative.contains { $0.id == "review-in" })
        #expect(projected.narrative.contains { $0.id == "review-out" })
        #expect(projected.narrative.contains { $0.id == "context-compacted-turn" })
        #expect(projected.narrative.contains { $0.id == "future" })
        let rows = projected.narrative.flatMap(\.workRows)
        #expect(rows.contains { $0.id == "command" })
        #expect(rows.contains { $0.id == "file" })
        #expect(rows.contains { $0.id == "mcp" })
        #expect(rows.contains { $0.id == "web" })
        #expect(rows.contains { $0.id == "collab" })
        #expect(rows.contains { $0.id == "image" })
    }

    @Test func liveChunksAndCompletedPayloadUseTheSameProjectionPath() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: ["answer"],
            itemsCoverage: .full,
            lastChangedRevision: StateRevision(2)
        )
        let live = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "answer"),
            kind: .agentMessage,
            payload: ["phase": .string("final_answer"), "text": .string("Hel")],
            authority: .started,
            liveOverlay: .init(agentMessage: .init(chunks: ["lo", " world"])),
            lastChangedRevision: StateRevision(2)
        )
        let snapshot = state(revision: 2, threadID: threadID, turns: [turn], items: [live])

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        #expect(projected.finalAnswer?.text == "Hello world")
        #expect(projected.finalAnswer?.isStreaming == true)
    }

    @Test func equivalentHydratedAndLiveCanonicalStateProjectIdentically() {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let finalItem = item(threadID, turnID, "answer", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("Same answer")
        ], revision: 4)
        let liveTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            startedAt: ProtocolSeconds(10),
            completedAt: ProtocolSeconds(12),
            itemOrder: ["answer"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(4)
        )
        let hydratedTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            startedAt: ProtocolSeconds(10),
            completedAt: ProtocolSeconds(12),
            itemOrder: ["answer"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(40)
        )
        let live = state(revision: 4, threadID: threadID, turns: [liveTurn], items: [finalItem])
        let history = state(revision: 40, threadID: threadID, turns: [hydratedTurn], items: [
            item(threadID, turnID, "answer", .agentMessage, [
                "phase": .string("final_answer"), "text": .string("Same answer")
            ], revision: 40)
        ])
        let projector = CodexCanonicalTranscriptProjector()

        #expect(
            projector.rebuild(snapshot: live, threadID: threadID).presentation.transcript
                == projector.rebuild(snapshot: history, threadID: threadID).presentation.transcript
        )
    }

    @Test func liveCompactionExtensionAndHydratedItemProjectIdentically() {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let hydratedItem = item(threadID, turnID, "server-compaction", .contextCompaction)
        let hydrated = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: [hydratedItem.key.itemID],
                revision: 2
            )],
            items: [hydratedItem]
        )
        let live = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                extensions: ["contextCompacted": .bool(true)],
                revision: 2
            )],
            items: []
        )
        let projector = CodexCanonicalTranscriptProjector()

        #expect(
            projector.rebuild(snapshot: hydrated, threadID: threadID).presentation.transcript
                == projector.rebuild(snapshot: live, threadID: threadID).presentation.transcript
        )
    }

    @Test func incrementalProjectionUsesAggregateTurnRevisionAndLeavesUnrelatedTurnUntouched() throws {
        let threadID: ThreadID = "thread"
        let firstTurnID: TurnID = "one"
        let secondTurnID: TurnID = "two"
        let firstItem = item(threadID, firstTurnID, "a", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("A")
        ], revision: 1)
        let secondItem = item(threadID, secondTurnID, "b", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("B")
        ], revision: 1)
        let initial = state(
            revision: 1,
            threadID: threadID,
            turns: [
                turn(firstTurnID, threadID: threadID, itemIDs: ["a"], revision: 1),
                turn(secondTurnID, threadID: threadID, itemIDs: ["b"], revision: 1)
            ],
            items: [firstItem, secondItem]
        )
        let projector = CodexCanonicalTranscriptProjector()
        let previous = projector.rebuild(snapshot: initial, threadID: threadID).presentation

        let changedItem = item(threadID, secondTurnID, "b", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("B2")
        ], revision: 2)
        let changed = state(
            revision: 2,
            threadID: threadID,
            turns: [
                turn(firstTurnID, threadID: threadID, itemIDs: ["a"], revision: 1),
                turn(secondTurnID, threadID: threadID, itemIDs: ["b"], revision: 2)
            ],
            items: [firstItem, changedItem]
        )
        let result = try projector.project(
            snapshot: changed,
            threadID: threadID,
            previous: previous
        )

        #expect(result.update.sourceRevision == StateRevision(2))
        #expect(result.update.turnOrder == nil)
        #expect(result.update.upsertedTurns.map(\.id) == [secondTurnID.rawValue])
        #expect(result.update.dirtyTurnIDs == [secondTurnID])
        #expect(result.presentation.turnsByID[firstTurnID] == previous.turnsByID[firstTurnID])
        #expect(result.presentation.turnsByID[secondTurnID]?.finalAnswer?.text == "B2")
    }

    @Test func localSubmissionIsOptimisticUntilCanonicalUserEcho() throws {
        let threadID: ThreadID = "thread"
        let intentID: SubmissionIntentID = "client-1"
        let intent = SubmissionIntent(
            id: intentID,
            threadID: threadID,
            input: [.dictionary(["type": .string("text"), "text": .string("Hello")])],
            localOrdinal: 1,
            state: .pending,
            lastChangedRevision: StateRevision(1)
        )
        let pending = CanonicalStateSnapshot(
            revision: StateRevision(1),
            submissionIntents: [intentID: intent]
        )
        let projector = CodexCanonicalTranscriptProjector()
        let optimistic = projector.rebuild(snapshot: pending, threadID: threadID)
        let provisional = try #require(optimistic.presentation.transcript.turns.first)
        #expect(provisional.id == "local-client-1")
        #expect(provisional.userMessage?.text == "Hello")
        #expect(provisional.userMessage?.isOptimistic == true)

        let turnID: TurnID = "server-turn"
        let echoedUser = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "server-user"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary(["type": .string("text"), "text": .string("Hello")])])
            ],
            authority: .completed,
            clientUserMessageID: intentID,
            lastChangedRevision: StateRevision(2)
        )
        let echoed = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["server-user"], revision: 2)],
            items: [echoedUser],
            intents: [intentID: intent]
        )
        let reconciled = projector.rebuild(snapshot: echoed, threadID: threadID).presentation.transcript
        #expect(reconciled.turns.map(\.id) == [turnID.rawValue])
        #expect(reconciled.turns.first?.userMessage?.isOptimistic == false)
        #expect(reconciled.turns.first?.userMessage?.clientID == intentID.rawValue)
    }

    @Test func onlyPendingTypedRequestsForThreadArePlacedAndDirtyTheirTurn() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, revision: 1)],
            items: []
        )
        let projector = CodexCanonicalTranscriptProjector()
        let previous = projector.rebuild(snapshot: snapshot, threadID: threadID).presentation
        let pending = request(
            id: .integer(7),
            kind: .commandApproval,
            threadID: threadID,
            turnID: turnID,
            itemID: "command",
            sequence: 1
        )
        let otherThread = request(
            id: .string("7"),
            kind: .fileChangeApproval,
            threadID: "other",
            turnID: turnID,
            sequence: 2
        )
        let terminal = CodexServerRequestSnapshot(
            key: .init(connectionEpoch: 1, requestID: .string("terminal")),
            method: CodexServerRequestKind.permissionsApproval.method,
            kind: .permissionsApproval,
            scope: .init(threadID: threadID.rawValue, turnID: turnID.rawValue),
            approvalCorrelation: nil,
            registrationSequence: 3,
            registeredRevision: 3,
            state: .terminal(.init(
                cause: .serverResolved,
                responseDisposition: .abandoned,
                revision: 4
            ))
        )
        let result = try projector.project(
            snapshot: snapshot,
            threadID: threadID,
            requests: [otherThread, terminal, pending],
            previous: previous
        )

        #expect(result.presentation.pendingRequests.count == 1)
        #expect(result.presentation.requestSourceRevision == 4)
        #expect(result.update.requestSourceRevision == 4)
        #expect(result.presentation.pendingRequests.first?.kind == .commandApproval)
        #expect(result.presentation.pendingRequests.first?.summary == "Run command")
        #expect(result.update.dirtyTurnIDs == [turnID])
        let upsertedTurnIDs: [String] = result.update.upsertedTurns.map { $0.id }
        #expect(upsertedTurnIDs == [turnID.rawValue])
    }

    @Test func staleCanonicalRevisionCannotRegressPresentation() throws {
        let threadID: ThreadID = "thread"
        let previous = CodexCanonicalTranscriptPresentation(
            threadID: threadID,
            sourceRevision: StateRevision(10)
        )
        #expect(throws: CodexCanonicalTranscriptProjectionError.self) {
            try CodexCanonicalTranscriptProjector().project(
                snapshot: .init(revision: StateRevision(9)),
                threadID: threadID,
                previous: previous
            )
        }
    }

    @Test func staleRequestRevisionCannotRegressPendingPrompts() {
        let threadID: ThreadID = "thread"
        let previous = CodexCanonicalTranscriptPresentation(
            threadID: threadID,
            sourceRevision: .zero,
            requestSourceRevision: 10
        )
        #expect(throws: CodexCanonicalTranscriptProjectionError.self) {
            try CodexCanonicalTranscriptProjector().project(
                snapshot: .init(),
                threadID: threadID,
                requestRevision: 9,
                previous: previous
            )
        }
    }
}

private extension CodexCanonicalTranscriptProjectorTests {
    func state(
        revision: UInt64,
        threadID: ThreadID,
        turns: [CanonicalTurn],
        items: [CanonicalItem],
        intents: [SubmissionIntentID: SubmissionIntent] = [:]
    ) -> CanonicalStateSnapshot {
        let thread = CanonicalThread(
            id: threadID,
            status: .idle,
            turnOrder: turns.map(\.key.turnID),
            history: .init(turnsCoverage: .full),
            consistency: .authoritative,
            lastChangedRevision: StateRevision(revision)
        )
        return .init(
            revision: StateRevision(revision),
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: Dictionary(uniqueKeysWithValues: turns.map { ($0.key, $0) }),
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) }),
            submissionIntents: intents
        )
    }

    func turn(
        _ id: TurnID,
        threadID: ThreadID,
        itemIDs: [ItemID] = [],
        extensions: [String: CodexJSONValue] = [:],
        revision: UInt64
    ) -> CanonicalTurn {
        .init(
            key: .init(threadID: threadID, turnID: id),
            status: .completed,
            duration: DurationMilliseconds(20),
            itemOrder: itemIDs,
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            extensions: extensions,
            lastChangedRevision: StateRevision(revision)
        )
    }

    func item(
        _ threadID: ThreadID,
        _ turnID: TurnID,
        _ itemID: ItemID,
        _ kind: ThreadItemKind,
        _ payload: [String: CodexJSONValue] = [:],
        revision: UInt64 = 8
    ) -> CanonicalItem {
        .init(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: kind,
            payload: payload,
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(revision)
        )
    }

    func request(
        id: CodexServerRequestID,
        kind: CodexServerRequestKind,
        threadID: ThreadID,
        turnID: TurnID,
        itemID: ItemID? = nil,
        sequence: UInt64
    ) -> CodexServerRequestSnapshot {
        .init(
            key: .init(connectionEpoch: 1, requestID: id),
            method: kind.method,
            kind: kind,
            scope: .init(
                threadID: threadID.rawValue,
                turnID: turnID.rawValue,
                itemID: itemID?.rawValue
            ),
            approvalCorrelation: nil,
            registrationSequence: sequence,
            registeredRevision: sequence,
            state: .pending
        )
    }
}

private extension CodexNarrativeEntry {
    var workRows: [CodexWorkRowV2] {
        if case .workGroup(let group) = self { group.rows } else { [] }
    }
}
