import XCTest
@testable import CodexCoreUI

final class CodexAccessibilityLabelTests: XCTestCase {
    func testComposerSendStopLabelsMatchIconOnlyControls() {
        XCTAssertEqual(CodexComposerAccessibility.sendButtonLabel(isEnabled: true), "Send message")
        XCTAssertEqual(CodexComposerAccessibility.sendButtonLabel(isEnabled: false), "Send message unavailable")
        XCTAssertEqual(CodexComposerAccessibility.sendButtonHelp(isEnabled: true), "Send message (Command-Return)")
        XCTAssertEqual(CodexComposerAccessibility.stopButtonLabel, "Stop response")
    }

    func testSidebarCommandLabelsIncludeVisibleShortcuts() {
        XCTAssertEqual(
            CodexSidebarAccessibility.commandRowLabel(title: "Search", shortcut: "⌘G"),
            "Search, shortcut ⌘G"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.commandRowLabel(title: "Plugins"),
            "Plugins"
        )
    }

    func testSidebarProjectAndChatAffordanceLabelsAreSpecific() {
        XCTAssertEqual(
            CodexSidebarAccessibility.collapseToggleLabel(isCollapsed: true),
            "Expand sidebar"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.projectDisclosureLabel(projectTitle: "CodexCore", isExpanded: false),
            "Expand project CodexCore"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.projectNewChatLabel(projectTitle: "CodexCore"),
            "New chat in CodexCore"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatPinLabel(isPinned: true, title: "Review PR"),
            "Unpin chat Review PR"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatArchiveLabel(title: "Review PR"),
            "Archive chat Review PR"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatUnarchiveLabel(title: "Review PR"),
            "Restore chat Review PR"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatSelectLabel(title: "Review PR"),
            "Select chat Review PR"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatStatusValue(
                status: .running,
                hasUnreadUpdates: true,
                recencyLabel: "2m",
                progress: 0.42,
                statusText: "Working"
            ),
            "Unread updates, Running, Working, 42 percent"
        )
        XCTAssertEqual(
            CodexSidebarAccessibility.chatStatusValue(
                status: .idle,
                hasUnreadUpdates: false,
                recencyLabel: "2m"
            ),
            "2m"
        )
    }
}
