import XCTest
@testable import CodexCoreUI

final class CodexChatMessageRenderKeyTests: XCTestCase {
    func testChangesWhenVisibleTextChanges() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let date = Date(timeIntervalSince1970: 100)
        let first = CodexChatMessage(id: id, role: .assistant, text: "First answer", createdAt: date)
        let second = CodexChatMessage(id: id, role: .assistant, text: "Final answer", createdAt: date)

        XCTAssertNotEqual(
            CodexChatMessageRenderKey(message: first),
            CodexChatMessageRenderKey(message: second)
        )
    }

    func testIgnoresProjectedBlocksWhenTextMatches() {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let date = Date(timeIntervalSince1970: 200)
        let parsed = CodexChatMessage(id: id, role: .assistant, text: "**Done**", createdAt: date)
        let unparsed = CodexChatMessage(id: id, role: .assistant, text: "**Done**", createdAt: date, parseContent: false)

        XCTAssertEqual(
            CodexChatMessageRenderKey(message: parsed),
            CodexChatMessageRenderKey(message: unparsed)
        )
    }

    func testChangesWhenStructuredPayloadChanges() {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let date = Date(timeIntervalSince1970: 300)
        let first = CodexChatMessage(
            id: id,
            role: .terminal,
            text: "swift test",
            createdAt: date,
            commandRun: CodexChatMessage.CommandRun(
                itemID: "cmd-1",
                command: "swift test",
                output: "first output",
                status: "running",
                isStreaming: true
            )
        )
        let second = CodexChatMessage(
            id: id,
            role: .terminal,
            text: "swift test",
            createdAt: date,
            commandRun: CodexChatMessage.CommandRun(
                itemID: "cmd-1",
                command: "swift test",
                output: "second output",
                status: "running",
                isStreaming: true
            )
        )

        XCTAssertNotEqual(
            CodexChatMessageRenderKey(message: first),
            CodexChatMessageRenderKey(message: second)
        )
    }
}
