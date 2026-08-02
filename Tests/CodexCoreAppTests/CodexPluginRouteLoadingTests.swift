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
}

@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}
