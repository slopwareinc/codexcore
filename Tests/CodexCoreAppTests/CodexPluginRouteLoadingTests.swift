import Testing
import Observation
@testable import CodexCoreApp
@testable import CodexCoreUI

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

    @Test("Plugin and skill switches update immediately and roll back when disconnected")
    func catalogTogglesAreOptimisticAndRecoverFromFailure() async {
        let model = CodexCoreAppModel()
        let plugin = CodexPluginSummary(
            id: "local:github",
            protocolID: "github@local",
            name: "github",
            marketplaceName: "local",
            installed: true,
            enabled: true
        )
        let skill = CodexSkillSummary(
            name: "writer",
            path: "/tmp/skills/writer/SKILL.md",
            scope: "user",
            enabled: true
        )
        model.runtimeSession.integrationCatalogSession = CodexIntegrationCatalogSession(
            plugins: [plugin],
            skills: [skill]
        )

        model.performPluginCatalogAction(.setPluginEnabled(.init(plugin: plugin), enabled: false))
        #expect(model.runtimeSession.integrationCatalogSession.plugins[0].enabled == false)
        await drainMainActorTasks()
        #expect(model.runtimeSession.integrationCatalogSession.plugins[0].enabled == true)

        model.performPluginCatalogAction(.setSkillEnabled(.init(skill: skill), enabled: false))
        #expect(model.runtimeSession.integrationCatalogSession.skills[0].enabled == false)
        await drainMainActorTasks()
        #expect(model.runtimeSession.integrationCatalogSession.skills[0].enabled == true)
    }

    @Test("Changing plugins and skills invalidates the UI observations that drive their switches")
    func catalogTogglesPublishTheOptimisticStateToSwiftUI() {
        let model = CodexCoreAppModel()
        let plugin = CodexPluginSummary(
            id: "local:github",
            protocolID: "github@local",
            name: "github",
            marketplaceName: "local",
            installed: true,
            enabled: true
        )
        let skill = CodexSkillSummary(
            name: "writer",
            path: "/tmp/skills/writer/SKILL.md",
            scope: "user",
            enabled: true
        )
        model.runtimeSession.integrationCatalogSession = CodexIntegrationCatalogSession(
            plugins: [plugin],
            skills: [skill]
        )
        nonisolated(unsafe) var pluginInvalidationCount = 0

        withObservationTracking {
            _ = model.plugins.first?.enabled
        } onChange: {
            pluginInvalidationCount += 1
        }
        model.performPluginCatalogAction(.setPluginEnabled(.init(plugin: plugin), enabled: false))

        #expect(model.plugins.first?.enabled == false)
        #expect(pluginInvalidationCount == 1)

        nonisolated(unsafe) var skillInvalidationCount = 0
        withObservationTracking {
            _ = model.skills.first?.enabled
        } onChange: {
            skillInvalidationCount += 1
        }
        model.performPluginCatalogAction(.setSkillEnabled(.init(skill: skill), enabled: false))

        #expect(model.skills.first?.enabled == false)
        #expect(skillInvalidationCount == 1)
    }

    @Test("Catalog actions are sent once, expose pending state, and keep successful toggle state")
    func catalogActionsHaveDeterministicPendingState() async {
        let provider = GatedPluginCatalogActionProvider(outcome: .init(
            activity: .init(title: "Applied", detail: "Test provider")
        ))
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            pluginCatalogActionProvider: provider
        )
        let plugin = CodexPluginSummary(
            id: "remote:github",
            protocolID: "github@openai-curated-remote",
            name: "github",
            marketplaceName: "openai-curated-remote",
            installed: true,
            enabled: true
        )
        let skill = CodexSkillSummary(
            name: "github:triage",
            path: "/tmp/github/triage/SKILL.md",
            scope: "plugin",
            enabled: true
        )
        model.runtimeSession.integrationCatalogSession = .init(plugins: [plugin], skills: [skill])

        let pluginAction = CodexPluginRouteAction.setPluginEnabled(.init(plugin: plugin), enabled: false)
        model.performPluginCatalogAction(pluginAction)
        model.performPluginCatalogAction(pluginAction)
        #expect(model.plugins[0].enabled == false)
        #expect(model.pendingPluginActionIDs == [plugin.protocolID])
        await provider.waitForInvocationCount(1)
        #expect(await provider.invocations == [.pluginEnabled(plugin.protocolID, false)])
        await provider.completeNext()
        await drainMainActorTasks()
        #expect(model.plugins[0].enabled == false)
        #expect(model.pendingPluginActionIDs.isEmpty)

        model.performPluginCatalogAction(.setSkillEnabled(.init(skill: skill), enabled: false))
        #expect(model.skills[0].enabled == false)
        #expect(model.pendingSkillActionIDs == [skill.name])
        await provider.waitForInvocationCount(2)
        #expect(await provider.invocations.last == .skillEnabled(skill.name, false))
        await provider.completeNext()
        await drainMainActorTasks()
        #expect(model.skills[0].enabled == false)
        #expect(model.pendingSkillActionIDs.isEmpty)

        model.performPluginCatalogAction(.installPlugin(.init(plugin: plugin)))
        #expect(model.pendingPluginActionIDs == [plugin.protocolID])
        await provider.waitForInvocationCount(3)
        #expect(await provider.invocations.last == .install(plugin.protocolID))
        await provider.completeNext()
        await drainMainActorTasks()

        model.performPluginCatalogAction(.uninstallPlugin(.init(plugin: plugin)))
        await provider.waitForInvocationCount(4)
        #expect(await provider.invocations.last == .uninstall(plugin.protocolID))
        await provider.completeNext()
        await drainMainActorTasks()
        #expect(model.pendingPluginActionIDs.isEmpty)
    }

    @Test("Failed catalog toggles roll back and clear their pending state")
    func failedCatalogActionRollsBack() async {
        let provider = GatedPluginCatalogActionProvider(outcome: .init(
            activity: .init(title: "Rejected", detail: "Synthetic failure"),
            didSucceed: false
        ))
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore(),
            pluginCatalogActionProvider: provider
        )
        let plugin = CodexPluginSummary(
            id: "remote:gmail",
            protocolID: "gmail@openai-curated-remote",
            name: "gmail",
            marketplaceName: "openai-curated-remote",
            installed: true,
            enabled: true
        )
        model.runtimeSession.integrationCatalogSession = .init(plugins: [plugin])

        model.performPluginCatalogAction(.setPluginEnabled(.init(plugin: plugin), enabled: false))
        #expect(model.plugins[0].enabled == false)
        await provider.waitForInvocationCount(1)
        await provider.completeNext()
        await drainMainActorTasks()

        #expect(model.plugins[0].enabled == true)
        #expect(model.pendingPluginActionIDs.isEmpty)
    }
}

@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

private actor GatedPluginCatalogActionProvider: CodexPluginCatalogActionProvider {
    enum Invocation: Equatable {
        case install(String)
        case uninstall(String)
        case pluginEnabled(String, Bool)
        case skillEnabled(String, Bool)
        case uninstallSkill(String)
    }

    private(set) var invocations: [Invocation] = []
    private var completions: [CheckedContinuation<Void, Never>] = []
    let outcome: CodexPluginActionOutcome

    init(outcome: CodexPluginActionOutcome) {
        self.outcome = outcome
    }

    func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        await record(.install(target.id))
    }

    func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        await record(.uninstall(target.id))
    }

    func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        await record(.pluginEnabled(target.id, enabled))
    }

    func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        await record(.skillEnabled(target.name.contains(":") ? target.name : target.path, enabled))
    }

    func uninstallSkill(_ target: CodexSkillActionTarget) async -> CodexPluginActionOutcome {
        await record(.uninstallSkill(target.path))
    }

    func waitForInvocationCount(_ expected: Int) async {
        while invocations.count < expected { await Task.yield() }
    }

    func completeNext() {
        guard !completions.isEmpty else { return }
        completions.removeFirst().resume()
    }

    private func record(_ invocation: Invocation) async -> CodexPluginActionOutcome {
        invocations.append(invocation)
        await withCheckedContinuation { continuation in
            completions.append(continuation)
        }
        return outcome
    }
}
