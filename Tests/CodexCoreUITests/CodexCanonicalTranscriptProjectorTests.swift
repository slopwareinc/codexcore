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
        } else {
            Issue.record("Expected unknown MCP row")
        }
        #expect(CodexWorkGroupPresentationV2.status(rows: [rows[0]], isLive: false) == .declined)
        #expect(
            CodexWorkGroupPresentationV2.status(rows: [rows[1]], isLive: false)
                == .unknown("awaitingPolicy")
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
                revisedPrompt: "A precise native developer workspace"
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

    @Test func canonicalFileChangesPreserveEveryPatchAndMetadataInOneStableRow() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let fileChange = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                fileUpdate(
                    path: "Sources/Added.swift",
                    kind: "add",
                    diff: "@@ -0,0 +1 @@\n+let added = true"
                ),
                fileUpdate(
                    path: "Sources/Modified.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-let value = 1\n+let value = 2"
                ),
                fileUpdate(
                    path: "Sources/Deleted.swift",
                    kind: "delete",
                    diff: "@@ -1 +0,0 @@\n-let deleted = true"
                ),
                fileUpdate(
                    path: "Sources/OldName.swift",
                    kind: "update",
                    movePath: "Sources/NewName.swift",
                    diff: "@@ -1 +1 @@\n-let name = \"old\"\n+let name = \"new\""
                ),
            ]),
        ])
        let snapshot = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 4)],
            items: [fileChange]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let rows = projected.narrative.flatMap(\.workRows)
        let row = try #require(rows.compactMap(\.fileChange).first)

        #expect(rows.count == 1)
        #expect(row.id == "patch")
        #expect(Set(row.changes.map(\.id)).count == 4)
        #expect(row.changes.allSatisfy { $0.id.hasPrefix("patch:file:") })
        #expect(row.changes.map(\.path) == [
            "Sources/Added.swift",
            "Sources/Modified.swift",
            "Sources/Deleted.swift",
            "Sources/OldName.swift",
        ])
        #expect(row.changes.map(\.kind) == [.added, .modified, .deleted, .renamed])
        #expect(row.changes.map(\.destinationPath) == [
            nil,
            nil,
            nil,
            "Sources/NewName.swift",
        ])
        #expect(row.changes.map(\.diff) == [
            "@@ -0,0 +1 @@\n+let added = true",
            "@@ -1 +1 @@\n-let value = 1\n+let value = 2",
            "@@ -1 +0,0 @@\n-let deleted = true",
            "@@ -1 +1 @@\n-let name = \"old\"\n+let name = \"new\"",
        ])
        #expect(row.status == .completed)
        #expect(row.files == [
            "Sources/Added.swift",
            "Sources/Modified.swift",
            "Sources/Deleted.swift",
            "Sources/NewName.swift",
        ])
    }

    @Test func liveFilePatchAndHydratedHistoryProjectIdenticallyInTheirTurn() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let changes: [CodexJSONValue] = [
            fileUpdate(
                path: "Sources/Live.swift",
                kind: "update",
                diff: "@@ -1 +1 @@\n-let live = false\n+let live = true"
            ),
            fileUpdate(
                path: "Tests/LiveTests.swift",
                kind: "add",
                diff: "@@ -0,0 +1 @@\n+#expect(live)"
            ),
        ]
        let liveItem = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "patch"),
            kind: .fileChange,
            payload: ["status": .string("inProgress"), "changes": .array([])],
            authority: .started,
            liveFields: ["fileChanges": .array(changes)],
            consistency: .partial,
            lastChangedRevision: StateRevision(4)
        )
        let historyItem = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array(changes),
        ], revision: 40)
        let live = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 4)],
            items: [liveItem]
        )
        let history = state(
            revision: 40,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 40)],
            items: [historyItem]
        )
        let projector = CodexCanonicalTranscriptProjector()

        let liveTranscript = projector.rebuild(snapshot: live, threadID: threadID)
            .presentation.transcript
        let historyTranscript = projector.rebuild(snapshot: history, threadID: threadID)
            .presentation.transcript

        #expect(liveTranscript == historyTranscript)
        #expect(liveTranscript.turns.map(\.id) == [turnID.rawValue])
        let row = try #require(
            liveTranscript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )
        #expect(row.changes.map(\.path) == ["Sources/Live.swift", "Tests/LiveTests.swift"])
    }

    @Test func malformedFileChangeEntriesDoNotDropValidSiblings() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let fileChange = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                .string("not an object"),
                .dictionary([
                    "kind": .dictionary(["type": .string("delete")]),
                    "diff": .string("-missing path"),
                ]),
                .dictionary([
                    "path": .string("Sources/Partial.swift"),
                    "kind": .bool(true),
                    "diff": .int(7),
                ]),
                fileUpdate(
                    path: "Sources/Valid.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-let valid = false\n+let valid = true"
                ),
            ]),
        ])
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 2)],
            items: [fileChange]
        )

        let row = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        #expect(row.changes.map(\.path) == ["Sources/Partial.swift", "Sources/Valid.swift"])
        #expect(row.changes.map(\.kind) == [.unknown("unknown"), .modified])
        #expect(row.changes.map(\.diff) == [
            "",
            "@@ -1 +1 @@\n-let valid = false\n+let valid = true",
        ])
        #expect(row.preparedChanges.map(\.isMalformed) == [true, false])
    }

    @Test func nullMovePathAndEmptyDiffAreValidButMissingDiffIsMalformed() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 2)],
            items: [item(threadID, turnID, "patch", .fileChange, [
                "status": .string("inProgress"),
                "changes": .array([
                    .dictionary([
                        "path": .string("Sources/Empty.swift"),
                        "kind": .dictionary([
                            "type": .string("update"),
                            "move_path": .null,
                        ]),
                        "diff": .string(""),
                    ]),
                    .dictionary([
                        "path": .string("Sources/Missing.swift"),
                        "kind": .dictionary(["type": .string("update")]),
                    ]),
                ]),
            ], revision: 2)]
        )

        let row = try #require(
            CodexCanonicalTranscriptProjector().rebuild(
                snapshot: snapshot,
                threadID: threadID
            ).presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )
        #expect(row.status == .inProgress)
        #expect(row.changes.map(\.kind) == [.modified, .modified])
        #expect(row.changes.map(\.destinationPath) == [nil, nil])
        #expect(row.preparedChanges.map(\.isMalformed) == [false, true])
    }

    @Test func representativeLargeFilePatchIsPreparedOnceDuringProjection() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let lineCount = 5_000
        let body = (0..<lineCount).flatMap { index in
            ["-let value\(index) = false", "+let value\(index) = true"]
        }.joined(separator: "\n")
        let diff = "@@ -1,\(lineCount) +1,\(lineCount) @@\n\(body)"
        let fileChange = item(threadID, turnID, "large-patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                fileUpdate(path: "Sources/Large.swift", kind: "update", diff: diff),
            ]),
        ])
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["large-patch"], revision: 3)],
            items: [fileChange]
        )

        let row = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )
        let prepared = try #require(row.preparedChanges.first?.file)

        #expect(row.changes.first?.diff == diff)
        #expect(row.preparedChanges.count == 1)
        #expect(prepared.path == "Sources/Large.swift")
        #expect(prepared.added == lineCount)
        #expect(prepared.removed == lineCount)
        #expect(
            row.retainedPreparedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(row.preparedChanges.first?.isTruncated == true)
        #expect(row.preparedChanges.first?.displayPatch.contains("more lines") == true)
    }

    @Test func officialKindDependentFilePayloadsNormalizeOnceWithExactStats() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let addedContent = "let first = true\n\nlet second = true\n"
        let deletedContent = "old\n--value\n"
        let updateDiff = "@@ -1 +1 @@\n---value\n+++counter"
        let changes: [CodexJSONValue] = [
            fileUpdate(path: "Sources/Added.swift", kind: "add", diff: addedContent),
            fileUpdate(path: "Sources/Deleted.swift", kind: "delete", diff: deletedContent),
            fileUpdate(path: "Sources/Counter.swift", kind: "update", diff: updateDiff),
            fileUpdate(
                path: "Sources/Old.swift",
                kind: "update",
                movePath: "Sources/New.swift",
                diff: ""
            ),
        ]
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 3)],
            items: [item(threadID, turnID, "patch", .fileChange, [
                "status": .string("completed"),
                "changes": .array(changes),
            ], revision: 3)]
        )

        let row = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        #expect(row.changes.map(\.diff) == [
            addedContent,
            deletedContent,
            updateDiff,
            "",
        ])
        #expect(row.preparedChanges.map(\.added) == [3, 0, 1, 0])
        #expect(row.preparedChanges.map(\.removed) == [0, 2, 1, 0])
        #expect(row.preparedChanges[0].displayPatch.contains("new file mode 100644"))
        #expect(row.preparedChanges[0].displayPatch.contains("+let first = true"))
        #expect(row.preparedChanges[1].displayPatch.contains("deleted file mode 100644"))
        #expect(row.preparedChanges[1].displayLines.contains {
            $0.kind == .remove && $0.text == "---value"
        })
        #expect(row.preparedChanges[2].displayPatch.contains("--- a/Sources/Counter.swift"))
        #expect(row.preparedChanges[2].displayLines.contains {
            $0.kind == .add && $0.text == "+++counter"
        })
        #expect(row.preparedChanges[3].displayPatch.contains("rename from Sources/Old.swift"))
        #expect(row.preparedChanges[3].displayPatch.contains("rename to Sources/New.swift"))
        #expect(row.hasPreparedDetail)
    }

    @Test func statusOnlyFileRevisionReusesPreparationAndContentRevisionInvalidates() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let probe = FilePreparationProbe()
        let production = CodexFileChangeDiffPreparer()
        let projector = CodexCanonicalTranscriptProjector(
            fileChangeDiffPreparer: .init { changes, legacyDiff, maximumBytes in
                probe.record()
                return production.prepare(
                    changes: changes,
                    legacyDiff: legacyDiff,
                    maximumRetainedUTF8Bytes: maximumBytes
                )
            }
        )
        let firstFile = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                fileUpdate(
                    path: "Sources/Stable.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-old\n+new"
                ),
            ]),
        ], revision: 3)
        let first = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 3
            )],
            items: [
                firstFile,
                item(threadID, turnID, "message", .agentMessage, [
                    "phase": .string("commentary"),
                    "text": .string("one"),
                ], revision: 3),
            ]
        )
        let firstResult = projector.rebuild(snapshot: first, threadID: threadID)
        let firstRow = try #require(
            firstResult.presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        let statusOnlyFileRevision = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": firstFile.payload["changes"] ?? .array([]),
        ], revision: 4, fileChangeContentRevision: 3)
        let siblingChanged = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 4
            )],
            items: [
                statusOnlyFileRevision,
                item(threadID, turnID, "message", .agentMessage, [
                    "phase": .string("commentary"),
                    "text": .string("two"),
                ], revision: 4),
            ]
        )
        let secondResult = try projector.project(
            snapshot: siblingChanged,
            threadID: threadID,
            previous: firstResult.presentation
        )
        let secondRow = try #require(
            secondResult.presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        #expect(probe.count == 1)
        #expect(firstRow.preparedFileChanges === secondRow.preparedFileChanges)

        let contentChanged = item(
            threadID,
            turnID,
            "patch",
            .fileChange,
            [
                "status": .string("completed"),
                "changes": .array([
                    fileUpdate(
                        path: "Sources/Stable.swift",
                        kind: "update",
                        diff: "@@ -1 +1 @@\n-old\n+newer"
                    ),
                ]),
            ],
            revision: 5,
            fileChangeContentRevision: 5
        )
        let third = state(
            revision: 5,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 5
            )],
            items: [
                contentChanged,
                siblingChanged.items[.init(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: "message"
                )]!,
            ]
        )
        let thirdResult = try projector.project(
            snapshot: third,
            threadID: threadID,
            previous: secondResult.presentation
        )
        let thirdRow = try #require(
            thirdResult.presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        #expect(probe.count == 2)
        #expect(thirdRow.preparedFileChanges !== secondRow.preparedFileChanges)
    }

    @Test func duplicatePathIDsRemainUniqueAndFollowContentAcrossReordering() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let firstDiff = "@@ -1 +1 @@\n-a\n+b"
        let secondDiff = "@@ -1 +1 @@\n-c\n+d"
        func snapshot(_ diffs: [String], revision: UInt64) -> CanonicalStateSnapshot {
            state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array(diffs.map {
                        fileUpdate(path: "Sources/Same.swift", kind: "update", diff: $0)
                    }),
                ], revision: revision)]
            )
        }
        func IDsByDiff(_ snapshot: CanonicalStateSnapshot) throws -> [String: String] {
            let row = try #require(
                CodexCanonicalTranscriptProjector().rebuild(
                    snapshot: snapshot,
                    threadID: threadID
                ).presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                    .compactMap(\.fileChange).first
            )
            #expect(Set(row.changes.map(\.id)).count == row.changes.count)
            return Dictionary(uniqueKeysWithValues: row.changes.map { ($0.diff, $0.id) })
        }

        let original = try IDsByDiff(snapshot([firstDiff, secondDiff], revision: 2))
        let reordered = try IDsByDiff(snapshot([secondDiff, firstDiff], revision: 3))

        #expect(original == reordered)
    }

    @Test func fileChangeIDSurvivesSingletonToDuplicateTransition() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let originalDiff = "@@ -1 +1 @@\n-a\n+b"
        let siblingDiff = "@@ -1 +1 @@\n-c\n+d"
        func row(_ diffs: [String], revision: UInt64) throws -> CodexFileChangeRowV2 {
            let snapshot = state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array(diffs.map {
                        fileUpdate(path: "Sources/Same.swift", kind: "update", diff: $0)
                    }),
                ], revision: revision)]
            )
            return try #require(
                CodexCanonicalTranscriptProjector().rebuild(
                    snapshot: snapshot,
                    threadID: threadID
                ).presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                    .compactMap(\.fileChange).first
            )
        }

        let singleton = try row([originalDiff], revision: 2)
        let duplicate = try row([originalDiff, siblingDiff], revision: 3)
        #expect(
            singleton.changes.first?.id
                == duplicate.changes.first { $0.diff == originalDiff }?.id
        )
    }

    @Test func fileChangeIDSurvivesIncrementalPatchEvolution() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        func snapshot(diff: String, revision: UInt64) -> CanonicalStateSnapshot {
            state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array([
                        fileUpdate(
                            path: "Sources/Evolving.swift",
                            kind: "update",
                            diff: diff
                        ),
                    ]),
                ], revision: revision)]
            )
        }

        let projector = CodexCanonicalTranscriptProjector()
        let first = projector.rebuild(
            snapshot: snapshot(diff: "@@ -1 +1 @@\n-old\n+new", revision: 2),
            threadID: threadID
        )
        let firstID = try #require(
            first.presentation.transcript.turns.first?.narrative
                .flatMap(\.workRows)
                .compactMap(\.fileChange)
                .first?
                .changes
                .first?
                .id
        )
        let evolved = try projector.project(
            snapshot: snapshot(diff: "@@ -1 +1 @@\n-old\n+newer", revision: 3),
            threadID: threadID,
            previous: first.presentation
        )
        let evolvedID = try #require(
            evolved.presentation.transcript.turns.first?.narrative
                .flatMap(\.workRows)
                .compactMap(\.fileChange)
                .first?
                .changes
                .first?
                .id
        )

        #expect(evolvedID == firstID)
    }

    @Test func publicFileChangeMutationCannotDivergePathsAndDerivedStateIsNotEquality() {
        var row = CodexFileChangeRowV2(
            id: "patch",
            changes: [.init(
                id: "change",
                path: "Sources/Old.swift",
                destinationPath: "Sources/New.swift",
                kind: .renamed,
                diff: ""
            )],
            status: .completed
        )
        #expect(row.files == ["Sources/New.swift"])
        #expect(row.preparedChanges.count == 1)

        row.files = ["Sources/SetThroughLegacyAPI.swift"]
        #expect(row.changes[0].destinationPath == "Sources/SetThroughLegacyAPI.swift")
        #expect(row.preparedChanges.first?.path == "Sources/SetThroughLegacyAPI.swift")

        row.files = ["one", "two"]
        #expect(row.changes.count == 1)
        #expect(row.files == ["Sources/SetThroughLegacyAPI.swift"])

        row.diff = "legacy aggregate must not diverge"
        #expect(row.diff == nil)

        row.changes[0].destinationPath = "Sources/Newer.swift"
        #expect(row.files == ["Sources/Newer.swift"])
        #expect(row.preparedChanges.first?.path == "Sources/Newer.swift")

        let alternatePreparation = CodexFileChangeDiffPreparer().prepare(
            changes: row.changes,
            legacyDiff: nil,
            maximumRetainedUTF8Bytes: 8
        )
        let semanticallyEqual = CodexFileChangeRowV2(
            id: row.id,
            changes: row.changes,
            status: row.status,
            durationMs: row.durationMs,
            preparationKey: .init(
                itemKey: nil,
                sourceRevision: nil,
                contentFingerprint: 999
            ),
            preparedFileChanges: alternatePreparation
        )
        #expect(row == semanticallyEqual)
    }

    @Test func malformedLivePatchAndAdapterCompletionKeepValidSibling() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let itemID: ItemID = "patch"
        let itemKey = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
        let malformedWire: CodexJSONValue = .dictionary([
            "path": .string("Sources/Future.swift"),
            "kind": .dictionary(["type": .string("update")]),
            "diff": .int(42),
            "futureField": .dictionary(["kept": .bool(true)]),
        ])
        let rawChanges: CodexJSONValue = .array([
            fileUpdate(
                path: "Sources/Valid.swift",
                kind: "update",
                diff: "@@ -1 +1 @@\n-old\n+new"
            ),
            malformedWire,
        ])
        let adaptation = try ProtocolStateAdapter().adaptNotification(
            method: .itemFileChangePatchUpdated,
            params: [
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string(itemID.rawValue),
                "changes": rawChanges,
            ]
        )
        var graph = CanonicalStateGraph()
        var reducer = CanonicalStateReducer()
        _ = reducer.apply(.threadUpsert(.init(
            id: threadID,
            status: .active(flags: []),
            turnOrder: [turnID],
            isLoaded: true
        )), to: &graph)
        _ = reducer.apply(.turnStarted(.init(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: [itemID]
        ), items: []), to: &graph)
        _ = reducer.apply(.itemStarted(.init(
            key: itemKey,
            kind: .fileChange,
            payload: ["status": .string("inProgress")],
            authority: .started
        )), to: &graph)
        _ = reducer.apply(adaptation.mutations, to: &graph)

        let projector = CodexCanonicalTranscriptProjector()
        let liveResult = projector.rebuild(snapshot: graph.snapshot(), threadID: threadID)
        let liveRow = try #require(
            liveResult.presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )
        let liveContentRevision = graph.items[itemKey]?.fileChangeContentRevision
        #expect(liveRow.changes.map(\.path) == [
            "Sources/Valid.swift",
            "Sources/Future.swift",
        ])
        #expect(graph.items[itemKey]?.liveFields["fileChanges"] == rawChanges)
        #expect(liveRow.preparedChanges.map(\.isMalformed) == [false, true])
        #expect(liveRow.changes[1].wireValue == malformedWire)

        let completion = try ProtocolStateAdapter().adaptNotification(
            method: .itemCompleted,
            params: [
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "completedAtMs": .int(10),
                "item": .dictionary([
                    "id": .string(itemID.rawValue),
                    "type": .string("fileChange"),
                    "status": .string("completed"),
                    "changes": rawChanges,
                ]),
            ]
        )
        _ = reducer.apply(completion.mutations, to: &graph)
        #expect(graph.items[itemKey]?.fileChangeContentRevision == liveContentRevision)
        let completedResult = try projector.project(
            snapshot: graph.snapshot(),
            threadID: threadID,
            previous: liveResult.presentation
        )
        let hydratedRow = try #require(
            completedResult.presentation.transcript.turns.first?.narrative.flatMap(\.workRows)
                .compactMap(\.fileChange).first
        )

        #expect(hydratedRow.changes.map(\.path) == liveRow.changes.map(\.path))
        #expect(hydratedRow.changes.map(\.diff) == liveRow.changes.map(\.diff))
        #expect(
            hydratedRow.preparedChanges.map(\.added)
                == liveRow.preparedChanges.map(\.added)
        )
        #expect(
            hydratedRow.preparedChanges.map(\.removed)
                == liveRow.preparedChanges.map(\.removed)
        )
        #expect(hydratedRow.preparedFileChanges === liveRow.preparedFileChanges)
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

    @Test func steerAppendsAUserMessageWithoutReplacingTheOriginalPrompt() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let original = item(threadID, turnID, "original", .userMessage, [
            "content": .array([.dictionary(["type": .string("text"), "text": .string("Original prompt")])])
        ])
        let commentary = item(threadID, turnID, "work", .agentMessage, [
            "phase": .string("commentary"), "text": .string("Working")
        ])
        let steered = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "steered"),
            kind: .userMessage,
            payload: [
                "content": .array([.dictionary(["type": .string("text"), "text": .string("New direction")])])
            ],
            authority: .completed,
            clientUserMessageID: "steer-client",
            consistency: .authoritative,
            lastChangedRevision: StateRevision(8)
        )
        let continued = item(threadID, turnID, "continued", .agentMessage, [
            "phase": .string("commentary"), "text": .string("Following the new direction")
        ])
        let answer = item(threadID, turnID, "answer", .agentMessage, [
            "phase": .string("final_answer"), "text": .string("Done")
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
            "content": .array([.dictionary(["type": .string("text"), "text": .string("Original prompt")])])
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
                "content": .array([.dictionary(["type": .string("text"), "text": .string("New direction")])])
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
        revision: UInt64 = 8,
        fileChangeContentRevision: UInt64? = nil
    ) -> CanonicalItem {
        .init(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: kind,
            payload: payload,
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(revision),
            fileChangeContentRevision: fileChangeContentRevision.map(StateRevision.init)
        )
    }

    func fileUpdate(
        path: String,
        kind: String,
        movePath: String? = nil,
        diff: String
    ) -> CodexJSONValue {
        var kindPayload: [String: CodexJSONValue] = ["type": .string(kind)]
        if let movePath {
            kindPayload["move_path"] = .string(movePath)
        }
        return .dictionary([
            "path": .string(path),
            "kind": .dictionary(kindPayload),
            "diff": .string(diff),
        ])
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

private extension CodexWorkRowV2 {
    var fileChange: CodexFileChangeRowV2? {
        if case .fileChange(let value) = self { value } else { nil }
    }
}

private final class FilePreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}
