import XCTest
@testable import CodexCoreUI

final class CodexChatUtilitySessionTests: XCTestCase {
    func testTranscriptTextPreservesUserSteerAndAnswerOrderAcrossTurns() {
        let transcript = CodexTranscriptV2(turns: [
            CodexTurnV2(
                id: "first",
                userMessage: CodexUserMessageV2(id: "first-user", text: "Start"),
                steeredMessages: [
                    CodexUserMessageV2(id: "first-steer-one", text: "Continue"),
                    CodexUserMessageV2(id: "first-steer-two", text: "Focus on tests")
                ],
                finalAnswer: CodexAssistantTextV2(id: "first-answer", text: "Done", isStreaming: false),
                status: .done(durationMs: 1)
            ),
            CodexTurnV2(
                id: "second",
                finalAnswer: CodexAssistantTextV2(id: "second-answer", text: "Follow-up", isStreaming: false),
                status: .done(durationMs: 1)
            )
        ])

        XCTAssertEqual(
            CodexChatUtilitySession.transcriptText(transcript: transcript),
            "You: Start\n\nYou: Continue\n\nYou: Focus on tests\n\nCodex: Done\n\nCodex: Follow-up"
        )
    }

    func testTranscriptTextIsEmptyWithoutUserSteerOrAnswerMessages() {
        let transcript = CodexTranscriptV2(turns: [
            CodexTurnV2(id: "empty", status: .working(since: nil))
        ])

        XCTAssertEqual(CodexChatUtilitySession.transcriptText(transcript: transcript), "")
    }
}
