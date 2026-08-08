import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
@Suite("App actions")
struct CodexAppActionTests {
    @Test("Installed app local execution publishes pending state and routes the generated config action")
    func routesAppEnablement() async {
        let provider = AppActionProvider()
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            pluginCatalogActionProvider: provider
        )
        let app = CodexAppSummary(
            id: "github",
            name: "GitHub",
            isInstalled: true,
            runtimeEnabled: false,
            runtimeCallable: true
        )

        model.performPluginCatalogAction(.setAppEnabled(.init(app: app), enabled: true))
        #expect(model.pendingAppActionIDs == ["github"])
        await provider.waitForInvocation()
        #expect(await provider.invocation == "github:true")
        await provider.complete()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.pendingAppActionIDs.isEmpty)
    }
}

private actor AppActionProvider: CodexPluginCatalogActionProvider {
    private(set) var invocation: String?
    private var continuation: CheckedContinuation<Void, Never>?

    func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome { unsupported() }
    func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome { unsupported() }
    func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome { unsupported() }
    func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome { unsupported() }

    func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        invocation = "\(target.id):\(enabled)"
        await withCheckedContinuation { continuation = $0 }
        return .init(activity: .init(title: "Updated", detail: target.name), didSucceed: true, shouldRefresh: false)
    }

    func waitForInvocation() async {
        while invocation == nil { await Task.yield() }
    }

    func complete() { continuation?.resume(); continuation = nil }

    private func unsupported() -> CodexPluginActionOutcome {
        .init(activity: .init(title: "Unsupported", detail: "Unsupported"), didSucceed: false)
    }
}
