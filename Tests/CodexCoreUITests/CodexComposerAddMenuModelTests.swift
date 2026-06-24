import XCTest
@testable import CodexCoreUI

final class CodexComposerAddMenuModelTests: XCTestCase {
    func testObservedAddMenuRowsMatchCurrentAppCapture() {
        let items = CodexComposerAddMenuModel.observedItems(canUsePlanMode: true)

        XCTAssertEqual(items.map(\.title), [
            "Files and folders",
            "Attach Warp",
            "Goal",
            "Plan mode",
            "Plugins",
            "Documents",
            "PDF",
            "Spreadsheets",
            "Presentations",
            "Template Creator",
            "Browser",
            "Computer",
            "GitHub",
            "Files and chats"
        ])
        XCTAssertEqual(items.map(\.id), CodexComposerAddMenuItemID.allCases)
        XCTAssertTrue(items.allSatisfy(\.isEnabled))

        let withoutPlan = CodexComposerAddMenuModel.observedItems(canUsePlanMode: false)
        XCTAssertFalse(try XCTUnwrap(withoutPlan.first { $0.id == .planMode }).isEnabled)
    }

    func testActionableAddMenuRowsReturnHostActionsAndBoundariesStayExplicit() {
        XCTAssertEqual(
            CodexComposerAddMenuModel.route(itemID: .filesAndFolders, canUsePlanMode: true).hostActions,
            [.attachFilesAndFolders]
        )
        XCTAssertEqual(
            CodexComposerAddMenuModel.route(itemID: .goal, canUsePlanMode: true).hostActions,
            [.enableGoalPursuit]
        )
        XCTAssertEqual(
            CodexComposerAddMenuModel.route(itemID: .planMode, canUsePlanMode: true).hostActions,
            [.enablePlanMode]
        )
        XCTAssertEqual(
            CodexComposerAddMenuModel.route(itemID: .plugins, canUsePlanMode: true).hostActions,
            [.openPlugins]
        )
        XCTAssertEqual(
            CodexComposerAddMenuModel.route(itemID: .filesAndChats, canUsePlanMode: true).hostActions,
            [.openFilesAndChats]
        )

        let browser = CodexComposerAddMenuModel.route(itemID: .browser, canUsePlanMode: true)
        XCTAssertEqual(browser.hostActions, [])
        XCTAssertEqual(browser.activities.first?.title, "Browser unavailable")
        XCTAssertTrue(browser.activities.first?.detail.contains("not wired") == true)

        let disabledPlan = CodexComposerAddMenuModel.route(itemID: .planMode, canUsePlanMode: false)
        XCTAssertFalse(disabledPlan.isEnabled)
        XCTAssertEqual(disabledPlan.hostActions, [])
        XCTAssertEqual(disabledPlan.activities.first?.title, "Plan mode unavailable")
    }

    func testGoalAndPlanChipsUseCapturedTitlesAndClearLabels() {
        XCTAssertEqual(CodexComposerAddMenuModel.chips(isGoalPursuitEnabled: false, isPlanModeEnabled: false), [])

        let chips = CodexComposerAddMenuModel.chips(isGoalPursuitEnabled: true, isPlanModeEnabled: true)

        XCTAssertEqual(chips.map(\.kind), [.goal, .plan])
        XCTAssertEqual(chips.map(\.title), ["Goal", "Plan"])
        XCTAssertEqual(chips.map(\.clearAccessibilityLabel), ["Clear goal", "Clear plan"])
    }
}
