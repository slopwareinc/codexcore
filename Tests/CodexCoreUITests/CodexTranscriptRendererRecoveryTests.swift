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

    @Test func typedRecoveryEventsExplainOverloadAndStreamFailuresWithoutRawErrors() {
        let overload = CanonicalTurn(
            key: .init(threadID: "thread", turnID: "overload"),
            status: .failed,
            error: .init(
                message: "busy",
                codexErrorInfo: .dictionary(["type": .string("serverOverloaded")])
            )
        )
        let stream = CanonicalTurn(
            key: .init(threadID: "thread", turnID: "stream"),
            status: .failed,
            error: .init(
                message: "lost",
                codexErrorInfo: .dictionary(["type": .string("responseStreamDisconnected")])
            )
        )
        let registry = CodexTranscriptEventRegistry()
        guard case .recovery(let overloadNotice)? = registry.events(for: overload).first else {
            Issue.record("Expected overload recovery")
            return
        }
        #expect(overloadNotice.kind == .overload)
        #expect(overloadNotice.canRetry)
        #expect(overloadNotice.message.contains("busy"))
        guard case .recovery(let streamNotice)? = registry.events(for: stream).first else {
            Issue.record("Expected stream recovery")
            return
        }
        #expect(streamNotice.kind == .streamFailure)
        #expect(streamNotice.message.contains("disconnected"))
    }

    @Test func rendererRegistrySelectsTypedNodesWithoutAProtocolSwitch() {
        let card = CodexStructuredTranscriptCardV2(
            id: "todo",
            kind: .todo,
            title: "Todo",
            steps: [.init(id: "step", title: "Ship")],
            status: .inProgress
        )
        let entry = CodexNarrativeEntry.structuredCard(card)
        let node = CodexTranscriptRendererRegistry.default.node(for: entry)
        #expect(node == .structuredCard(card))
        #expect(node?.id == "todo")
    }

    @Test func approvalReviewAndHookExtensionsBecomeStableTypedCards() throws {
        let turn = CanonicalTurn(
            key: .init(threadID: "thread", turnID: "turn"),
            status: .completed,
            extensions: [
                "autoApprovalReview:review-1": .dictionary([
                    "reviewId": .string("review-1"),
                    "review": .dictionary([
                        "status": .string("timedOut"),
                        "rationale": .string("Review deadline elapsed"),
                        "riskLevel": .string("high")
                    ])
                ]),
                "hook:hook-1": .dictionary([
                    "run": .dictionary([
                        "id": .string("hook-1"),
                        "eventName": .string("preToolUse"),
                        "handlerType": .string("command"),
                        "status": .string("completed"),
                        "entries": .array([.dictionary(["text": .string("checked")])])
                    ])
                ])
            ]
        )
        let events = CodexTranscriptEventRegistry().events(for: turn)
        guard case .approvalReview(let review) = events[0] else {
            Issue.record("Expected approval review card")
            return
        }
        #expect(review.status == .timedOut)
        #expect(review.title == "Approval timed out")
        guard case .hookActivity(let hook) = events[1] else {
            Issue.record("Expected hook activity")
            return
        }
        #expect(hook.label == "preToolUse · command")
        #expect(hook.entries == ["checked"])
    }

    @Test func markdownProjectionUsesTypedMathAndMermaidBlocks() {
        let blocks = CodexBlockProjector.project(
            "$$x^2 + y^2$$\n\n```mermaid\ngraph TD\n A-->B\n```",
            cacheNamespace: "rich"
        )
        #expect(blocks.count == 2)
        guard case .math(_, let latex, let display) = blocks[0] else {
            Issue.record("Expected display math block")
            return
        }
        #expect(latex == "x^2 + y^2")
        #expect(display)
        guard case .mermaid(_, let diagram, let complete) = blocks[1] else {
            Issue.record("Expected Mermaid block")
            return
        }
        #expect(diagram.contains("graph TD"))
        #expect(complete)
    }

    @Test func canonicalTurnPlanBecomesAStableImplementationCard() throws {
        let turnID: TurnID = "turn"
        let threadID: ThreadID = "thread"
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            plan: [
                .init(step: "Inspect", status: .completed),
                .init(step: "Implement", status: .inProgress)
            ],
            planExplanation: "Proposed plan"
        )
        let thread = CanonicalThread(
            id: threadID,
            status: .active(flags: []),
            turnOrder: [turnID],
            history: .init(mode: .legacy, turnsCoverage: .full)
        )
        let snapshot = CanonicalStateSnapshot(
            revision: .init(1),
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: [turn.key: turn]
        )
        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let card = try #require(projected.structuredCards.first)
        #expect(card.id == "plan:turn")
        #expect(card.title == "Proposed plan")
        #expect(card.steps.map(\.status) == [.completed, .inProgress])
        #expect(projected.narrative.contains { entry in
            if case .structuredCard = entry { return true }
            return false
        })
    }

    @Test func MCPDetailsUseTypedContentSummariesInsteadOfRawJSON() {
        let blocks: [CodexMCPContentBlockV2] = [
            .text("The answer"),
            .resource(uri: "docs://guide", mimeType: "text/plain", text: "Read this"),
            .widget(id: "chart", uri: "ui://chart", payload: ["series": .array([])])
        ]
        let summary = CodexMCPContentPresentationV2.summary(blocks)
        #expect(summary?.contains("The answer") == true)
        #expect(summary?.contains("docs://guide") == true)
        #expect(summary?.contains("Interactive widget") == true)
        #expect(summary?.contains("series") == false)
        #expect(CodexMCPContentPresentationV2.toolDetail(arguments: .dictionary(["secret": .string("value")]), blocks: blocks)?.contains("Arguments supplied") == true)
    }

    @Test func memoryCitationsProjectAsSelectableFileReferenceChips() async throws {
        let citation = CodexMemoryCitationV2(
            path: "docs/README.md",
            lineStart: 12,
            lineEnd: 14,
            note: "Project guide"
        )
        let turn = CodexTurnV2(
            id: "turn",
            finalAnswer: .init(id: "answer", text: "See the guide", isStreaming: false, memoryCitations: [citation]),
            status: .done(durationMs: 1)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])),
            availableWidth: 860,
            theme: .init(.officialDark, colorScheme: .dark)
        )
        let chips = try #require(snapshot.itemsByID.values.first { $0.id.rawValue.contains("memory-citations") })
        #expect(chips.agentChips.first?.label == "docs/README.md:12")
        #expect(chips.agentChips.first?.attachmentKind == .file)
        #expect(chips.copyText?.contains("docs/README.md:12-14") == true)
        #expect(chips.accessibilityLabel.contains("Memory citations"))
    }
}
