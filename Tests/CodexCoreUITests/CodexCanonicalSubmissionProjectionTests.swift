@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexCanonicalSubmissionProjectionTests {
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
                "content": .array([.dictionary([
                    "type": .string("text"),
                    "text": .string("Hello"),
                ])]),
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
        let reconciled = projector.rebuild(
            snapshot: echoed,
            threadID: threadID
        ).presentation.transcript
        #expect(reconciled.turns.map(\.id) == [turnID.rawValue])
        #expect(reconciled.turns.first?.userMessage?.isOptimistic == false)
        #expect(reconciled.turns.first?.userMessage?.clientID == intentID.rawValue)
    }

    @Test func steerAppendsAUserMessageWithoutReplacingTheOriginalPrompt() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let original = item(threadID, turnID, "original", .userMessage, [
            "content": .array([.dictionary([
                "type": .string("text"),
                "text": .string("Original prompt"),
            ])]),
        ])
        let commentary = item(threadID, turnID, "work", .agentMessage, [
            "phase": .string("commentary"),
            "text": .string("Working"),
        ])
        let steered = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "steered"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary([
                    "type": .string("text"),
                    "text": .string("New direction"),
                ])]),
            ],
            authority: .completed,
            clientUserMessageID: "steer-client",
            consistency: .authoritative,
            lastChangedRevision: StateRevision(8)
        )
        let continued = item(threadID, turnID, "continued", .agentMessage, [
            "phase": .string("commentary"),
            "text": .string("Following the new direction"),
        ])
        let answer = item(threadID, turnID, "answer", .agentMessage, [
            "phase": .string("final_answer"),
            "text": .string("Done"),
        ])
        let projected = CodexCanonicalTranscriptProjector().rebuild(
            snapshot: state(
                revision: 8,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["original", "work", "steered", "continued", "answer"],
                    revision: 8
                )],
                items: [original, commentary, steered, continued, answer]
            ),
            threadID: threadID
        ).presentation.transcript

        let turn = try #require(projected.turns.first)
        #expect(turn.userMessage?.text == "Original prompt")
        #expect(turn.steeredMessages.map(\.text) == ["New direction"])
        #expect(turn.steeredMessages.first?.clientID == "steer-client")
        #expect(turn.conversationSegments.count == 2)
        #expect(turn.conversationSegments[0].steeredMessage == nil)
        #expect(turn.conversationSegments[0].narrative.first?.id == "work")
        #expect(turn.conversationSegments[1].steeredMessage?.text == "New direction")
        #expect(turn.conversationSegments[1].narrative.first?.id == "continued")
        #expect(turn.finalAnswer?.text == "Done")
    }

    @Test func optimisticSteerReconcilesInPlaceWithoutDuplicatingItsBubble() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let intentID: SubmissionIntentID = "steer-client"
        let intent = SubmissionIntent(
            id: intentID,
            threadID: threadID,
            expectedTurnID: turnID,
            input: [.dictionary(["type": .string("text"), "text": .string("New direction")])],
            localOrdinal: 2,
            state: .pending,
            lastChangedRevision: StateRevision(2)
        )
        let original = item(threadID, turnID, "original", .userMessage, [
            "content": .array([.dictionary([
                "type": .string("text"),
                "text": .string("Original prompt"),
            ])]),
        ], revision: 2)
        let activeTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: ["original"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(2)
        )
        let projector = CodexCanonicalTranscriptProjector()
        let optimistic = projector.rebuild(
            snapshot: state(
                revision: 2,
                threadID: threadID,
                turns: [activeTurn],
                items: [original],
                intents: [intentID: intent]
            ),
            threadID: threadID
        ).presentation.transcript

        #expect(optimistic.turns.first?.userMessage?.text == "Original prompt")
        #expect(optimistic.turns.first?.steeredMessages.map(\.text) == ["New direction"])
        #expect(optimistic.turns.first?.steeredMessages.first?.isOptimistic == true)

        let echo = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "server-steer"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary([
                    "type": .string("text"),
                    "text": .string("New direction"),
                ])]),
            ],
            authority: .completed,
            clientUserMessageID: intentID,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(3)
        )
        let echoedTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: ["original", "server-steer"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(3)
        )
        let reconciled = projector.rebuild(
            snapshot: state(
                revision: 3,
                threadID: threadID,
                turns: [echoedTurn],
                items: [original, echo],
                intents: [intentID: intent]
            ),
            threadID: threadID
        ).presentation.transcript

        #expect(reconciled.turns.first?.userMessage?.text == "Original prompt")
        #expect(reconciled.turns.first?.steeredMessages.map(\.text) == ["New direction"])
        #expect(reconciled.turns.first?.steeredMessages.first?.isOptimistic == false)
        #expect(reconciled.turns.first?.steeredMessages.first?.clientID == intentID.rawValue)
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
            snapshot: .init(
                revision: StateRevision(1),
                submissionIntents: [intentID: intent]
            ),
            threadID: threadID
        )
        let optimisticUser = try #require(
            optimistic.presentation.transcript.turns.first?.userMessage
        )
        #expect(optimisticUser.text == "Review this file")
        #expect(optimisticUser.referencedFiles.map(\.path) == ["/tmp/reference.swift"])
        #expect(optimisticUser.displayText == "Review this file\n\n📎 reference.swift")

        let turnID: TurnID = "server-turn"
        let user = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "server-user"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary([
                    "type": .string("text"),
                    "text": .string(rawPrompt),
                ])]),
            ],
            authority: .completed,
            clientUserMessageID: intentID,
            lastChangedRevision: StateRevision(2)
        )
        let canonical = projector.rebuild(
            snapshot: state(
                revision: 2,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["server-user"],
                    revision: 2
                )],
                items: [user],
                intents: [intentID: intent]
            ),
            threadID: threadID
        )
        let canonicalUser = try #require(
            canonical.presentation.transcript.turns.first?.userMessage
        )
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
            snapshot: .init(
                revision: StateRevision(1),
                submissionIntents: [intentID: intent]
            ),
            threadID: threadID
        )
        let user = try #require(projected.presentation.transcript.turns.first?.userMessage)
        #expect(user.text.isEmpty)
        #expect(user.displayText == "📎 reference.png")
        #expect(user.rawText == rawPrompt)
    }
}

private extension CodexCanonicalSubmissionProjectionTests {
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
        revision: UInt64
    ) -> CanonicalTurn {
        .init(
            key: .init(threadID: threadID, turnID: id),
            status: .completed,
            duration: DurationMilliseconds(20),
            itemOrder: itemIDs,
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
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
}
