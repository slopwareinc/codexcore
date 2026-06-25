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
    public private(set) var skills: [CodexSkillSummary]
    public private(set) var isLoadingSkills: Bool
    public private(set) var skillErrorMessage: String?

    public init(
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        mcpErrorMessage: String? = nil,
        plugins: [CodexPluginSummary] = [],
        isLoadingPlugins: Bool = false,
        pluginErrorMessage: String? = nil,
        pluginLoadErrors: [String] = [],
        skills: [CodexSkillSummary] = [],
        isLoadingSkills: Bool = false,
        skillErrorMessage: String? = nil
    ) {
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.mcpErrorMessage = mcpErrorMessage
        self.plugins = plugins
        self.isLoadingPlugins = isLoadingPlugins
        self.pluginErrorMessage = pluginErrorMessage
        self.pluginLoadErrors = pluginLoadErrors
        self.skills = skills
        self.isLoadingSkills = isLoadingSkills
        self.skillErrorMessage = skillErrorMessage
    }

    public mutating func reset() {
        mcpServers = []
        isLoadingMCPServers = false
        mcpErrorMessage = nil
        plugins = []
        isLoadingPlugins = false
        pluginErrorMessage = nil
        pluginLoadErrors = []
        skills = []
        isLoadingSkills = false
        skillErrorMessage = nil
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
            let raw = try CodexJSONValue(encoding: await codex.mcpServerStatusList(threadId: threadID, detail: .full, limit: 100))
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

    public mutating func applyMCPStartupStatus(_ update: CodexMCPServerStartupStatus) {
        if let index = mcpServers.firstIndex(where: { $0.name == update.name }) {
            mcpServers[index] = mcpServers[index].applyingStartupStatus(update.status, error: update.error)
        } else {
            mcpServers.append(CodexMCPServerStatus(name: update.name, startupStatus: update.status, error: update.error))
        }
    }

    public mutating func requirePluginConnection(message: String) {
        plugins = []
        pluginLoadErrors = []
        isLoadingPlugins = false
        pluginErrorMessage = message
        skills = []
        isLoadingSkills = false
        skillErrorMessage = message
    }

    public mutating func beginPluginRefresh() {
        isLoadingPlugins = true
        pluginErrorMessage = nil
    }

    public mutating func beginSkillRefresh() {
        isLoadingSkills = true
        skillErrorMessage = nil
    }

    @discardableResult
    public mutating func applyPluginResponse(_ raw: CodexJSONValue) -> CodexIntegrationCatalogActivity {
        plugins = CodexPluginSummary.plugins(from: raw)
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
            return applyPluginResponse(try CodexJSONValue(encoding: await codex.pluginList(cwds: cwds)))
        } catch {
            return failPluginRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failPluginRefresh(message: String) -> CodexIntegrationCatalogActivity {
        plugins = []
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
        using codex: Codex,
        cwds: [String],
        forceReload: Bool = false,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        beginSkillRefresh()
        do {
            return applySkillResponse(try CodexJSONValue(encoding: await codex.skillsList(cwds: cwds, forceReload: forceReload)))
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
}
