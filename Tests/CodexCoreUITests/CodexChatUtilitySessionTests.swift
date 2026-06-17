import XCTest
@testable import CodexCore
@testable import CodexCoreUI

extension CodexAgentUITests {
    func testChatUtilitySessionFormatsTranscriptWithCommandFallback() {
        let messages = [
            CodexChatMessage(role: .user, text: "  Build it  "),
            CodexChatMessage(
                role: .terminal,
                text: "   ",
                commandRun: .init(
                    itemID: "cmd-1",
                    command: "swift test",
                    output: "",
                    status: "completed",
                    isStreaming: false
                )
            )
        ]

        XCTAssertEqual(
            CodexChatUtilitySession.transcriptText(messages: messages),
            """
            You: Build it

            Terminal: swift test
            """
        )
    }

    func testChatUtilitySessionFormatsCopyActivityDetail() {
        XCTAssertEqual(CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: 0), "No transcript text yet")
        XCTAssertEqual(CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: 2), "2 messages copied")
    }

    func testChatUtilitySessionFormatsStatusSummary() {
        let summary = CodexChatUtilitySession.statusSummary(
            CodexChatStatusSummaryContext(
                connectionLabel: "Connected",
                workspacePath: "/tmp/project",
                currentThreadID: "thread-123",
                modelDisplayName: "GPT-5.1 Codex Max",
                reasoningDisplayName: "High",
                approvalDisplayName: "Ask for approval",
                messageCount: 7,
                isSideChatOpen: true,
                activeSubagentCount: 2,
                subagentCount: 3
            )
        )

        XCTAssertEqual(
            summary,
            """
            Connection: Connected
            Project: /tmp/project
            Chat: thread-123
            Model: GPT-5.1 Codex Max High
            Approval: Ask for approval
            Messages: 7
            Side chat: open
            Subagents: 2 active / 3 total
            """
        )
    }

}
