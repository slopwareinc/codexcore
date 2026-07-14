@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexTranscriptV2Tests {
    @Test @MainActor func globalStreamOwnsTranscriptIngress() async throws {
        let runtime = CodexChatRuntimeSession()
        let global = AsyncStream.makeStream(of: CodexNotification.self)
        let scoped = AsyncStream.makeStream(of: CodexNotification.self)
        var scopedResultCount = 0
        let notifications = [
            notification("turn/started", [
                "threadId": .string("thread-1"),
                "turn": .dictionary(["id": .string("turn-1")])
            ]),
            notification("item/started", [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "item": .dictionary([
                    "type": .string("agentMessage"),
                    "id": .string("answer"),
                    "phase": .string("final_answer"),
                    "text": .string("")
                ])
            ]),
            notification("item/agentMessage/delta", [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("answer"),
                "delta": .string("WIRE")
            ])
        ]

        runtime.consumeGlobalNotificationStream(
            global.stream,
            store: nil,
            currentThreadID: { "thread-1" },
            applyResult: { _ in }
        )
        runtime.consumeMainTurnStream(
            id: "turn-1",
            notifications: scoped.stream,
            currentThreadID: { "thread-1" },
            store: { nil },
            applyResult: { _ in scopedResultCount += 1 }
        )

        for notification in notifications {
            global.continuation.yield(notification)
            scoped.continuation.yield(notification)
        }
        global.continuation.finish()
        scoped.continuation.finish()
        for _ in 0..<10 { await Task.yield() }

        #expect(try #require(runtime.transcriptV2.turns.first?.finalAnswer?.text) == "WIRE")
        #expect(scopedResultCount > 0)
    }

    @Test func repoInspectReplay() throws {
        let transcript = try replay("turn-repo-inspect")
        let turn = try #require(transcript.turns.first)
        #expect(turn.userMessage != nil)
        #expect(turn.narrative.filter(\.isProse).count == 5)
        #expect(turn.narrative.compactMap(\.header) == ["Listed files, ran 2 commands", "Read 4 files, ran a command", "Read 2 files and searched, ran 2 commands", "Ran 2 commands"])
        #expect(turn.liveTail == nil)
    }

    @Test func subagentsReplayFiltersChildren() throws {
        let transcript = try replay("turn-subagents"), turn = try #require(transcript.turns.first)
        #expect(transcript.turns.count == 1)
        #expect(turn.narrative.flatMap(\.rows).count == 6)
        #expect(turn.narrative.compactMap(\.header).contains("Created 2 agents"))
        #expect(turn.narrative.compactMap(\.header).contains("Closed 2 agents"))
        let agentRows = turn.narrative.flatMap(\.rows).compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let value) = row else { return nil }
            return value
        }
        #expect(agentRows.contains { !$0.agentThreadIDs.isEmpty })
        #expect(turn.narrative.contains(where: \.isProse) && turn.finalAnswer != nil)
    }

    @Test func liveCollabFixtureMatchesOfficialAgentGrammar() throws {
        let transcript = try replay(
            "turn-collab-live",
            threadID: "019f5207-0817-70f0-ab00-33810d6c8744"
        )
        #expect(transcript.turns.count == 1)
        let turn = try #require(transcript.turns.first)
        let groups = turn.narrative.compactMap(\.workGroup)
        let createdGroup = try #require(groups.first { $0.header == "Created 5 agents" })
        let createdRows = createdGroup.rows.compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let value) = row, value.action == .created else { return nil }
            return value
        }
        #expect(createdRows.count == 5)
        let createdLabels = createdRows.map { row in
            "Created \(row.agentNames.joined(separator: ", "))" +
                (row.instructions.map { " with the instructions: \($0)" } ?? "")
        }
        #expect(createdLabels.count == 5)
        #expect(createdLabels.allSatisfy { $0.hasPrefix("Created agent-019f") && $0.contains(" with the instructions: Count from ") })

        let waitRows = groups.flatMap(\.rows).compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let value) = row, value.action == .waited else { return nil }
            return value
        }
        #expect(groups.contains { $0.header == "Working" })
        #expect(!waitRows.isEmpty)
        #expect(waitRows.allSatisfy { !$0.agentNames.isEmpty })
        #expect(waitRows.contains { !$0.agentMessages.isEmpty })
    }

    @Test func officialCollabReplayMatchesCapturedRowsAndFiltersChildThreads() throws {
        let transcript = try replay(
            "turn-collab-official",
            threadID: "019f521f-4a88-7003-91ff-36afe08e67cf"
        )
        #expect(transcript.turns.count == 3)
        let firstTurn = try #require(transcript.turns.first)
        #expect(firstTurn.narrative.compactMap(\.header).contains("Created 2 agents"))
        let labels = transcript.turns.flatMap(\.narrative).flatMap(\.rows).compactMap { row -> String? in
            guard case .collabAgent(let value) = row else { return nil }
            return value.label
        }
        #expect(labels.contains { $0.hasPrefix("Created agent-019f521f with the instructions: In /Users/") })
        #expect(labels.contains { $0.hasPrefix("Sent input to agent-") })
    }

    @Test func ultraSubagentReplayBuildsTwoIndependentAgentTranscripts() throws {
        let replay = try replayWithSubagents(
            "turn-subagents-ultra",
            threadID: "019f5233-c8fa-7cf0-b33b-6f2fb77a4230"
        )
        let mainTurn = try #require(replay.transcript.turns.first)
        #expect(mainTurn.narrative.flatMap(\.rows).contains { row in
            guard case .collabAgent(let agent) = row else { return false }
            return agent.action == .started
        })
        #expect(mainTurn.narrative.flatMap(\.rows).contains { row in
            guard case .collabAgent(let agent) = row else { return false }
            return agent.action == .waited
        })
        #expect(replay.subagents.agents.count == 2)
        #expect(replay.subagents.agents.map(\.agentPath) == ["/root/count_binaries", "/root/count_docs"])
        #expect(replay.subagents.agents.allSatisfy { agent in
            !agent.transcript.turns.isEmpty
                && agent.transcript.turns.contains { !$0.narrative.flatMap(\.rows).isEmpty }
                && agent.transcript.turns.contains { $0.narrative.contains(where: \.isProse) || $0.finalAnswer != nil }
        })
        #expect(replay.subagents.agents.allSatisfy { agent in
            guard case .completed = agent.status else { return false }
            return true
        })
    }

    @Test func classicCollabReplayDiscoversAgentsWithoutChangingMainTranscript() throws {
        let replay = try replayWithSubagents(
            "turn-collab-official",
            threadID: "019f521f-4a88-7003-91ff-36afe08e67cf"
        )
        #expect(replay.transcript.turns.count == 3)
        #expect(replay.subagents.agents.count == 2)
        #expect(replay.transcript.turns.first?.narrative.compactMap(\.header).contains("Created 2 agents") == true)
        let labels = replay.transcript.turns.flatMap(\.narrative).flatMap(\.rows).compactMap { row -> String? in
            guard case .collabAgent(let value) = row else { return nil }
            return value.label
        }
        #expect(labels.contains { $0.hasPrefix("Created agent-019f521f with the instructions: In /Users/") })
        #expect(labels.contains { $0.hasPrefix("Sent input to agent-") })
    }

    @Test func mcpFailureReplay() throws {
        let transcript = try replay("turn-mcp-failure")
        let turn = try #require(transcript.turns.first)
        let calls = turn.narrative.flatMap(\.rows).compactMap { if case .mcpToolCall(let value) = $0 { value } else { nil } }
        #expect(calls.count == 5)
        #expect(calls.filter { $0.status == .failed }.count == 2)
        #expect(calls.first { $0.tool == "github.get_repo" }?.errorFirstLine?.hasPrefix("GitHub API error 404") == true)
        #expect(turn.liveTail == "Asking Gmail")
    }

    @Test func reconcileAndNilPhaseDemotion() {
        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.submitLocalUserMessage(text: "local", clientID: "c")
        reducer.apply(method: "turn/started", params: json(["threadId":"t", "turn":["id":"v"]]))
        reducer.apply(method: "item/started", params: json(["threadId":"t", "turnId":"v", "item":["type":"userMessage", "id":"server", "clientId":"c", "content":[["type":"text", "text":"echo"]]]]))
        for id in ["one", "two"] { reducer.apply(method: "item/started", params: json(["threadId":"t", "turnId":"v", "item":["type":"agentMessage", "id":id, "text":id]])) }
        #expect(reducer.transcript.turns[0].userMessage?.id == "server")
        #expect(reducer.transcript.turns[0].narrative.contains { $0.id == "one" })
        #expect(reducer.transcript.turns[0].finalAnswer?.id == "two")
    }

    @Test func messageDeltaAliasesStreamIntoFinalAnswer() throws {
        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.apply(method: "item/started", params: json([
            "threadId": "t", "turnId": "v",
            "item": ["type": "agentMessage", "id": "answer", "phase": "final_answer", "text": ""]
        ]))
        reducer.apply(method: "item/message/delta", params: json([
            "threadId": "t", "turnId": "v", "itemId": "answer", "delta": "Hello"
        ]))
        reducer.apply(method: "item/agentMessage/delta", params: json([
            "threadId": "t", "turnId": "v", "itemId": "answer", "delta": " world"
        ]))

        #expect(try #require(reducer.transcript.turns.first?.finalAnswer?.text) == "Hello world")
    }

    @Test func historyRestoresExactTurnEnvelopes() async throws {
        let parent = json([
            "thread": [
                "id": "thread-1",
                "status": ["type": "idle"],
                "turns": [
                    [
                        "id": "turn-complete",
                        "status": "completed",
                        "startedAt": 100,
                        "completedAt": 108,
                        "durationMs": 8_000,
                        "itemsView": "full",
                        "items": [[
                            "type": "agentMessage",
                            "id": "answer",
                            "phase": "final_answer",
                            "text": "done"
                        ]]
                    ],
                    [
                        "id": "turn-failed-empty",
                        "status": "failed",
                        "startedAt": 200,
                        "completedAt": 201,
                        "error": [
                            "message": "structured failure",
                            "additionalDetails": "request id 42"
                        ],
                        "itemsView": "notLoaded",
                        "items": []
                    ]
                ]
            ]
        ])

        let result = await CodexThreadHistorySession.restore(parentRaw: parent) { _ in
            throw Error.invalid
        }
        let turns = result.transcriptV2.turns

        #expect(turns.map(\.id) == ["turn-complete", "turn-failed-empty"])
        #expect(turns[0].wireStatus == .completed)
        #expect(turns[0].startedAt == 100)
        #expect(turns[0].completedAt == 108)
        #expect(turns[0].durationMs == 8_000)
        #expect(turns[0].itemsView == .full)
        #expect(turns[1].wireStatus == .failed)
        #expect(turns[1].error?.message == "structured failure")
        #expect(turns[1].error?.additionalDetails == "request id 42")
        #expect(turns[1].userMessage == nil)
    }

    @Test func structuredErrorsRespectRetrySemantics() throws {
        var reducer = CodexTranscriptReducerV2(threadID: "thread-1")
        reducer.apply(method: "turn/started", params: json([
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "inProgress"]
        ]))
        reducer.apply(method: "error", params: json([
            "threadId": "thread-1",
            "turnId": "turn-1",
            "willRetry": true,
            "error": ["message": "temporary overload"]
        ]))

        guard case .working = try #require(reducer.transcript.turns.first).status else {
            Issue.record("A retrying error must keep the turn active")
            return
        }

        reducer.apply(method: "error", params: json([
            "threadId": "thread-1",
            "turnId": "turn-1",
            "willRetry": false,
            "error": ["message": "terminal overload", "additionalDetails": "retry budget exhausted"]
        ]))

        let turn = try #require(reducer.transcript.turns.first)
        #expect(turn.error?.message == "terminal overload")
        #expect(turn.error?.additionalDetails == "retry budget exhausted")
        #expect(turn.status == .failed(message: "terminal overload"))

        var completionReducer = CodexTranscriptReducerV2(threadID: "thread-1")
        completionReducer.apply(method: "turn/started", params: json([
            "threadId": "thread-1", "turn": ["id": "turn-2", "status": "inProgress"]
        ]))
        completionReducer.apply(method: "turn/completed", params: json([
            "threadId": "thread-1",
            "turn": [
                "id": "turn-2",
                "status": "failed",
                "error": ["message": "completion failure"],
                "items": []
            ]
        ]))
        #expect(completionReducer.transcript.turns.first?.status == .failed(message: "completion failure"))

        var statusOnlyFailure = CodexTranscriptReducerV2(threadID: "thread-1")
        statusOnlyFailure.apply(method: "turn/started", params: json([
            "threadId": "thread-1", "turn": ["id": "turn-3", "status": "inProgress"]
        ]))
        statusOnlyFailure.apply(method: "turn/completed", params: json([
            "threadId": "thread-1",
            "turn": ["id": "turn-3", "status": "failed", "items": []]
        ]))
        #expect(statusOnlyFailure.transcript.turns.first?.wireStatus == .failed)
        #expect(statusOnlyFailure.transcript.turns.first?.status == .failed(message: "Turn failed"))
    }

    @Test func headersAndLiveTail() {
        func row(_ id: String, _ action: CodexWorkCategoryV2) -> CodexWorkRowV2 { .command(.init(id:id, command:id, label:id, action:action, status:.completed, exitCode:0, durationMs:nil, output:nil)) }
        #expect(CodexWorkGroupHeaderV2.synthesize(rows: [row("l",.list),row("1",.run),row("2",.run)]) == "Listed files, ran 2 commands")
        #expect(CodexWorkGroupHeaderV2.synthesize(rows: [row("a",.read),row("b",.read),row("s",.search),row("1",.run),row("2",.run)]) == "Read 2 files and searched, ran 2 commands")
        var reducer = CodexTranscriptReducerV2(threadID:"t")
        reducer.apply(method:"turn/started", params:json(["threadId":"t","turn":["id":"v"]]))
        reducer.apply(method:"item/started", params:json(["threadId":"t","turnId":"v","item":["type":"reasoning","id":"r","summary":[],"content":[]]]))
        #expect(reducer.transcript.turns[0].liveTail == "Thinking")
    }

    @Test func stopwatchUsesEpochSecondsBackfillsAndFallsBackToClientAnchor() throws {
        let now = Date(timeIntervalSince1970: 1_783_539_680)
        #expect(CodexWorkBlockViewV2.elapsedSeconds(
            at: now,
            since: 1_783_539_644,
            clientStartedAt: .distantPast
        ) == 36)
        #expect(CodexWorkBlockViewV2.workingLabel(
            at: now,
            since: 1_783_539_644,
            clientStartedAt: .distantPast
        ) == "Working for 36s")
        #expect(CodexWorkBlockViewV2.elapsedSeconds(
            at: now,
            since: nil,
            clientStartedAt: now.addingTimeInterval(-7)
        ) == 7)
        #expect(CodexWorkBlockViewV2.duration(68_000) == "1m 8s")

        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.apply(method: "item/started", params: json([
            "threadId": "t", "turnId": "v",
            "item": ["type": "reasoning", "id": "r", "summary": [], "content": []]
        ]))
        guard case .working(let initialSince) = reducer.transcript.turns[0].status else {
            Issue.record("Expected working turn")
            return
        }
        #expect(initialSince == nil)

        reducer.apply(method: "turn/started", params: json([
            "threadId": "t", "turn": ["id": "v", "startedAt": 1_783_539_644]
        ]))
        guard case .working(let backfilledSince) = reducer.transcript.turns[0].status else {
            Issue.record("Expected working turn after backfill")
            return
        }
        #expect(backfilledSince == 1_783_539_644)
    }

    @Test func activePresentationDistinguishesThinkingFromIntermediateWork() {
        #expect(!CodexWorkBlockViewV2.showsWorkingDuration(narrative: [], liveTail: nil))
        #expect(!CodexWorkBlockViewV2.showsWorkingDuration(narrative: [], liveTail: "Thinking"))
        #expect(CodexWorkBlockViewV2.showsWorkingDuration(narrative: [], liveTail: "Running rg"))
        #expect(CodexWorkBlockViewV2.showsWorkingDuration(
            narrative: [.prose(.init(id: "one", text: "First")), .prose(.init(id: "two", text: "Second"))],
            liveTail: nil
        ))
    }

    @Test func subAgentActivityMapsToAgentWorkWithoutGenericChrome() throws {
        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.apply(method: "item/started", params: json([
            "threadId": "t", "turnId": "v",
            "item": [
                "type": "subAgentActivity", "id": "activity-1", "kind": "interacted",
                "agentThreadId": "agent-thread", "agentPath": "agents/reviewer"
            ]
        ]))

        let turn = try #require(reducer.transcript.turns.first)
        let group = try #require(turn.narrative.compactMap(\.workGroup).first)
        #expect(group.header == "Worked with an agent")
        #expect(turn.liveTail == "Working with agents")
        guard case .collabAgent(let row) = try #require(group.rows.first) else {
            Issue.record("Expected collab-agent row")
            return
        }
        #expect(row.action == .interacted)
        #expect(row.agentNames == ["agents/reviewer"])
    }

    @Test func planIsProseAndUnknownItemsAreSkipped() throws {
        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.apply(method: "item/completed", params: json([
            "threadId": "t", "turnId": "v",
            "item": ["type": "plan", "id": "plan-1", "text": "## Plan\n\n- Ship it"]
        ]))
        reducer.apply(method: "item/started", params: json([
            "threadId": "t", "turnId": "v",
            "item": ["type": "futureWireItem", "id": "unknown-1"]
        ]))

        let turn = try #require(reducer.transcript.turns.first)
        #expect(turn.narrative.count == 1)
        guard case .prose(let prose) = turn.narrative[0] else {
            Issue.record("Expected plan prose")
            return
        }
        #expect(prose.text == "## Plan\n\n- Ship it")
        #expect(turn.liveTail == nil)

        var unknownOnly = CodexTranscriptReducerV2(threadID: "t")
        unknownOnly.apply(method: "item/started", params: json([
            "threadId": "t", "turnId": "v", "item": ["type": "futureWireItem", "id": "unknown-2"]
        ]))
        #expect(unknownOnly.transcript.turns.isEmpty)
        #expect(CodexWorkGroupHeaderV2.synthesize(rows: []) == "")
    }

    @Test func completionDerivesMissingDurationFromWireTimestamps() throws {
        var reducer = CodexTranscriptReducerV2(threadID: "t")
        reducer.apply(method: "turn/started", params: json([
            "threadId": "t", "turn": ["id": "v", "startedAt": 100]
        ]))
        reducer.apply(method: "turn/completed", params: json([
            "threadId": "t", "turn": ["id": "v", "startedAt": 100, "completedAt": 108]
        ]))

        let turn = try #require(reducer.transcript.turns.first)
        guard case .done(let durationMs) = turn.status else {
            Issue.record("Expected completed turn")
            return
        }
        #expect(durationMs == 8_000)
        #expect(CodexWorkBlockViewV2.duration(durationMs) == "8s")
    }

    private func replay(_ name: String, threadID explicitThreadID: String? = nil) throws -> CodexTranscriptV2 {
        struct Event: Decodable { let method: String; let params: CodexJSONValue }
        let url = try #require(Bundle.module.url(forResource:name, withExtension:"jsonl"))
        let lines = try String(contentsOf:url, encoding:.utf8).split(separator:"\n"), decoder = JSONDecoder()
        let first = try decoder.decode(Event.self, from:Data(lines[0].utf8))
        guard case .dictionary(let p) = first.params else { throw Error.invalid }
        let rootThreadID: String? = if case .string(let value)? = p["threadId"] { value } else { nil }
        let nestedThreadID: String? = if case .dictionary(let thread)? = p["thread"],
                                         case .string(let value)? = thread["id"] { value } else { nil }
        let thread = explicitThreadID
            ?? rootThreadID
            ?? nestedThreadID
        guard let thread else { throw Error.invalid }
        var reducer = CodexTranscriptReducerV2(threadID:thread)
        for line in lines { let event = try decoder.decode(Event.self, from:Data(line.utf8)); reducer.apply(method:event.method, params:event.params) }
        return reducer.transcript
    }
    private func replayWithSubagents(_ name: String, threadID: String) throws -> (transcript: CodexTranscriptV2, subagents: CodexSubagentStoreV2) {
        struct Event: Decodable { let method: String; let params: CodexJSONValue }
        let url = try #require(Bundle.module.url(forResource:name, withExtension:"jsonl"))
        let lines = try String(contentsOf:url, encoding:.utf8).split(separator:"\n"), decoder = JSONDecoder()
        var reducer = CodexTranscriptReducerV2(threadID: threadID)
        var subagents = CodexSubagentStoreV2()
        for line in lines {
            let event = try decoder.decode(Event.self, from:Data(line.utf8))
            reducer.apply(method:event.method, params:event.params)
            subagents.apply(method:event.method, params:event.params)
        }
        return (reducer.transcript, subagents)
    }
    private func json(_ value: Any) -> CodexJSONValue { try! JSONDecoder().decode(CodexJSONValue.self, from:JSONSerialization.data(withJSONObject:value)) }
    private func notification(_ method: String, _ params: [String: CodexJSONValue]) -> CodexNotification {
        CodexNotification(method: method, payload: .unknown(method: method, params: params), rawParams: params)
    }
    enum Error: Swift.Error { case invalid }
}

private extension CodexNarrativeEntry {
    var isProse: Bool { if case .prose = self { true } else { false } }
    var header: String? { if case .workGroup(let group) = self { group.header } else { nil } }
    var rows: [CodexWorkRowV2] { if case .workGroup(let group) = self { group.rows } else { [] } }
    var workGroup: CodexWorkGroupV2? { if case .workGroup(let group) = self { group } else { nil } }
}
