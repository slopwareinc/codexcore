import XCTest
@testable import CodexCoreUI

final class CodexSidebarRouteTests: XCTestCase {
    func testPrimarySidebarRoutesIncludeAutomationsAfterPlugins() {
        XCTAssertEqual(CodexAppRoute.primarySidebarRoutes, [
            .plugins,
            .automations,
        ])
        XCTAssertEqual(
            CodexAppRoute.primarySidebarRoutes.map(\.title),
            ["Plugins", "Automations"]
        )
    }
}
