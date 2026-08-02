import Foundation
import CodexCore

/// Stable host-facing operations behind the Plugins/Skills/Apps/MCP surfaces.
///
/// The UI owns presentation and confirmation. This type owns only protocol
/// routing, so new marketplace views do not need to depend on `Codex` directly.
public enum CodexIntegrationControlPlaneRequest: Equatable, Sendable {
    case mcpOAuthLogin(CodexSchemaMCPServerOAuthLoginParams)
    case mcpStatusList(CodexSchemaListMCPServerStatusParams)
    case mcpResourceRead(CodexSchemaMCPResourceReadParams)
    case mcpToolCall(CodexSchemaMCPServerToolCallParams)
    case mcpReload
    case configRead(CodexSchemaConfigReadParams)
    case configValueWrite(CodexSchemaConfigValueWriteParams)
    case configBatchWrite(CodexSchemaConfigBatchWriteParams)
    case appList(CodexSchemaAppsListParams)
    case appRead(CodexSchemaAppsReadParams)
    case appInstalled(CodexSchemaAppsInstalledParams)
    case marketplaceAdd(CodexSchemaMarketplaceAddParams)
    case marketplaceRemove(CodexSchemaMarketplaceRemoveParams)
    case marketplaceUpgrade(CodexSchemaMarketplaceUpgradeParams)
    case pluginList(CodexSchemaPluginListParams)
    case pluginInstalled(CodexSchemaPluginInstalledParams)
    case pluginRead(CodexSchemaPluginReadParams)
    case pluginSkillRead(CodexSchemaPluginSkillReadParams)
    case pluginShareSave(CodexSchemaPluginShareSaveParams)
    case pluginShareUpdateTargets(CodexSchemaPluginShareUpdateTargetsParams)
    case pluginShareList(CodexSchemaPluginShareListParams)
    case pluginShareCheckout(CodexSchemaPluginShareCheckoutParams)
    case pluginShareDelete(CodexSchemaPluginShareDeleteParams)
    case pluginInstall(CodexSchemaPluginInstallParams)
    case pluginUninstall(CodexSchemaPluginUninstallParams)
    case skillsList(CodexSchemaSkillsListParams)
    case skillsConfigWrite(CodexSchemaSkillsConfigWriteParams)
    case skillsExtraRootsSet(CodexSchemaSkillsExtraRootsSetParams)
    case fsRemove(CodexSchemaFSRemoveParams)
    case hooksList(CodexSchemaHooksListParams)

    public var surface: CodexIntegrationControlPlaneSurface {
        switch self {
        case .mcpOAuthLogin, .mcpStatusList, .mcpResourceRead, .mcpToolCall, .mcpReload:
            .mcp
        case .configRead, .configValueWrite, .configBatchWrite:
            .configuration
        case .appList, .appRead, .appInstalled:
            .apps
        case .marketplaceAdd, .marketplaceRemove, .marketplaceUpgrade,
             .pluginList, .pluginInstalled, .pluginRead, .pluginSkillRead,
             .pluginShareSave, .pluginShareUpdateTargets, .pluginShareList,
             .pluginShareCheckout, .pluginShareDelete, .pluginInstall, .pluginUninstall:
            .plugins
        case .skillsList, .skillsConfigWrite, .skillsExtraRootsSet, .fsRemove:
            .skills
        case .hooksList:
            .hooks
        }
    }

    public var operationID: String {
        switch self {
        case .mcpOAuthLogin: "mcpServer/oauth/login"
        case .mcpStatusList: "mcpServerStatus/list"
        case .mcpResourceRead: "mcpServer/resource/read"
        case .mcpToolCall: "mcpServer/tool/call"
        case .mcpReload: "config/mcpServer/reload"
        case .configRead: "config/read"
        case .configValueWrite: "config/value/write"
        case .configBatchWrite: "config/batchWrite"
        case .appList: "app/list"
        case .appRead: "app/read"
        case .appInstalled: "app/installed"
        case .marketplaceAdd: "marketplace/add"
        case .marketplaceRemove: "marketplace/remove"
        case .marketplaceUpgrade: "marketplace/upgrade"
        case .pluginList: "plugin/list"
        case .pluginInstalled: "plugin/installed"
        case .pluginRead: "plugin/read"
        case .pluginSkillRead: "plugin/skill/read"
        case .pluginShareSave: "plugin/share/save"
        case .pluginShareUpdateTargets: "plugin/share/updateTargets"
        case .pluginShareList: "plugin/share/list"
        case .pluginShareCheckout: "plugin/share/checkout"
        case .pluginShareDelete: "plugin/share/delete"
        case .pluginInstall: "plugin/install"
        case .pluginUninstall: "plugin/uninstall"
        case .skillsList: "skills/list"
        case .skillsConfigWrite: "skills/config/write"
        case .skillsExtraRootsSet: "skills/extraRoots/set"
        case .fsRemove: "fs/remove"
        case .hooksList: "hooks/list"
        }
    }

    /// A presentation hint. Hosts should confirm these operations before calling
    /// `perform`; app-server remains the final policy/permission authority.
    public var permissionBoundary: CodexIntegrationPermissionBoundary? {
        switch self {
        case .mcpOAuthLogin: .externalAuthentication
        case .mcpResourceRead: .externalResourceRead
        case .mcpToolCall: .externalToolExecution
        case .configValueWrite, .configBatchWrite, .mcpReload: .configurationWrite
        case .marketplaceAdd, .marketplaceRemove, .marketplaceUpgrade,
             .pluginInstall, .pluginUninstall, .pluginShareSave,
             .pluginShareUpdateTargets, .pluginShareCheckout, .pluginShareDelete:
            .pluginMutation
        case .skillsConfigWrite, .skillsExtraRootsSet, .fsRemove: .skillConfigurationWrite
        default: nil
        }
    }
}

public enum CodexIntegrationControlPlaneSurface: String, CaseIterable, Equatable, Hashable, Sendable {
    case mcp
    case configuration
    case apps
    case plugins
    case skills
    case hooks
}

public enum CodexIntegrationPermissionBoundary: String, Equatable, Sendable {
    case externalAuthentication
    case externalResourceRead
    case externalToolExecution
    case configurationWrite
    case pluginMutation
    case skillConfigurationWrite
}

public enum CodexIntegrationControlPlanePhase: Equatable, Sendable {
    case idle
    case loading(CodexIntegrationPermissionBoundary?)
    case loaded
    case failed(String)
    case permissionRequired(CodexIntegrationPermissionBoundary, message: String)
}

public protocol CodexIntegrationControlPlaneProvider: Sendable {
    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue
}

public struct CodexAppServerIntegrationControlPlaneProvider: CodexIntegrationControlPlaneProvider {
    private let codex: Codex

    public init(codex: Codex) {
        self.codex = codex
    }

    public func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        switch request {
        case .mcpOAuthLogin(let params): try await encode(codex.mcpServerOAuthLogin(params))
        case .mcpStatusList(let params): try await encode(codex.mcpServerStatusList(params))
        case .mcpResourceRead(let params): try await encode(codex.mcpServerResourceRead(params))
        case .mcpToolCall(let params): try await encode(codex.mcpServerToolCall(params))
        case .mcpReload: try await codex.configMCPServerReload()
        case .configRead(let params): try await encode(codex.configRead(params))
        case .configValueWrite(let params): try await codex.configValueWrite(params)
        case .configBatchWrite(let params): try await codex.configBatchWrite(params)
        case .appList(let params): try await encode(codex.appList(params))
        case .appRead(let params): try await encode(codex.appRead(params))
        case .appInstalled(let params): try await encode(codex.appInstalled(params))
        case .marketplaceAdd(let params): try await encode(codex.marketplaceAdd(params))
        case .marketplaceRemove(let params): try await encode(codex.marketplaceRemove(params))
        case .marketplaceUpgrade(let params): try await encode(codex.marketplaceUpgrade(params))
        case .pluginList(let params): try await encode(codex.pluginList(params))
        case .pluginInstalled(let params): try await encode(codex.pluginInstalled(params))
        case .pluginRead(let params): try await encode(codex.pluginRead(params))
        case .pluginSkillRead(let params): try await encode(codex.pluginSkillRead(params))
        case .pluginShareSave(let params): try await encode(codex.pluginShareSave(params))
        case .pluginShareUpdateTargets(let params): try await encode(codex.pluginShareUpdateTargets(params))
        case .pluginShareList(let params): try await encode(codex.pluginShareList(params))
        case .pluginShareCheckout(let params): try await encode(codex.pluginShareCheckout(params))
        case .pluginShareDelete(let params): try await encode(codex.pluginShareDelete(params))
        case .pluginInstall(let params): try await encode(codex.pluginInstall(params))
        case .pluginUninstall(let params): try await encode(codex.pluginUninstall(params))
        case .skillsList(let params): try await encode(codex.skillsList(params))
        case .skillsConfigWrite(let params): try await encode(codex.skillsConfigWrite(params))
        case .skillsExtraRootsSet(let params): try await codex.skillsExtraRootsSet(params)
        case .fsRemove(let params): try await encode(codex.remove(params))
        case .hooksList(let params): try await encode(codex.hooksList(params))
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> CodexJSONValue {
        try CodexJSONValue(encoding: value)
    }
}

public struct CodexUnsupportedIntegrationControlPlaneProvider: CodexIntegrationControlPlaneProvider {
    public init() {}

    public func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        throw CodexIntegrationControlPlaneError("\(request.surface.rawValue.capitalized) requires an active Codex connection.")
    }
}

public struct CodexIntegrationControlPlaneError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Operation state and last successful responses for host/UI coordination.
public struct CodexIntegrationControlPlaneSession: Equatable, Sendable {
    public private(set) var phases: [CodexIntegrationControlPlaneSurface: CodexIntegrationControlPlanePhase]
    public private(set) var responses: [String: CodexJSONValue]

    public init(
        phases: [CodexIntegrationControlPlaneSurface: CodexIntegrationControlPlanePhase] = [:],
        responses: [String: CodexJSONValue] = [:]
    ) {
        self.phases = phases
        self.responses = responses
    }

    public func phase(for surface: CodexIntegrationControlPlaneSurface) -> CodexIntegrationControlPlanePhase {
        phases[surface] ?? .idle
    }

    public func response(for request: CodexIntegrationControlPlaneRequest) -> CodexJSONValue? {
        responses[request.operationID]
    }

    public mutating func reset() {
        phases = [:]
        responses = [:]
    }

    public mutating func requireConnection(for surface: CodexIntegrationControlPlaneSurface, message: String) {
        phases[surface] = .failed(message)
    }

    public mutating func requirePermission(
        _ boundary: CodexIntegrationPermissionBoundary,
        for surface: CodexIntegrationControlPlaneSurface,
        message: String
    ) {
        phases[surface] = .permissionRequired(boundary, message: message)
    }

    @discardableResult
    public mutating func perform(
        _ request: CodexIntegrationControlPlaneRequest,
        provider: any CodexIntegrationControlPlaneProvider,
        errorMessage: (Error) -> String
    ) async -> CodexIntegrationCatalogActivity {
        phases[request.surface] = .loading(request.permissionBoundary)
        do {
            let response = try await provider.perform(request)
            responses[request.operationID] = response
            phases[request.surface] = .loaded
            return .init(title: "Updated \(request.surface.rawValue)", detail: "App-server request completed")
        } catch {
            let message = errorMessage(error)
            phases[request.surface] = .failed(message)
            return .init(title: "\(request.surface.rawValue.capitalized) unavailable", detail: message)
        }
    }
}

/// Implements the action seam consumed by the current plugin route. Richer UI
/// can use `CodexIntegrationControlPlaneSession` directly for detail/share flows.
public struct CodexIntegrationControlPlanePluginCatalogActionProvider: CodexPluginCatalogActionProvider {
    private let provider: any CodexIntegrationControlPlaneProvider

    public init(provider: any CodexIntegrationControlPlaneProvider) {
        self.provider = provider
    }

    public init(codex: Codex) {
        self.init(provider: CodexAppServerIntegrationControlPlaneProvider(codex: codex))
    }

    public func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        await mutation(
            .pluginInstall(.init(
                marketplacePath: target.marketplacePath.map(Self.path),
                pluginName: target.name,
                remoteMarketplaceName: target.marketplacePath == nil ? target.marketplaceName : nil
            )),
            successTitle: "Installed \(target.displayName)"
        )
    }

    public func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        await mutation(.pluginUninstall(.init(pluginID: target.id)), successTitle: "Uninstalled \(target.displayName)")
    }

    public func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        await mutation(
            .configValueWrite(.init(
                keyPath: "plugins.\(target.name).enabled",
                mergeStrategy: .replace,
                value: .bool(enabled)
            )),
            successTitle: "Updated \(target.displayName)"
        )
    }

    public func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        await mutation(
            .skillsConfigWrite(.init(enabled: enabled, name: target.name, path: Self.path(target.path))),
            successTitle: "Updated \(target.displayName)"
        )
    }

    public func uninstallSkill(_ target: CodexSkillActionTarget) async -> CodexPluginActionOutcome {
        guard target.scope == "user" else {
            return .init(
                activity: .init(
                    title: "Can’t uninstall \(target.displayName)",
                    detail: "Only personal skills can be uninstalled from this surface."
                ),
                didSucceed: false
            )
        }
        return await mutation(
            .fsRemove(CodexPluginProtocolMutation.skillUninstallParams(for: target)),
            successTitle: "Uninstalled \(target.displayName)"
        )
    }

    private func mutation(
        _ request: CodexIntegrationControlPlaneRequest,
        successTitle: String
    ) async -> CodexPluginActionOutcome {
        do {
            _ = try await provider.perform(request)
            return .init(
                activity: .init(title: successTitle, detail: "App-server request completed"),
                shouldRefresh: true
            )
        } catch {
            return .init(activity: .init(
                title: "Plugin action failed",
                detail: error.localizedDescription
            ))
        }
    }

    private static func path(_ value: String) -> CodexSchemaAbsolutePathBuf {
        CodexSchemaAbsolutePathBuf(.string(value))
    }
}
