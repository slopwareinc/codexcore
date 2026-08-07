@testable import CodexCoreUI
import Testing

struct CodexSubagentEmptyStateTests {
    @Test func emptyTranscriptCopyReflectsTheAgentLifecycle() {
        var agent = CodexSubagentState(
            name: "Cicero",
            title: "Subagent",
            prompt: "Do nothing",
            status: .running
        )

        #expect(agent.emptyTranscriptMessage == "Waiting for this agent’s transcript…")

        agent.status = .completed
        #expect(
            agent.emptyTranscriptMessage
                == "This agent completed without returning a transcript."
        )

        agent.status = .failed
        #expect(
            agent.emptyTranscriptMessage
                == "This agent failed before returning a transcript."
        )
    }
}
