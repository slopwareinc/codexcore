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
    public private(set) var marketplaces: [CodexMarketplaceSummary]
    public private(set) var isLoadingPlugins: Bool
    public private(set) var pluginErrorMessage: String?
    public private(set) var pluginLoadErrors: [String]
    public private(set) var pluginReadDetails: [String: CodexPluginReadDetail]
    public private(set) var loadingPluginReadIDs: Set<String>
    public private(set) var pluginReadErrors: [String: String]
    public private(set) var apps: [CodexAppSummary]
    public private(set) var isLoadingApps: Bool
    public private(set) var appErrorMessage: String?
    public private(set) var skills: [CodexSkillSummary]
    public private(set) var isLoadingSkills: Bool
    public private(set) var skillErrorMessage: String?
    public private(set) var skillLoadErrors: [String]

    public init(
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        mcpErrorMessage: String? = nil,
        plugins: [CodexPluginSummary] = [],
        marketplaces: [CodexMarketplaceSummary] = [],
        isLoadingPlugins: Bool = false,
        pluginErrorMessage: String? = nil,
        pluginLoadErrors: [String] = [],
        pluginReadDetails: [String: CodexPluginReadDetail] = [:],
        loadingPluginReadIDs: Set<String> = [],
        pluginReadErrors: [String: String] = [:],
        apps: [CodexAppSummary] = [],
        isLoadingApps: Bool = false,
        appErrorMessage: String? = nil,
        skills: [CodexSkillSummary] = [],
        isLoadingSkills: Bool = false,
        skillErrorMessage: String? = nil,
        skillLoadErrors: [String] = []
    ) {
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.mcpErrorMessage = mcpErrorMessage
        self.plugins = plugins
        self.marketplaces = marketplaces
        self.isLoadingPlugins = isLoadingPlugins
        self.pluginErrorMessage = pluginErrorMessage
        self.pluginLoadErrors = pluginLoadErrors
        self.pluginReadDetails = pluginReadDetails
        self.loadingPluginReadIDs = loadingPluginReadIDs
        self.pluginReadErrors = pluginReadErrors
        self.apps = apps
        self.isLoadingApps = isLoadingApps
        self.appErrorMessage = appErrorMessage
        self.skills = skills
        self.isLoadingSkills = isLoadingSkills
        self.skillErrorMessage = skillErrorMessage
        self.skillLoadErrors = skillLoadErrors
    }

    public mutating func reset() {
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = nil
        plugins = []
        marketplaces = []
        isLoadingPlugins = false
        pluginErrorMessage = nil
        pluginLoadErrors = []
        pluginReadDetails = [:]
        loadingPluginReadIDs = []
        pluginReadErrors = [:]
        apps = []
        isLoadingApps = false
        appErrorMessage = nil
        skills = []
        isLoadingSkills = false
        skillErrorMessage = nil
        skillLoadErrors = []
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
        using codex: Codex,
        threadID: String?,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginMCPRefresh()
        do {
            let response = try await codex.perform(CodexRequest.mcpServerStatusList(.init(
                detail: .full,
                limit: 100,
                threadID: threadID
            )))
            let raw = try CodexJSONValue(encoding: response)
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

    public mutating func requirePluginConnection(message: String) {
        plugins = []
        marketplaces = []
        pluginLoadErrors = []
        pluginReadDetails = [:]
        loadingPluginReadIDs = []
        pluginReadErrors = [:]
        isLoadingPlugins = false
        pluginErrorMessage = message
        apps = []
        isLoadingApps = false
        appErrorMessage = message
        skills = []
        isLoadingSkills = false
        skillErrorMessage = message
        skillLoadErrors = []
    }

    public mutating func beginPluginRefresh() {
        isLoadingPlugins = true
        pluginErrorMessage = nil
    }

    public mutating func beginAppRefresh() {
        isLoadingApps = true
        appErrorMessage = nil
    }

    public mutating func beginSkillRefresh() {
        isLoadingSkills = true
        skillErrorMessage = nil
        skillLoadErrors = []
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

    public mutating func beginPluginRead(id: String) {
        loadingPluginReadIDs.insert(id)
        pluginReadErrors.removeValue(forKey: id)
    }

    public mutating func applyPluginRead(id: String, response: CodexSchemaPluginReadResponse) {
        pluginReadDetails[id] = CodexPluginReadDetail(id: id, detail: response.plugin)
        loadingPluginReadIDs.remove(id)
        pluginReadErrors.removeValue(forKey: id)
    }

    public mutating func failPluginRead(id: String, message: String) {
        loadingPluginReadIDs.remove(id)
        pluginReadErrors[id] = message
    }

    @discardableResult
    public mutating func applyPluginResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        plugins = CodexPluginSummary.plugins(from: raw)
        let availableIDs = Set(plugins.map(\.id))
        pluginReadDetails = pluginReadDetails.filter { availableIDs.contains($0.key) }
        pluginReadErrors = pluginReadErrors.filter { availableIDs.contains($0.key) }
        loadingPluginReadIDs.formIntersection(availableIDs)
        marketplaces = CodexMarketplaceSummary.marketplaces(from: raw)
        pluginLoadErrors = CodexPluginSummary.loadErrorMessages(from: raw)
        isLoadingPlugins = false
        return CodexIntegrationCatalogActivity(title: "Loaded plugins", detail: "\(plugins.count) available")
    }

    @discardableResult
    public mutating func refreshPlugins(
        using codex: Codex,
        cwds: [String],
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginPluginRefresh()
        do {
            let response = try await codex.perform(CodexRequest.pluginList(.init(
                cwds: cwds.isEmpty ? nil : cwds.map { CodexAppServerSchemaValue(.string($0)) }
            )))
            return applyPluginResponse(try CodexJSONValue(encoding: response))
        } catch {
            return failPluginRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func applyAppResponses(
        catalog: [CodexSchemaAppInfo],
        installed: [CodexSchemaInstalledApp]
    ) -> CodexIntegrationCatalogActivity {
        apps = CodexAppSummary.join(catalog: catalog, installed: installed)
        isLoadingApps = false
        appErrorMessage = nil
        return CodexIntegrationCatalogActivity(title: "Loaded apps", detail: "\(apps.count) available")
    }

    @discardableResult
    public mutating func refreshApps(
        using codex: Codex,
        threadID: String?,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginAppRefresh()
        do {
            var catalog: [CodexSchemaAppInfo] = []
            var cursor: String?
            var observedCursors: Set<String> = []
            repeat {
                let response = try await codex.perform(CodexRequest.appList(.init(
                    cursor: cursor,
                    limit: 100,
                    threadID: threadID
                )))
                catalog.append(contentsOf: response.data)
                cursor = response.nextCursor
                if let cursor, !observedCursors.insert(cursor).inserted {
                    throw CodexAppInventoryError.repeatedCursor(cursor)
                }
            } while cursor != nil

            let installed = try await codex.perform(CodexRequest.appInstalled(.init(
                threadID: threadID
            )))
            return applyAppResponses(catalog: catalog, installed: installed.apps)
        } catch {
            return failAppRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failAppRefresh(message: String) -> CodexIntegrationCatalogActivity {
        apps = []
        isLoadingApps = false
        appErrorMessage = message
        return CodexIntegrationCatalogActivity(title: "App list unavailable", detail: message)
    }

    @discardableResult
    public mutating func failPluginRefresh(message: String) -> CodexIntegrationCatalogActivity {
        plugins = []
        marketplaces = []
        pluginLoadErrors = []
        pluginReadDetails = [:]
        loadingPluginReadIDs = []
        pluginReadErrors = [:]
        isLoadingPlugins = false
        pluginErrorMessage = message
        return CodexIntegrationCatalogActivity(title: "Plugin list unavailable", detail: message)
    }

    @discardableResult
    public mutating func applySkillResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        skills = CodexSkillSummary.skills(from: raw)
        skillLoadErrors = CodexSkillSummary.loadErrorMessages(from: raw)
        isLoadingSkills = false
        skillErrorMessage = nil
        return CodexIntegrationCatalogActivity(title: "Loaded skills", detail: "\(skills.count) available")
    }

    @discardableResult
    public mutating func refreshSkills(
        using codex: Codex,
        cwds: [String],
        forceReload: Bool = false,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginSkillRefresh()
        do {
            let response = try await codex.perform(CodexRequest.skillsList(.init(
                cwds: cwds.isEmpty ? nil : cwds,
                forceReload: forceReload ? true : nil
            )))
            return applySkillResponse(try CodexJSONValue(encoding: response))
        } catch {
            return failSkillRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failSkillRefresh(message: String) -> CodexIntegrationCatalogActivity {
        skills = []
        isLoadingSkills = false
        skillErrorMessage = message
        skillLoadErrors = []
        return CodexIntegrationCatalogActivity(title: "Skill list unavailable", detail: message)
    }
}

private enum CodexAppInventoryError: LocalizedError {
    case repeatedCursor(String)

    var errorDescription: String? {
        switch self {
        case .repeatedCursor(let cursor): "App list returned repeated cursor \(cursor)."
        }
    }
}
