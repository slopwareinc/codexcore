import Observation
import Testing
import CodexCore
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

    @Test("Global MCP and app catalogs never become thread overview resources")
    func globalCatalogIsExcludedFromThreadResources() throws {
        let model = CodexCoreAppModel()
        model.runtimeSession.integrationCatalogSession = .init(
            mcpServers: [
                .init(
                    name: "global-server",
                    resources: [.init(name: "global-resource", title: "Global resource")]
                ),
            ],
            apps: [
                .init(id: "global-app", name: "Global app", isInstalled: true, runtimeEnabled: true),
            ]
        )
        let revision = StateRevision(1)
        let threadID: ThreadID = "thread"
        model.applySelectedThreadSnapshotForTesting(threadID: threadID.rawValue, snapshot: .init(
            stateRevision: revision,
            canonical: .init(
                revision: revision,
                threadOrder: [threadID],
                threads: [threadID: .init(
                    id: threadID,
                    status: .idle,
                    history: .init(turnsCoverage: .full),
                    consistency: .authoritative,
                    lastChangedRevision: revision
                )]
            ),
            serverRequests: .init(revision: revision, requests: []),
            lifecycle: .ready(connectionEpoch: 1)
        ))

        let resources = try #require(model.threadResourceInventory).resources
        #expect(!resources.contains { $0.kind == .mcpResource })
        #expect(!resources.contains { $0.kind == .mcpApp })
        #expect(!resources.contains { $0.title == "Global resource" || $0.title == "Global app" })
    }
}
