import Observation
import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
@Suite("App inventory view state")
struct CodexAppInventoryViewStateTests {
    @Test("Opening Plugins synchronously exposes app loading")
    func routeSelectionMarksAppsLoading() {
        let model = CodexCoreAppModel()
        model.selectAppRoute(.plugins)
        #expect(model.isLoadingApps)
    }

    @Test("App inventory changes invalidate observed model view state")
    func appsAreExposedThroughObservableViewState() {
        let model = CodexCoreAppModel()
        nonisolated(unsafe) var invalidations = 0
        withObservationTracking {
            _ = model.apps
        } onChange: {
            invalidations += 1
        }

        model.runtimeSession.integrationCatalogSession = .init(apps: [
            CodexAppSummary(id: "github", name: "GitHub", isInstalled: true, runtimeEnabled: true)
        ])
        model.selectAppRoute(.plugins)

        #expect(model.apps.map(\.id) == ["github"])
        #expect(invalidations == 1)
    }
}
