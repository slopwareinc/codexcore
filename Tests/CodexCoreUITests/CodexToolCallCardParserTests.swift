import XCTest
@testable import CodexCoreUI

final class CodexToolCallCardParserTests: XCTestCase {
    func testParseToolCallsMarkdown() throws {
        let md = """
        ### Command Execution
        status: completed
        duration: 2.3s
        cwd: /tmp/project
        command: ```bash
        swift build
        ```
        """

        let cards = CodexToolCallCardParser.parse(md)
        XCTAssertEqual(cards.count, 1)

        let card = cards[0]
        XCTAssertEqual(card.kind, .commandExecution)
        XCTAssertEqual(card.status, .completed)
        XCTAssertEqual(card.duration, "2.3s")
        XCTAssertEqual(card.commandContext?.command, "swift build")
        XCTAssertEqual(card.commandContext?.directory, "/tmp/project")
    }

    func testToolCallKindIconNamesLiveInUI() {
        // Presentation now lives in the UI layer.
        XCTAssertEqual(ToolCallKind.commandExecution.iconName, "terminal.fill")
        XCTAssertEqual(ToolCallStatus.inProgress.label, "In Progress")
        XCTAssertTrue(ToolCallCardModel(
            kind: .fileChange, title: "t", summary: "", status: .failed, duration: nil, sections: []
        ).defaultExpanded)
    }
}
