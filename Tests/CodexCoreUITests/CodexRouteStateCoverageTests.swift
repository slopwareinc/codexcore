import XCTest
@testable import CodexCoreUI

final class CodexRouteStateCoverageTests: XCTestCase {
    func testEveryFirstClassRouteDocumentsEmptyLoadingAndErrorStates() {
        let documentedRoutes = CodexRouteStateCoverageCatalog.firstClassRoutes.compactMap(\.route)

        XCTAssertEqual(documentedRoutes, CodexAppRoute.allCases)
        for route in CodexAppRoute.allCases {
            let coverage = CodexRouteStateCoverageCatalog.coverage(for: route)
            XCTAssertNotNil(coverage, "\(route.title) should have route-state coverage")
            XCTAssertTrue(coverage?.coversAllKinds == true, "\(route.title) should cover empty/loading/error")
            XCTAssertFalse(coverage?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            for kind in CodexRouteStateKind.allCases {
                let entry = coverage?.entry(for: kind)
                XCTAssertFalse(entry?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                XCTAssertFalse(entry?.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
    }

    func testPanelSurfacesDocumentReviewAndSideChatStates() {
        let panelIDs = CodexRouteStateCoverageCatalog.panelSurfaces.map(\.id)

        XCTAssertEqual(panelIDs, ["review-panel", "side-chat-panel"])
        for panel in CodexRouteStateCoverageCatalog.panelSurfaces {
            XCTAssertTrue(panel.coversAllKinds)
        }
    }

    func testCoverageUsesExistingRouteStateStringsWhereAvailable() {
        let search = CodexRouteStateCoverageCatalog.coverage(for: .search)
        XCTAssertEqual(search?.entry(for: .loading)?.title, "Searching...")

        let automations = CodexRouteStateCoverageCatalog.coverage(for: .automations)
        XCTAssertEqual(automations?.entry(for: .empty)?.title, CodexAutomationRouteState().emptyTitle)

        let mobile = CodexRouteStateCoverageCatalog.coverage(for: .codexMobile)
        XCTAssertEqual(mobile?.entry(for: .error)?.title, "Remote control unavailable")

        let settings = CodexRouteStateCoverageCatalog.coverage(for: .settingsAbout)
        XCTAssertEqual(settings?.entry(for: .error)?.title, "Version unavailable")
    }
}
