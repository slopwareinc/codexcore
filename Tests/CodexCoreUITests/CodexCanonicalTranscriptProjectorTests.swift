@testable import CodexCore
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

    @Test func pendingSubmissionHidesServerPlaceholderAboveOptimisticUser() throws {
        let threadID: ThreadID = "thread"
        let serverTurnID: TurnID = "server-turn"
        let intent = SubmissionIntent(
            id: "client-message",
            threadID: threadID,
            input: [.string("hello")],
            localOrdinal: 0
        )
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(
                serverTurnID,
                threadID: threadID,
                status: .inProgress,
                revision: 2
            )],
            items: [],
            intents: [intent.id: intent]
        )

        let turns = CodexCanonicalTranscriptProjector()
            .rebuild(snapshot: snapshot, threadID: threadID)
            .presentation.transcript.turns

        #expect(turns.count == 1)
        #expect(turns.first?.id == "local-client-message")
        #expect(turns.first?.userMessage?.text == "hello")
    }

    @Test func realtimeDelegationEnvelopeIsNeverRenderedAsUserContent() throws {
        let threadID: ThreadID = "thread"
        let handoffTurnID: TurnID = "handoff"
        let responseTurnID: TurnID = "response"
        let rawEnvelope = """
        <realtime_delegation>
        <source>transcript_tail_flush</source>
        <input>The user just ended their realtime session.</input>
        <transcript_delta>user: Hello
        assistant: Hi there.</transcript_delta>
        </realtime_delegation>
        """
        let handoff = item(threadID, handoffTurnID, "handoff-user", .userMessage, [
            "content": .array([.dictionary(["type": .string("text"), "text": .string(rawEnvelope)])])
        ])
        let responseUser = item(threadID, responseTurnID, "response-user", .userMessage, [
            "content": .array([.dictionary(["type": .string("text"), "text": .string(rawEnvelope)])])
        ])
        let response = item(threadID, responseTurnID, "response", .agentMessage, [
            "phase": .string("final_answer"),
            "text": .string("I’ll check that.")
        ])
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [
                turn(handoffTurnID, threadID: threadID, itemIDs: ["handoff-user"], revision: 2),
                turn(responseTurnID, threadID: threadID, itemIDs: ["response-user", "response"], revision: 3),
            ],
            items: [handoff, responseUser, response]
        )

        let transcript = CodexCanonicalTranscriptProjector()
            .rebuild(snapshot: snapshot, threadID: threadID)
            .presentation.transcript

        #expect(transcript.turns.allSatisfy { $0.userMessage == nil })
        let visibleTurn = try #require(transcript.turns.first { $0.finalAnswer != nil })
        #expect(visibleTurn.id == responseTurnID.rawValue)
        #expect(visibleTurn.userMessage == nil)
        #expect(visibleTurn.finalAnswer?.text == "I’ll check that.")
    }

    @Test func codexDelegationProjectsVisibleInputAndSourceTaskProvenance() throws {
        let threadID: ThreadID = "target"
        let turnID: TurnID = "turn"
        let envelope = CodexThreadDelegationEnvelope(
            sourceThreadID: "source",
            input: "Please report the current status."
        ).encodedText
        let user = item(threadID, turnID, "user", .userMessage, [
            "content": .array([.dictionary(["type": .string("text"), "text": .string(envelope)])])
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["user"], revision: 1)],
            items: [user]
        )

        let message = try #require(CodexCanonicalTranscriptProjector()
            .rebuild(snapshot: snapshot, threadID: threadID)
            .presentation.transcript.turns.first?.userMessage)

        #expect(message.text == "Please report the current status.")
        #expect(message.rawText == envelope)
        #expect(message.delegationSource == .init(hostID: "local", threadID: "source"))
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

    @Test func commandExecutionProjectsEverySemanticActionWithStableOfficialIDs() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let command = item(threadID, turnID, "exec-multi", .commandExecution, [
            "command": .string("sed App.swift && sed Model.swift && rg liveTail Sources"),
            "status": .string("completed"),
            "exitCode": .int(0),
            "aggregatedOutput": .string("matches"),
            "commandActions": .array([
                .dictionary([
                    "type": .string("read"),
                    "command": .string("sed App.swift"),
                    "name": .string("App.swift"),
                    "path": .string("App.swift"),
                ]),
                .dictionary([
                    "type": .string("read"),
                    "command": .string("sed Model.swift"),
                    "name": .string("Model.swift"),
                    "path": .string("Model.swift"),
                ]),
                .dictionary([
                    "type": .string("search"),
                    "command": .string("rg liveTail Sources"),
                    "query": .string("liveTail"),
                    "path": .string("Sources"),
                ]),
            ]),
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["exec-multi"],
                revision: 1
            )],
            items: [command]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let rows = projected.narrative.flatMap(\.workRows)
        #expect(rows.map(\.id) == ["exec-multi:0", "exec-multi:1", "exec-multi:2"])

        let commands = rows.compactMap { row -> CodexCommandRowV2? in
            guard case .command(let command) = row else { return nil }
            return command
        }
        #expect(commands.map(\.command) == [
            "sed App.swift",
            "sed Model.swift",
            "rg liveTail Sources",
        ])
        #expect(commands.map(\.label) == [
            "Read App.swift",
            "Read Model.swift",
            "Searched for liveTail in Sources",
        ])
        #expect(commands.map(\.action) == [.read, .read, .search])
        #expect(commands.allSatisfy { $0.output == "matches" })
        #expect(projected.narrative.compactMap(\.workGroup).first?.header == "Read files")
    }

    @Test func declinedAndUnknownItemStatusesRemainNonSuccess() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let declined = item(threadID, turnID, "declined", .commandExecution, [
            "command": .string("apply patch"),
            "status": .string("declined"),
        ])
        let unknown = item(threadID, turnID, "unknown", .mcpToolCall, [
            "server": .string("future-server"),
            "tool": .string("future-tool"),
            "status": .string("awaitingPolicy"),
            "readOnlyHint": .bool(true),
        ])
        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(
                snapshot: state(
                    revision: 1,
                    threadID: threadID,
                    turns: [turn(
                        turnID,
                        threadID: threadID,
                        itemIDs: ["declined", "unknown"],
                        revision: 1
                    )],
                    items: [declined, unknown]
                ),
                threadID: threadID
            ).presentation.transcript.turns.first
        )
        let rows = projected.narrative.flatMap(\.workRows)

        #expect(rows.count == 2)
        if case .command(let command) = rows[0] {
            #expect(command.status == .declined)
        } else {
            Issue.record("Expected declined command row")
        }
        if case .mcpToolCall(let tool) = rows[1] {
            #expect(tool.status == .unknown("awaitingPolicy"))
            #expect(tool.readOnlyHint == true)
        } else {
            Issue.record("Expected unknown MCP row")
        }
        #expect(CodexWorkGroupPresentationV2.status(rows: [rows[0]], isLive: false) == .declined)
        #expect(
            CodexWorkGroupPresentationV2.status(rows: [rows[1]], isLive: false)
                == .unknown("awaitingPolicy")
        )
    }

    @Test func liveOrRunningWorkOutranksDeclinedAndUnknownSiblings() {
        let declined = CodexWorkRowV2.other(.init(
            id: "declined",
            label: "Declined",
            status: .declined
        ))
        let unknown = CodexWorkRowV2.other(.init(
            id: "unknown",
            label: "Unknown",
            status: .unknown("awaitingPolicy")
        ))
        let running = CodexWorkRowV2.other(.init(
            id: "running",
            label: "Running",
            status: .inProgress
        ))

        #expect(
            CodexWorkGroupPresentationV2.status(
                rows: [declined, unknown, running],
                isLive: false
            ) == .inProgress
        )
        #expect(
            CodexWorkGroupPresentationV2.status(
                rows: [declined, unknown],
                isLive: true
            ) == .inProgress
        )
    }

    @Test func skillReadsBecomeLoadedToolsAndUnknownCommandsUseFallback() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let skill = item(threadID, turnID, "skill", .commandExecution, [
            "command": .string("cat /plugins/github/skills/github/SKILL.md"),
            "status": .string("completed"),
            "commandActions": .array([.dictionary([
                "type": .string("read"),
                "command": .string("cat /plugins/github/skills/github/SKILL.md"),
                "name": .string("SKILL.md"),
                "path": .string("/plugins/github/skills/github/SKILL.md"),
            ])]),
        ])
        let fallback = item(threadID, turnID, "fallback", .commandExecution, [
            "command": .string("swift test"),
            "status": .string("completed"),
            "commandActions": .array([]),
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["skill", "fallback"],
                revision: 1
            )],
            items: [skill, fallback]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let commands = projected.narrative.flatMap(\.workRows).compactMap { row -> CodexCommandRowV2? in
            guard case .command(let command) = row else { return nil }
            return command
        }
        #expect(commands.map(\.action) == [.loadedTool, .run])
        #expect(commands.map(\.label) == ["Read GitHub skill", "Ran swift test"])
        #expect(projected.narrative.compactMap(\.workGroup).first?.header == "Loaded a tool, ran a command")
    }

    @Test func modelReasoningSummaryIsTheOnlySeparateLiveTail() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let reasoning = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "reasoning"),
            kind: .reasoning,
            payload: [:],
            authority: .started,
            liveOverlay: .init(reasoningSummary: [
                0: .init(chunks: ["**Evaluating uncommitted partial modifications**"]),
            ]),
            lastChangedRevision: StateRevision(2)
        )
        let command = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "command"),
            kind: .commandExecution,
            payload: [
                "command": .string("swift test"),
                "status": .string("inProgress"),
                "commandActions": .array([.dictionary([
                    "type": .string("unknown"),
                    "command": .string("swift test"),
                ])]),
            ],
            authority: .started,
            lastChangedRevision: StateRevision(2)
        )
        let liveTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: ["reasoning", "command"],
            itemsCoverage: .full,
            lastChangedRevision: StateRevision(2)
        )
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [liveTurn],
            items: [reasoning, command]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        #expect(projected.liveTail == "**Evaluating uncommitted partial modifications**")

        let withoutReasoning = state(
            revision: 3,
            threadID: threadID,
            turns: [.init(
                key: liveTurn.key,
                status: .inProgress,
                itemOrder: ["command"],
                itemsCoverage: .full,
                lastChangedRevision: StateRevision(3)
            )],
            items: [command]
        )
        let commandOnly = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: withoutReasoning, threadID: threadID)
                .presentation.transcript.turns.first
        )
        #expect(commandOnly.liveTail == nil)
    }

    @Test func imageViewProjectsAsExpandableInlineImageActivity() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let image = item(threadID, turnID, "view", .imageView, [
            "path": .string("/tmp/reference.png")
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["view"], revision: 1)],
            items: [image]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let activity = try #require(projected.narrative.compactMap { entry -> CodexInlineActivityV2? in
            guard case .inlineActivity(let activity) = entry else { return nil }
            return activity
        }.first)

        #expect(activity.id == "view")
        #expect(activity.label == "Viewed an image")
        #expect(activity.systemImage == "photo.on.rectangle.angled")
        #expect(activity.imagePath == "/tmp/reference.png")
        #expect(activity.status == .completed)
    }

    @Test func completedImageGenerationProjectsPersistentTurnMedia() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let generation = item(threadID, turnID, "generation", .imageGeneration, [
            "status": .string("completed"),
            "savedPath": .string("/tmp/generated.png"),
            "result": .string("fallback-base64"),
            "revisedPrompt": .string("A precise native developer workspace"),
            "transparentBackground": .bool(true),
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["generation"], revision: 1)],
            items: [generation]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )

        #expect(projected.generatedImages == [
            .init(
                id: "generation",
                source: "/tmp/generated.png",
                revisedPrompt: "A precise native developer workspace",
                hasTransparentBackground: true
            )
        ])
        #expect(projected.narrative.flatMap(\.workRows).contains { $0.id == "generation" })
    }

    @Test func generatedImageFallsBackToResultPayloadWithoutSavedPath() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let generation = item(threadID, turnID, "generation", .imageGeneration, [
            "status": .string("completed"),
            "result": .string("data:image/png;base64,aW1hZ2U="),
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["generation"], revision: 1)],
            items: [generation]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )

        #expect(projected.generatedImages.first?.source == "data:image/png;base64,aW1hZ2U=")
    }

    @Test func imageGenerationUsageLimitProjectsPersistentFailureMetadata() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let generation = item(threadID, turnID, "generation", .imageGeneration, [
            "status": .string("failed"),
            "result": .string(""),
            "failure": .dictionary([
                "type": .string("usageLimitExceeded"),
                "limitId": .string("image_gen"),
                "resetsAt": .int(1_786_150_800),
            ]),
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["generation"], revision: 1)],
            items: [generation]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector()
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )

        let failure = try #require(projected.imageGenerationFailures.first)
        #expect(failure.type == "usageLimitExceeded")
        #expect(failure.limitID == "image_gen")
        #expect(failure.resetsAt == Date(timeIntervalSince1970: 1_786_150_800))
        #expect(failure.message.contains("Image generation limit reached"))
        #expect(projected.generatedImages.isEmpty)
    }

    @Test func hostPolicyCoalescesSuccessiveItemsIntoOneSemanticActivity() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let commentary = item(threadID, turnID, "commentary", .agentMessage, [
            "phase": .string("commentary"),
            "text": .string("I’ll research the topic and shape the lessons.")
        ])
        let begin = item(threadID, turnID, "begin", .dynamicToolCall, [
            "tool": .string("begin_research_activity")
        ])
        let update = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "update"),
            kind: .dynamicToolCall,
            payload: [
                "tool": .string("update_research_activity"),
                "arguments": .dictionary(["lessonCount": .int(3)])
            ],
            authority: .started,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(3)
        )
        let canonicalTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: ["commentary", "begin", "update"],
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(3)
        )
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [canonicalTurn],
            items: [commentary, begin, update]
        )
        let policy = CodexTranscriptItemPresentationPolicyV2 { context in
            guard context.kind == .dynamicToolCall else { return .standard }
            let tool: String? = {
                guard let value = context.payload["tool"],
                      case .string(let tool) = value else { return nil }
                return tool
            }()
            let label = tool == "begin_research_activity"
                ? "Researching the musical building blocks"
                : "Drafting 3 lessons"
            return .inlineActivity(.init(
                id: "lesson-authoring",
                label: label,
                systemImage: "book.pages",
                status: context.status
            ))
        }

        let projected = try #require(
            CodexCanonicalTranscriptProjector(itemPresentationPolicy: policy)
                .rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        #expect(projected.narrative.contains { $0.id == "commentary" })
        #expect(!projected.narrative.contains { $0.id == "begin" || $0.id == "update" })
        let activities = projected.narrative.compactMap { entry -> CodexInlineActivityV2? in
            guard case .inlineActivity(let activity) = entry else { return nil }
            return activity
        }
        #expect(activities == [
            CodexInlineActivityV2(
                id: "lesson-authoring",
                label: "Drafting 3 lessons",
                systemImage: "book.pages",
                status: .inProgress
            )
        ])
        #expect(projected.liveTail == nil)
    }

    @Test func hostPolicyCanHideItemsAndStandardDecisionPreservesFallbackProjection() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let tool = item(threadID, turnID, "tool", .dynamicToolCall, [
            "namespace": .string("product"),
            "tool": .string("offer_choices")
        ])
        let snapshot = state(
            revision: 1,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["tool"], revision: 1)],
            items: [tool]
        )
        let baseline = CodexCanonicalTranscriptProjector()
            .rebuild(snapshot: snapshot, threadID: threadID)
            .presentation.transcript
        let standard = CodexCanonicalTranscriptProjector(
            itemPresentationPolicy: .init { _ in .standard }
        )
        .rebuild(snapshot: snapshot, threadID: threadID)
        .presentation.transcript
        let hidden = CodexCanonicalTranscriptProjector(
            itemPresentationPolicy: .init { _ in .hidden }
        )
        .rebuild(snapshot: snapshot, threadID: threadID)
        .presentation.transcript

        #expect(standard == baseline)
        #expect(baseline.turns.first?.narrative.map(\.id) == ["tool"])
        #expect(hidden.turns.first?.narrative.isEmpty == true)
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

    @Test func hydratedMessageTimesComeFromServerTurnBoundaries() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let user = item(threadID, turnID, "user", .userMessage, [
            "content": CodexJSONValue.array([
                CodexJSONValue.dictionary([
                    "type": CodexJSONValue.string("text"),
                    "text": CodexJSONValue.string("Question")
                ])
            ])
        ])
        let answer = item(threadID, turnID, "answer", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("Answer")
        ])
        let canonicalTurn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID),
            status: .completed,
            startedAt: ProtocolSeconds(100),
            completedAt: ProtocolSeconds(200),
            itemOrder: [user.key.itemID, answer.key.itemID],
            itemsCoverage: .full,
            itemsConsistency: .authoritative
        )

        let transcript = CodexCanonicalTranscriptProjector().rebuild(
            snapshot: state(
                revision: 1,
                threadID: threadID,
                turns: [canonicalTurn],
                items: [user, answer]
            ),
            threadID: threadID
        ).presentation.transcript
        let projected = try #require(transcript.turns.first)

        #expect(projected.userMessage?.sentAt == Date(timeIntervalSince1970: 100))
        #expect(projected.finalAnswer?.sentAt == Date(timeIntervalSince1970: 200))
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
            "status": .string("completed"),
            "receiverThreadIds": .array(agentIDs.map(CodexJSONValue.string)),
            "agentsStates": .dictionary(Dictionary(uniqueKeysWithValues: agentIDs.map {
                ($0, .dictionary(["status": .string("running")]))
            })),
        ]))
        let snapshot = state(
            revision: 8,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                status: .inProgress,
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
        #expect(agents.allSatisfy {
            $0.action == .started
                && $0.status == .completed
                && $0.displayStatus == .done
        })
        #expect(Set(agents.flatMap(\.agentNames)) == Set(names))
    }

    @Test func receiverlessTerminalWaitReconcilesAgentsWithoutRenderingASecondGroup() throws {
        let threadID: ThreadID = "parent"
        let turnID: TurnID = "turn"
        let agentIDs = ["child-1", "child-2", "child-3"]
        let names = ["Poincare", "Ampere", "Leibniz"]
        var items = zip(agentIDs, names).enumerated().map { index, pair in
            item(threadID, turnID, ItemID("started-\(index)"), .subAgentActivity, [
                "kind": .string("started"),
                "agentThreadId": .string(pair.0),
                "agentPath": .string("/root/\(pair.1.lowercased())"),
            ])
        }
        items.append(item(threadID, turnID, "wait", .collabAgentToolCall, [
            "tool": .string("wait"),
            "status": .string("completed"),
            "receiverThreadIds": .array([]),
            "agentsStates": .dictionary([:]),
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
        let groups = projected.narrative.compactMap(\.workGroup)
        let agents = groups.flatMap(\.rows).compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let agent) = row else { return nil }
            return agent
        }

        #expect(groups.count == 1)
        #expect(agents.count == 3)
        #expect(Set(agents.flatMap(\.agentThreadIDs)) == Set(agentIDs))
        #expect(Set(agents.flatMap(\.agentNames)) == Set(names))
        #expect(agents.allSatisfy {
            $0.action == .started
                && $0.status == .completed
                && $0.displayStatus == .done
        })
    }

    @Test func completedV2ActivitySignalStaysWorkingWhileParentTurnIsLive() throws {
        let threadID: ThreadID = "parent"
        let turnID: TurnID = "turn"
        let activity = item(threadID, turnID, "started", .subAgentActivity, [
            "kind": .string("started"),
            "agentThreadId": .string("child"),
            "agentPath": .string("/root/curie"),
        ])
        let snapshot = state(
            revision: 8,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                status: .inProgress,
                itemIDs: [activity.key.itemID],
                revision: 8
            )],
            items: [activity]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(
                snapshot: snapshot,
                threadID: threadID
            ).presentation.transcript.turns.first
        )
        let agent = try #require(projected.narrative.flatMap(\.workRows).compactMap {
            row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let agent) = row else { return nil }
            return agent
        }.first)

        #expect(agent.action == .started)
        #expect(agent.status == .inProgress)
        #expect(agent.displayStatus == .working)
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
        status: CanonicalTurnStatus = .completed,
        itemIDs: [ItemID] = [],
        extensions: [String: CodexJSONValue] = [:],
        revision: UInt64
    ) -> CanonicalTurn {
        .init(
            key: .init(threadID: threadID, turnID: id),
            status: status,
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

    var workGroup: CodexWorkGroupV2? {
        if case .workGroup(let group) = self { group } else { nil }
    }
}
