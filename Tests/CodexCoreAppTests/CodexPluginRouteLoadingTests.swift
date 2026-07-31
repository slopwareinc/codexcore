import Testing
@testable import CodexCoreApp

@MainActor
@Suite("Plugin route loading")
struct CodexPluginRouteLoadingTests {
    @Test("Opening Plugins exposes loading before the asynchronous refresh starts")
    func openMarksCatalogLoadingSynchronously() {
        let model = CodexCoreAppModel()

        model.selectAppRoute(.plugins)

        #expect(model.isLoadingPlugins)
        #expect(model.isLoadingSkills)
    }

    @Test("Repeated appearance callbacks do not schedule duplicate refreshes")
    func repeatedRequestPreservesLoadingState() {
        let model = CodexCoreAppModel()

        model.requestPluginRefresh()
        model.requestPluginRefresh()

        #expect(model.isLoadingPlugins)
        #expect(model.isLoadingSkills)
    }
}
