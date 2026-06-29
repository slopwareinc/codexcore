import XCTest
@testable import CodexCoreUI

final class CodexThreadLifecycleActionTests: XCTestCase {
    func testAddAutomationDraftPromptIsBoundedToCurrentChatContext() {
        let prompt = CodexThreadLifecycleActionModel.addAutomationDraftPrompt(
            threadID: "thread-123",
            threadTitle: "Release planning",
            workspacePath: "/tmp/CodexCore"
        )

        XCTAssertTrue(prompt.contains("Release planning"))
        XCTAssertTrue(prompt.contains("thread-123"))
        XCTAssertTrue(prompt.contains("/tmp/CodexCore"))
        XCTAssertTrue(prompt.contains("Ask me what should trigger it"))
        XCTAssertTrue(prompt.contains("before changing any settings"))
    }
}
