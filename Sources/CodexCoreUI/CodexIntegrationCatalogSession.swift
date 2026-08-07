import Foundation
import CodexCore

public struct CodexIntegrationCatalogActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct CodexIntegrationCatalogSession: Equatable, Sendable {
    public private(set) var mcpServers: [CodexMCPServerStatus]
    public private(set) var isLoadingMCPServers: Bool
    public private(set) var mcpErrorMessage: String?
    public private(set) var plugins: [CodexPluginSummary]
    public private(set) var isLoadingPlugins: Bool
    public private(set) var pluginErrorMessage: String?
    public private(set) var pluginLoadErrors: [String]
    public private(set) var marketplaces: [CodexMarketplaceSummary]
    public private(set) var apps: [CodexAppSummary]
    public private(set) var isLoadingApps: Bool
    public private(set) var appErrorMessage: String?
    public private(set) var skills: [CodexSkillSummary]
    public private(set) var isLoadingSkills: Bool
    public private(set) var skillErrorMessage: String?
    public private(set) var hooksCatalog: CodexHooksCatalog
    public private(set) var isLoadingHooks: Bool
    public private(set) var hooksErrorMessage: String?

    public init(
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        mcpErrorMessage: String? = nil,
        plugins: [CodexPluginSummary] = [],
        isLoadingPlugins: Bool = false,
        pluginErrorMessage: String? = nil,
        pluginLoadErrors: [String] = [],
        marketplaces: [CodexMarketplaceSummary] = [],
        apps: [CodexAppSummary] = [],
        isLoadingApps: Bool = false,
        appErrorMessage: String? = nil,
        skills: [CodexSkillSummary] = [],
        isLoadingSkills: Bool = false,
        skillErrorMessage: String? = nil,
        hooksCatalog: CodexHooksCatalog = .init(),
        isLoadingHooks: Bool = false,
        hooksErrorMessage: String? = nil
    ) {
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.mcpErrorMessage = mcpErrorMessage
        self.plugins = plugins
        self.isLoadingPlugins = isLoadingPlugins
        self.pluginErrorMessage = pluginErrorMessage
        self.pluginLoadErrors = pluginLoadErrors
        self.marketplaces = marketplaces
        self.apps = apps
        self.isLoadingApps = isLoadingApps
        self.appErrorMessage = appErrorMessage
        self.skills = skills
        self.isLoadingSkills = isLoadingSkills
        self.skillErrorMessage = skillErrorMessage
        self.hooksCatalog = hooksCatalog
        self.isLoadingHooks = isLoadingHooks
        self.hooksErrorMessage = hooksErrorMessage
    }

    public mutating func reset() {
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = nil
        plugins = []
        isLoadingPlugins = false
        pluginErrorMessage = nil
        pluginLoadErrors = []
        marketplaces = []
        apps = []
        isLoadingApps = false
        appErrorMessage = nil
        skills = []
        isLoadingSkills = false
        skillErrorMessage = nil
        hooksCatalog = .init()
        isLoadingHooks = false
        hooksErrorMessage = nil
    }

    public mutating func requireMCPConnection(message: String) {
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = message
    }

    public mutating func beginMCPRefresh() {
        isLoadingMCPServers = true
        mcpErrorMessage = nil
    }

    @discardableResult
    public mutating func applyMCPResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        mcpServers = CodexMCPServerStatus.statuses(from: raw)
        isLoadingMCPServers = false
        return CodexIntegrationCatalogActivity(title: "Loaded MCP servers", detail: "\(mcpServers.count) configured")
    }

    @discardableResult
    public mutating func refreshMCPServers(
        using provider: any CodexIntegrationControlPlaneProvider,
        threadID: String?,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginMCPRefresh()
        do {
            let raw = try await provider.perform(.mcpStatusList(.init(
                detail: .full,
                limit: 100,
                threadID: threadID
            )))
            return applyMCPResponse(raw)
        } catch {
            return failMCPRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failMCPRefresh(message: String) -> CodexIntegrationCatalogActivity {
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = message
        return CodexIntegrationCatalogActivity(title: "MCP status unavailable", detail: message)
    }

    @discardableResult
    public mutating func applyMCPStartupStatus(
        _ notification: CodexSchemaMCPServerStatusUpdatedNotification
    ) -> Bool {
        guard let index = mcpServers.firstIndex(where: { $0.name == notification.name }) else { return false }
        mcpServers[index] = mcpServers[index].applyingStartupStatus(
            notification.status,
            error: notification.error,
            failureReason: notification.failureReason
        )
        return true
    }

    @discardableResult
    public mutating func setMCPEnabledOptimistically(name: String, enabled: Bool) -> Bool? {
        guard let index = mcpServers.firstIndex(where: { $0.name == name }) else { return nil }
        let previous = mcpServers[index].enabled
        mcpServers[index].enabled = enabled
        return previous
    }

    @discardableResult
    public mutating func performMCPMutation(
        _ request: CodexIntegrationControlPlaneRequest,
        using provider: any CodexIntegrationControlPlaneProvider,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        do {
            _ = try await provider.perform(request)
            _ = try await provider.perform(.mcpReload)
            return .init(title: "Updated MCP servers", detail: "Configuration reloaded")
        } catch {
            return .init(title: "MCP update failed", detail: errorMessage(error))
        }
    }

    public mutating func requirePluginConnection(message: String) {
        plugins = []
        pluginLoadErrors = []
        marketplaces = []
        isLoadingPlugins = false
        pluginErrorMessage = message
        apps = []
        isLoadingApps = false
        appErrorMessage = message
        skills = []
        isLoadingSkills = false
        skillErrorMessage = message
    }

    public mutating func beginPluginRefresh() {
        isLoadingPlugins = true
        pluginErrorMessage = nil
    }

    public mutating func beginAppRefresh() {
        isLoadingApps = true
        appErrorMessage = nil
    }

    @discardableResult
    public mutating func applyAppResponses(
        list: CodexJSONValue?,
        installed: CodexJSONValue?
    ) -> CodexIntegrationCatalogActivity {
        apps = CodexAppSummary.apps(listResponse: list, installedResponse: installed)
        isLoadingApps = false
        appErrorMessage = nil
        return .init(title: "Loaded apps", detail: "\(apps.count) installed")
    }

    @discardableResult
    public mutating func setAppEnabledOptimistically(id: String, enabled: Bool) -> Bool? {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return nil }
        let previous = apps[index].enabled
        apps[index].enabled = enabled
        return previous
    }

    public mutating func beginSkillRefresh() {
        isLoadingSkills = true
        skillErrorMessage = nil
    }

    @discardableResult
    public mutating func setPluginEnabledOptimistically(id: String, enabled: Bool) -> Bool? {
        guard let index = plugins.firstIndex(where: { $0.protocolID == id }) else { return nil }
        let previous = plugins[index].enabled
        plugins[index].enabled = enabled
        return previous
    }

    @discardableResult
    public mutating func setSkillEnabledOptimistically(path: String, enabled: Bool) -> Bool? {
        guard let index = skills.firstIndex(where: { $0.path == path }) else { return nil }
        let previous = skills[index].enabled
        skills[index].enabled = enabled
        return previous
    }

    @discardableResult
    public mutating func applyPluginResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        plugins = CodexPluginSummary.plugins(from: raw)
        marketplaces = CodexMarketplaceSummary.summaries(from: raw)
        pluginLoadErrors = CodexPluginSummary.loadErrorMessages(from: raw)
        isLoadingPlugins = false
        return CodexIntegrationCatalogActivity(title: "Loaded plugins", detail: "\(plugins.count) available")
    }

    @discardableResult
    public mutating func refreshPlugins(
        using provider: any CodexIntegrationControlPlaneProvider,
        cwds: [String],
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginPluginRefresh()
        do {
            let response = try await provider.perform(.pluginList(.init(
                cwds: cwds.isEmpty ? nil : cwds.map { CodexAppServerSchemaValue(.string($0)) }
            )))
            return applyPluginResponse(response)
        } catch {
            return failPluginRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failPluginRefresh(message: String) -> CodexIntegrationCatalogActivity {
        plugins = []
        marketplaces = []
        pluginLoadErrors = []
        isLoadingPlugins = false
        pluginErrorMessage = message
        return CodexIntegrationCatalogActivity(title: "Plugin list unavailable", detail: message)
    }

    @discardableResult
    public mutating func applySkillResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        skills = CodexSkillSummary.skills(from: raw)
        isLoadingSkills = false
        skillErrorMessage = nil
        return CodexIntegrationCatalogActivity(title: "Loaded skills", detail: "\(skills.count) available")
    }

    @discardableResult
    public mutating func refreshSkills(
        using provider: any CodexIntegrationControlPlaneProvider,
        cwds: [String],
        forceReload: Bool = false,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginSkillRefresh()
        do {
            let response = try await provider.perform(.skillsList(.init(
                cwds: cwds.isEmpty ? nil : cwds,
                forceReload: forceReload ? true : nil
            )))
            return applySkillResponse(response)
        } catch {
            return failSkillRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failSkillRefresh(message: String) -> CodexIntegrationCatalogActivity {
        skills = []
        isLoadingSkills = false
        skillErrorMessage = message
        return CodexIntegrationCatalogActivity(title: "Skill list unavailable", detail: message)
    }

    public mutating func beginHooksRefresh() {
        isLoadingHooks = true
        hooksErrorMessage = nil
    }

    @discardableResult
    public mutating func applyHooksResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        hooksCatalog = CodexHooksCatalog(raw: raw)
        isLoadingHooks = false
        hooksErrorMessage = nil
        return .init(title: "Loaded hooks", detail: "\(hooksCatalog.hooks.count) configured")
    }

    @discardableResult
    public mutating func refreshHooks(
        using provider: any CodexIntegrationControlPlaneProvider,
        cwds: [String],
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginHooksRefresh()
        do {
            return applyHooksResponse(try await provider.perform(.hooksList(.init(cwds: cwds.isEmpty ? nil : cwds))))
        } catch {
            isLoadingHooks = false
            hooksErrorMessage = errorMessage(error)
            return .init(title: "Hooks unavailable", detail: errorMessage(error))
        }
    }
}
