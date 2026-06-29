import XCTest
@testable import CodexCoreUI

final class CodexComposerAddMenuModelTests: XCTestCase {
    func testObservedAddMenuRowsMatchCurrentAppCapture() {
        let items = CodexComposerAddMenuModel.observedItems(canUsePlanMode: true)

        XCTAssertEqual(items.map(\.title), [
            "Files and folders",
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
        XCTAssertEqual(browser.activities, [])
        guard case .openPluginLauncher(let browserTarget)? = browser.hostActions.first else {
            return XCTFail("Browser row should launch plugin detail")
        }
        XCTAssertEqual(browserTarget.title, "Browser")
        XCTAssertEqual(browserTarget.searchQuery, "Browser")
        XCTAssertEqual(browserTarget.fallbackDetail.prompt, "Browser\nTest my checkout flow on localhost")

        let computer = CodexComposerAddMenuModel.route(itemID: .computer, canUsePlanMode: true)
        guard case .openPluginLauncher(let computerTarget)? = computer.hostActions.first else {
            return XCTFail("Computer row should launch plugin boundary")
        }
        XCTAssertEqual(computerTarget.title, "Computer Use")
        XCTAssertEqual(computerTarget.fallbackDetail.statusLabel, "Install boundary")
        XCTAssertEqual(computerTarget.fallbackDetail.boundaryActionTitle, "Add")
        XCTAssertTrue(computerTarget.fallbackDetail.description.contains("does not invoke the permission flow"))

        let documents = CodexComposerAddMenuModel.route(itemID: .documents, canUsePlanMode: true)
        guard case .openPluginLauncher(let documentTarget)? = documents.hostActions.first else {
            return XCTFail("Documents row should launch artifact plugin boundary")
        }
        XCTAssertEqual(documentTarget.title, "Documents")
        XCTAssertEqual(documentTarget.fallbackDetail.statusLabel, "Artifact boundary")

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
