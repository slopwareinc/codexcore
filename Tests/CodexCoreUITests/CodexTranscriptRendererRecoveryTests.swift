import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexTranscriptRendererRecoveryTests {
    @Test func planItemsAreAdaptedThroughTheTypedEventRegistry() throws {
        let item = CanonicalItem(
            key: .init(threadID: "thread", turnID: "turn", itemID: "plan"),
            kind: .plan,
            payload: [
                "text": .string("Inspect the transcript"),
                "steps": .array([
                    .dictionary([
                        "step": .string("Read the protocol"),
                        "status": .string("inProgress")
                    ])
                ])
            ],
            authority: .completed
        )

        let event = try #require(
            CodexTranscriptEventRegistry().event(for: item, completed: true)
        )

        guard case .structuredCard(let card) = event else {
            Issue.record("Expected the plan adapter to emit a structured card")
            return
        }
        #expect(card.kind == .proposedPlan)
        #expect(card.title == "Inspect the transcript")
        #expect(card.steps.map(\.title) == ["Read the protocol"])
        #expect(card.steps.first?.status == .inProgress)
    }

    @Test func malformedMCPBlocksFailClosedAndKnownBlocksStayTyped() throws {
        let item = CanonicalItem(
            key: .init(threadID: "thread", turnID: "turn", itemID: "mcp"),
            kind: .mcpToolCall,
            payload: [
                "result": .dictionary([
                    "content": .array([
                        .dictionary(["type": .string("text"), "text": .string("done")]),
                        .dictionary(["type": .string("image"), "url": .string("https://example.com/image.png")]),
                        .dictionary(["type": .string("futureBlock"), "value": .string("do not render")]),
                        .string("malformed")
                    ]),
                    "structuredContent": .dictionary(["ok": .bool(true)])
                ])
            ],
            authority: .completed
        )

        let event = try #require(CodexTranscriptEventRegistry().event(for: item, completed: true))
        guard case .mcpContent(let blocks) = event else {
            Issue.record("Expected typed MCP content")
            return
        }
        #expect(blocks.count == 3)
        #expect(blocks[0] == .text("done"))
        guard case .image(let source, _, _) = blocks[1] else {
            Issue.record("Expected typed image content")
            return
        }
        #expect(source == "https://example.com/image.png")
        guard case .structured(let fields) = blocks[2] else {
            Issue.record("Expected typed structured content")
            return
        }
        #expect(fields["ok"] == .bool(true))
    }

    @Test func userInputsAndMemoryCitationsRemainTypedAcrossProjection() throws {
        let user = CanonicalItem(
            key: .init(threadID: "thread", turnID: "turn", itemID: "user"),
            kind: .userMessage,
            payload: [
                "content": .array([
                    .dictionary(["type": .string("text"), "text": .string("Review this")]),
                    .dictionary(["type": .string("localImage"), "path": .string("/tmp/screenshot.png")]),
                    .dictionary(["type": .string("mention"), "name": .string("Docs"), "path": .string("/tmp/docs")])
                ]),
                "additionalContext": .dictionary([
                    "workspace": .string("trusted workspace")
                ])
            ],
            authority: .completed
        )
        let assistant = CanonicalItem(
            key: .init(threadID: "thread", turnID: "turn", itemID: "answer"),
            kind: .agentMessage,
            payload: [
                "phase": .string("final_answer"),
                "text": .string("The screenshot is clear."),
                "memoryCitation": .dictionary([
                    "threadIds": .array([.string("memory-thread")]),
                    "entries": .array([
                        .dictionary([
                            "path": .string("docs/README.md"),
                            "lineStart": .int(4),
                            "lineEnd": .int(8),
                            "note": .string("Project conventions")
                        ])
                    ])
                ])
            ],
            authority: .completed
        )

        let events = CodexTranscriptEventRegistry()
        guard case .userContext(let attachments, let context)? = events.event(for: user, completed: true) else {
            Issue.record("Expected typed user context")
            return
        }
        #expect(attachments.map(\.kind) == [.image, .mention])
        #expect(attachments.first?.value == "/tmp/screenshot.png")
        #expect(context.first?.value == "trusted workspace")

        guard case .memoryCitations(let citations)? = events.event(for: assistant, completed: true) else {
            Issue.record("Expected typed memory citation")
            return
        }
        #expect(citations.first?.path == "docs/README.md")
        #expect(citations.first?.lineStart == 4)
        #expect(citations.first?.sourceThreadIDs == ["memory-thread"])
    }

    @Test func canonicalProjectionCarriesCardsCitationsAndMCPBlocks() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let items: [CanonicalItem] = [
            .init(
                key: .init(threadID: threadID, turnID: turnID, itemID: "plan"),
                kind: .plan,
                payload: [
                    "title": .string("Proposed plan"),
                    "steps": .array([
                        .dictionary(["title": .string("Implement adapter"), "status": .string("completed")])
                    ])
                ],
                authority: .completed
            ),
            .init(
                key: .init(threadID: threadID, turnID: turnID, itemID: "mcp"),
                kind: .mcpToolCall,
                payload: [
                    "server": .string("docs"),
                    "tool": .string("search"),
                    "result": .dictionary([
                        "content": .array([.dictionary(["type": .string("text"), "text": .string("found")])])
                    ])
                ],
                authority: .completed
            ),
            .init(
                key: .init(threadID: threadID, turnID: turnID, itemID: "answer"),
                kind: .agentMessage,
                payload: [
                    "phase": .string("final_answer"),
                    "text": .string("Done"),
                    "memoryCitation": .dictionary([
                        "entries": .array([.dictionary([
                            "path": .string("docs/README.md"),
                            "lineStart": .int(1),
                            "lineEnd": .int(2),
                            "note": .string("Guide")
                        ])])
                    ])
                ],
                authority: .completed
            )
        ]
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            itemOrder: items.map(\.key.itemID),
            itemsCoverage: .full
        )
        let thread = CanonicalThread(
            id: threadID,
            status: .idle,
            turnOrder: [turnID],
            history: .init(mode: .legacy, turnsCoverage: .full)
        )
        let snapshot = CanonicalStateSnapshot(
            revision: .init(1),
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: [turn.key: turn],
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        #expect(projected.structuredCards.count == 1)
        #expect(projected.structuredCards.first?.kind == .proposedPlan)
        #expect(projected.finalAnswer?.memoryCitations.count == 1)
        let rows = projected.narrative.compactMap { entry -> CodexWorkGroupV2? in
            guard case .workGroup(let group) = entry else { return nil }
            return group
        }.flatMap(\.rows)
        let mcp: CodexMCPToolCallRowV2? = rows.compactMap { row in
            guard case .mcpToolCall(let value) = row else { return nil }
            return value
        }.first
        #expect(mcp?.contentBlocks == [CodexMCPContentBlockV2.text("found")])
    }
}
