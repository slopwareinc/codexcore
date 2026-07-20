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
        #expect(rows.contains { $0.id == "agent:child-thread" })
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

    @Test func fileReferenceContextIsHiddenFromOptimisticAndCanonicalUserBubbles() throws {
        let threadID: ThreadID = "thread"
        let rawPrompt = CodexFileReferencePromptCodec.encode(
            files: [CodexReferencedFile(path: "/tmp/reference.swift", kind: .file)],
            request: "Review this file"
        )
        let intentID: SubmissionIntentID = "client-file"
        let intent = SubmissionIntent(
            id: intentID,
            threadID: threadID,
            input: [.dictionary(["type": .string("text"), "text": .string(rawPrompt)])],
            localOrdinal: 1,
            state: .pending,
            lastChangedRevision: StateRevision(1)
        )
        let projector = CodexCanonicalTranscriptProjector()
        let optimistic = projector.rebuild(
            snapshot: .init(revision: StateRevision(1), submissionIntents: [intentID: intent]),
            threadID: threadID
        )
        let optimisticUser = try #require(optimistic.presentation.transcript.turns.first?.userMessage)
        #expect(optimisticUser.text == "Review this file")
        #expect(optimisticUser.referencedFiles.map(\.path) == ["/tmp/reference.swift"])
        #expect(optimisticUser.displayText == "Review this file\n\n📎 reference.swift")

        let turnID: TurnID = "server-turn"
        let user = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "server-user"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary(["type": .string("text"), "text": .string(rawPrompt)])])
            ],
            authority: .completed,
            clientUserMessageID: intentID,
            lastChangedRevision: StateRevision(2)
        )
        let canonical = projector.rebuild(
            snapshot: state(
                revision: 2,
                threadID: threadID,
                turns: [turn(turnID, threadID: threadID, itemIDs: ["server-user"], revision: 2)],
                items: [user],
                intents: [intentID: intent]
            ),
            threadID: threadID
        )
        let canonicalUser = try #require(canonical.presentation.transcript.turns.first?.userMessage)
        #expect(canonicalUser.text == "Review this file")
        #expect(canonicalUser.rawText == rawPrompt)
        #expect(canonicalUser.referencedFiles.map(\.path) == ["/tmp/reference.swift"])
    }

    @Test func fileOnlySubmissionHasAVisibleAttachmentBubble() throws {
        let threadID: ThreadID = "thread"
        let rawPrompt = CodexFileReferencePromptCodec.encode(
            files: [CodexReferencedFile(path: "/tmp/reference.png", kind: .image)],
            request: ""
        )
        let intentID: SubmissionIntentID = "client-file-only"
        let intent = SubmissionIntent(
            id: intentID,
            threadID: threadID,
            input: [.dictionary(["type": .string("text"), "text": .string(rawPrompt)])],
            localOrdinal: 1,
            state: .pending,
            lastChangedRevision: StateRevision(1)
        )
        let projected = CodexCanonicalTranscriptProjector().rebuild(
            snapshot: .init(revision: StateRevision(1), submissionIntents: [intentID: intent]),
            threadID: threadID
        )
        let user = try #require(projected.presentation.transcript.turns.first?.userMessage)
        #expect(user.text.isEmpty)
        #expect(user.displayText == "📎 reference.png")
        #expect(user.rawText == rawPrompt)
    }

    @Test func pendingTypedRequestsForThreadArePlacedAndDirtyTheirTurn() throws {
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
        let result = try projector.project(
            snapshot: snapshot,
            threadID: threadID,
            requests: [otherThread, pending],
            requestRevision: 4,
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

    @Test func multiAgentTerminalWaitReconcilesEveryStableAgentRow() throws {
        let threadID: ThreadID = "parent"
        let turnID: TurnID = "turn"
        let agentIDs = (1...5).map { "child-\($0)" }
        let names = ["Peirce", "Banach", "Hubble", "Maxwell", "Euler"]
        var items = zip(agentIDs, names).enumerated().map { index, pair in
            item(threadID, turnID, ItemID("started-\(index)"), .subAgentActivity, [
                "kind": .string("started"),
                "agentThreadId": .string(pair.0),
                "agentPath": .string("/root/\(pair.1.lowercased())"),
            ])
        }
        items.append(item(threadID, turnID, "wait", .collabAgentToolCall, [
            "tool": .string("wait"),
            "receiverThreadIds": .array(agentIDs.map(CodexJSONValue.string)),
            "agentsStates": .dictionary(Dictionary(uniqueKeysWithValues: agentIDs.map {
                ($0, .dictionary(["status": .string("completed")]))
            })),
        ]))
        let snapshot = state(
            revision: 8,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: items.map(\.key.itemID),
                revision: 8
            )],
            items: items
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(
                snapshot: snapshot,
                threadID: threadID
            ).presentation.transcript.turns.first
        )
        let agents = projected.narrative.flatMap(\.workRows).compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let agent) = row else { return nil }
            return agent
        }

        #expect(agents.count == 5)
        #expect(Set(agents.map(\.id)).count == 5)
        #expect(Set(agents.flatMap(\.agentThreadIDs)) == Set(agentIDs))
        #expect(agents.allSatisfy { $0.action == .waited && $0.status == .completed })
        #expect(Set(agents.flatMap(\.agentNames)) == Set(names))
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
    ) -> CodexPendingInteractionSnapshot {
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
            arrivalOrdinal: sequence
        )
    }
}

private extension CodexNarrativeEntry {
    var workRows: [CodexWorkRowV2] {
        if case .workGroup(let group) = self { group.rows } else { [] }
    }
}
