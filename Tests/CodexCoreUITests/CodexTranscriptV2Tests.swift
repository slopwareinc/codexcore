import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexTranscriptV2Tests {
    @Test func repoInspectReplay() throws {
        let transcript = try replay("turn-repo-inspect")
        let turn = try #require(transcript.turns.first)
        #expect(turn.userMessage != nil)
        #expect(turn.narrative.filter(\.isProse).count == 5)
        #expect(turn.narrative.compactMap(\.header) == ["Listed files, ran 2 commands", "Read 4 files, ran a command", "Read 2 files and searched code, ran 2 commands", "Ran 2 commands"])
        #expect(turn.liveTail == nil)
    }

    @Test func subagentsReplayFiltersChildren() throws {
        let transcript = try replay("turn-subagents"), turn = try #require(transcript.turns.first)
        #expect(transcript.turns.count == 1)
        #expect(turn.narrative.flatMap(\.rows).count == 6)
        #expect(turn.narrative.compactMap(\.header).contains("Created 2 agents"))
        #expect(turn.narrative.compactMap(\.header).contains("Closed 2 agents"))
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
        #expect(createdLabels.allSatisfy { $0.hasPrefix("Created 019f") && $0.contains(" with the instructions: Count from ") })

        let waitRows = groups.flatMap(\.rows).compactMap { row -> CodexCollabAgentRowV2? in
            guard case .collabAgent(let value) = row, value.action == .waited else { return nil }
            return value
        }
        #expect(groups.contains { $0.header == "Working" })
        #expect(!waitRows.isEmpty)
        #expect(waitRows.allSatisfy { !$0.agentNames.isEmpty })
        #expect(waitRows.contains { !$0.agentMessages.isEmpty })
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

    @Test func headersAndLiveTail() {
        func row(_ id: String, _ action: CodexWorkCategoryV2) -> CodexWorkRowV2 { .command(.init(id:id, command:id, label:id, action:action, status:.completed, exitCode:0, durationMs:nil, output:nil)) }
        #expect(CodexWorkGroupHeaderV2.synthesize(rows: [row("l",.list),row("1",.run),row("2",.run)]) == "Listed files, ran 2 commands")
        #expect(CodexWorkGroupHeaderV2.synthesize(rows: [row("a",.read),row("b",.read),row("s",.search),row("1",.run),row("2",.run)]) == "Read 2 files and searched code, ran 2 commands")
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
    private func json(_ value: Any) -> CodexJSONValue { try! JSONDecoder().decode(CodexJSONValue.self, from:JSONSerialization.data(withJSONObject:value)) }
    enum Error: Swift.Error { case invalid }
}

private extension CodexNarrativeEntry {
    var isProse: Bool { if case .prose = self { true } else { false } }
    var header: String? { if case .workGroup(let group) = self { group.header } else { nil } }
    var rows: [CodexWorkRowV2] { if case .workGroup(let group) = self { group.rows } else { [] } }
    var workGroup: CodexWorkGroupV2? { if case .workGroup(let group) = self { group } else { nil } }
}
