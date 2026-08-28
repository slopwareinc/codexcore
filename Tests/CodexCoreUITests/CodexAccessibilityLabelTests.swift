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
            CodexSidebarAccessibility.chatStatusValue(
                status: .running,
                hasUnreadUpdates: true,
                recencyLabel: "2m"
            ),
            "Unread updates, Running"
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

    func testWorkspacePanelLabelsNamePlacementAndKeyboardMoveAction() {
        XCTAssertEqual(
            CodexWorkspaceTabAccessibility.panelLabel(.right),
            "Workspace right panel"
        )
        XCTAssertEqual(
            CodexWorkspaceTabAccessibility.panelLabel(.bottom),
            "Workspace bottom panel"
        )
        XCTAssertEqual(
            CodexWorkspaceTabAccessibility.moveLabel(title: "swift test", to: .bottom),
            "Move swift test to bottom panel"
        )
        XCTAssertEqual(
            CodexWorkspaceTabAccessibility.closeLabel(title: "swift test"),
            "Close swift test"
        )
        XCTAssertEqual(CodexWorkspaceTabAccessibility.moveShortcut(for: .right), "⌘⌥]")
        XCTAssertEqual(CodexWorkspaceTabAccessibility.moveShortcut(for: .bottom), "⌘⌥[")
    }
}
