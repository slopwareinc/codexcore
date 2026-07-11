import CodexCore
import CodexCoreUI
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

    private func replay(_ name: String) throws -> CodexTranscriptV2 {
        struct Event: Decodable { let method: String; let params: CodexJSONValue }
        let url = try #require(Bundle.module.url(forResource:name, withExtension:"jsonl"))
        let lines = try String(contentsOf:url, encoding:.utf8).split(separator:"\n"), decoder = JSONDecoder()
        let first = try decoder.decode(Event.self, from:Data(lines[0].utf8))
        guard case .dictionary(let p) = first.params, case .string(let thread)? = p["threadId"] else { throw Error.invalid }
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
}
