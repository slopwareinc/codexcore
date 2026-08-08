import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
@Suite("Marketplace actions")
struct CodexMarketplaceActionTests {
    @Test("App model routes marketplace callbacks and publishes pending and error state")
    func routesMarketplaceMutation() async {
        let provider = MarketplaceFailureProvider()
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            pluginCatalogActionProvider: provider
        )
        let marketplace = CodexMarketplaceSummary(name: "team", displayName: "Team", pluginCount: 2)

        model.performPluginCatalogAction(.upgradeMarketplace(.init(marketplace: marketplace)))
        #expect(model.pendingMarketplaceActionIDs == ["team"])
        await provider.waitForInvocation()
        #expect(await provider.invocation == "upgrade:team")
        await provider.complete()
        for _ in 0..<10 { await Task.yield() }

        #expect(model.pendingMarketplaceActionIDs.isEmpty)
        #expect(model.marketplaceActionErrors["team"] == "Synthetic marketplace error")
    }
}

private actor MarketplaceFailureProvider: CodexPluginCatalogActionProvider {
    private(set) var invocation: String?
    private var continuation: CheckedContinuation<Void, Never>?

    func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome { unsupported() }
    func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome { unsupported() }
    func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome { unsupported() }
    func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome { unsupported() }

    func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome {
        invocation = "upgrade:\(target.name)"
        await withCheckedContinuation { continuation = $0 }
        return .init(
            activity: .init(title: "Couldn’t upgrade Team", detail: "Synthetic marketplace error"),
            didSucceed: false
        )
    }

    func waitForInvocation() async {
        while invocation == nil { await Task.yield() }
    }

    func complete() { continuation?.resume(); continuation = nil }

    private func unsupported() -> CodexPluginActionOutcome {
        .init(activity: .init(title: "Unsupported", detail: "Unsupported"), didSucceed: false)
    }
}
