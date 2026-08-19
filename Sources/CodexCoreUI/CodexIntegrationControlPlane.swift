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
    func observeMCPServerOAuthLogin(
        name: String,
        threadID: String?
    ) async throws -> AsyncThrowingStream<CodexSchemaMCPServerOAuthLoginCompletedNotification, Error>
    func observeMCPServerStartupStatus(
        threadID: String?
    ) async throws -> AsyncStream<CodexSchemaMCPServerStatusUpdatedNotification>
}

public extension CodexIntegrationControlPlaneProvider {
    func observeMCPServerOAuthLogin(
        name: String,
        threadID: String?
    ) async throws -> AsyncThrowingStream<CodexSchemaMCPServerOAuthLoginCompletedNotification, Error> {
        throw CodexIntegrationControlPlaneError("MCP OAuth completion observation is unavailable.")
    }

    func observeMCPServerStartupStatus(
        threadID: String?
    ) async throws -> AsyncStream<CodexSchemaMCPServerStatusUpdatedNotification> {
        throw CodexIntegrationControlPlaneError("MCP startup observation is unavailable.")
    }
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

    public func observeMCPServerOAuthLogin(
        name: String,
        threadID: String?
    ) async throws -> AsyncThrowingStream<CodexSchemaMCPServerOAuthLoginCompletedNotification, Error> {
        try await codex.observeMCPServerOAuthLogin(name: name, threadID: threadID)
    }

    public func observeMCPServerStartupStatus(
        threadID: String?
    ) async throws -> AsyncStream<CodexSchemaMCPServerStatusUpdatedNotification> {
        let scope = StateObservationScope.global(fields: .mcpServerStartup)
        let observation = await codex.session.observe(scope: scope)
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                var revisions: [CanonicalMCPServerStartupKey: StateRevision] = [:]
                func publish(_ snapshot: CanonicalStateSnapshot) {
                    for (key, value) in snapshot.mcpServerStartupStatuses
                    where key.threadID?.rawValue == threadID && revisions[key] != value.lastChangedRevision {
                        revisions[key] = value.lastChangedRevision
                        continuation.yield(.init(
                            error: value.error,
                            failureReason: value.failureReason,
                            name: key.serverName,
                            status: value.status,
                            threadID: key.threadID?.rawValue
                        ))
                    }
                }
                publish(observation.seed)
                for await _ in observation.signals {
                    guard !Task.isCancelled else { break }
                    publish(await codex.session.canonicalSnapshot(scope: scope))
                }
                await codex.session.cancelObservation(observation.id)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
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

public enum CodexMCPAuthenticationError: LocalizedError, Equatable, Sendable {
    case insufficientScope(requiredScope: String?, upgradeURL: URL?)
    case authorizationRequired
    case tokenExpired
    case tokenRefreshFailed
    case authorizationServerMismatch
    case other(String)

    public init(message: String) {
        let normalized = message.lowercased()
        if normalized.contains("insufficient_scope") || normalized.contains("insufficientscope") {
            self = .insufficientScope(
                requiredScope: Self.field("required_scope", in: message),
                upgradeURL: Self.field("upgrade_url", in: message).flatMap(URL.init(string:))
            )
        } else if normalized.contains("authorizationrequired") || normalized.contains("authorization_required") {
            self = .authorizationRequired
        } else if normalized.contains("tokenexpired") || normalized.contains("token_expired") {
            self = .tokenExpired
        } else if normalized.contains("tokenrefreshfailed") || normalized.contains("token_refresh_failed") {
            self = .tokenRefreshFailed
        } else if normalized.contains("authorizationservermismatch") || normalized.contains("authorization_server_mismatch") {
            self = .authorizationServerMismatch
        } else {
            self = .other(message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .insufficientScope(let requiredScope, _):
            requiredScope.map { "This server requires the \($0) scope." } ?? "This login lacks a required scope."
        case .authorizationRequired: "Authorization is required."
        case .tokenExpired: "The authorization token expired. Log in again."
        case .tokenRefreshFailed: "The authorization token could not be refreshed. Log in again."
        case .authorizationServerMismatch: "The server’s authorization endpoint changed. Verify the server and log in again."
        case .other(let message): message
        }
    }

    private static func field(_ name: String, in message: String) -> String? {
        let separators = CharacterSet(charactersIn: " ,;}\n\t\"")
        guard let range = message.range(of: name, options: .caseInsensitive) else { return nil }
        let suffix = message[range.upperBound...].drop(while: { $0 == ":" || $0 == "=" || $0 == " " || $0 == "\"" })
        return suffix.components(separatedBy: separators).first?.nilIfBlank
    }
}

public enum CodexMCPProtocolMutation {
    public static func save(_ configuration: CodexMCPServerConfiguration) throws -> CodexIntegrationControlPlaneRequest {
        try validate(configuration.name)
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(configuration.name)",
            mergeStrategy: .replace,
            value: configuration.configValue
        ))
    }

    public static func setEnabled(name: String, enabled: Bool) throws -> CodexIntegrationControlPlaneRequest {
        try validate(name)
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(name).enabled",
            mergeStrategy: .replace,
            value: .bool(enabled)
        ))
    }

    public static func remove(name: String) throws -> CodexIntegrationControlPlaneRequest {
        try validate(name)
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(name)",
            mergeStrategy: .replace,
            value: .null
        ))
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }) else {
            throw CodexIntegrationControlPlaneError("Server names may contain only letters, numbers, underscores, and hyphens.")
        }
    }
}

public enum CodexHookProtocolMutation {
    public static func setEnabled(
        _ enabled: Bool,
        for hook: CodexHookSummary
    ) -> CodexIntegrationControlPlaneRequest {
        stateUpdate(hook: hook, values: ["enabled": .bool(enabled)])
    }

    public static func trust(_ hook: CodexHookSummary) throws -> CodexIntegrationControlPlaneRequest {
        guard let hash = hook.currentHash.nilIfBlank else {
            throw CodexIntegrationControlPlaneError("Hook did not report a trust hash.")
        }
        return stateUpdate(hook: hook, values: ["trusted_hash": .string(hash)])
    }

    private static func stateUpdate(
        hook: CodexHookSummary,
        values: [String: CodexJSONValue]
    ) -> CodexIntegrationControlPlaneRequest {
        .configBatchWrite(.init(
            edits: [.init(
                keyPath: "hooks.state",
                mergeStrategy: .upsert,
                value: .dictionary([hook.protocolKey: .dictionary(values)])
            )],
            reloadUserConfig: true
        ))
    }
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

    public var hooksCatalog: CodexHooksCatalog {
        responses["hooks/list"].map(CodexHooksCatalog.init(raw:)) ?? .init()
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
