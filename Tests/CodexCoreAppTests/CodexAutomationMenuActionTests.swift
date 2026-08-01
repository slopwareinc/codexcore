import XCTest
import AppKit
import CodexCore
import CodexCoreUI
@testable import CodexCoreApp

@MainActor
final class CodexAutomationMenuActionTests: XCTestCase {
    func testMainMenuIncludesAutomationSectionAndCreationCommands() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let app = CodexCoreApp()

        app.configureMainMenu()

        let menu = try XCTUnwrap(NSApplication.shared.mainMenu)
        let automationsMenu = try XCTUnwrap(menu.items
            .compactMap(\.submenu)
            .first { $0.title == "Automations" })
        XCTAssertEqual(
            automationsMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Show Automations", "New Scheduled Automation…", "Create Automation via Chat…"]
        )
    }

    func testNewScheduledAutomationSelectsRouteAndRequestsEditor() {
        let model = CodexCoreAppModel(
            codexHome: CodexHome(path: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true).path),
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )

        model.requestNewScheduledAutomation()

        XCTAssertEqual(model.sidebarNavigationSession.selectedRoute, .automations)
        XCTAssertTrue(model.isNewScheduledAutomationRequested)
    }
}
