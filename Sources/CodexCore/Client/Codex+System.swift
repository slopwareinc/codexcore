import Foundation

extension Codex {
    public func mcpServerOAuthLogin(
        _ params: CodexSchemaMCPServerOAuthLoginParams
    ) async throws -> CodexSchemaMCPServerOAuthLoginResponse {
        try await perform(CodexRequest.mcpServerOAuthLogin(params))
    }

    public func mcpServerStatusList(
        _ params: CodexSchemaListMCPServerStatusParams
    ) async throws -> CodexSchemaListMCPServerStatusResponse {
        try await perform(CodexRequest.mcpServerStatusList(params))
    }

    public func mcpServerResourceRead(
        _ params: CodexSchemaMCPResourceReadParams
    ) async throws -> CodexSchemaMCPResourceReadResponse {
        try await perform(CodexRequest.mcpServerResourceRead(params))
    }

    public func mcpServerToolCall(
        _ params: CodexSchemaMCPServerToolCallParams
    ) async throws -> CodexSchemaMCPServerToolCallResponse {
        try await perform(CodexRequest.mcpServerToolCall(params))
    }

    @discardableResult
    public func configMCPServerReload() async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await perform(CodexRequest.configMCPServerReload()))
    }

    public func configRead(
        _ params: CodexSchemaConfigReadParams
    ) async throws -> CodexSchemaConfigReadResponse {
        try await perform(CodexRequest.configRead(params))
    }

    @discardableResult
    public func configValueWrite(
        _ params: CodexSchemaConfigValueWriteParams
    ) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await perform(CodexRequest.configValueWrite(params)))
    }

    @discardableResult
    public func configBatchWrite(
        _ params: CodexSchemaConfigBatchWriteParams
    ) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await perform(CodexRequest.configBatchWrite(params)))
    }

    public func skillsConfigWrite(
        _ params: CodexSchemaSkillsConfigWriteParams
    ) async throws -> CodexSchemaSkillsConfigWriteResponse {
        try await perform(CodexRequest.skillsConfigWrite(params))
    }

    public func skillsList(
        _ params: CodexSchemaSkillsListParams
    ) async throws -> CodexSchemaSkillsListResponse {
        try await perform(CodexRequest.skillsList(params))
    }

    @discardableResult
    public func skillsExtraRootsSet(
        _ params: CodexSchemaSkillsExtraRootsSetParams
    ) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await perform(CodexRequest.skillsExtraRootsSet(params)))
    }

    public func hooksList(
        _ params: CodexSchemaHooksListParams
    ) async throws -> CodexSchemaHooksListResponse {
        try await perform(CodexRequest.hooksList(params))
    }

    public func appList(
        _ params: CodexSchemaAppsListParams
    ) async throws -> CodexSchemaAppsListResponse {
        try await perform(CodexRequest.appList(params))
    }

    public func appRead(
        _ params: CodexSchemaAppsReadParams
    ) async throws -> CodexSchemaAppsReadResponse {
        try await perform(CodexRequest.appRead(params))
    }

    public func appInstalled(
        _ params: CodexSchemaAppsInstalledParams
    ) async throws -> CodexSchemaAppsInstalledResponse {
        try await perform(CodexRequest.appInstalled(params))
    }

    public func pluginList(
        _ params: CodexSchemaPluginListParams
    ) async throws -> CodexSchemaPluginListResponse {
        try await perform(CodexRequest.pluginList(params))
    }

    public func marketplaceAdd(
        _ params: CodexSchemaMarketplaceAddParams
    ) async throws -> CodexSchemaMarketplaceAddResponse {
        try await perform(CodexRequest.marketplaceAdd(params))
    }

    public func marketplaceRemove(
        _ params: CodexSchemaMarketplaceRemoveParams
    ) async throws -> CodexSchemaMarketplaceRemoveResponse {
        try await perform(CodexRequest.marketplaceRemove(params))
    }

    public func marketplaceUpgrade(
        _ params: CodexSchemaMarketplaceUpgradeParams
    ) async throws -> CodexSchemaMarketplaceUpgradeResponse {
        try await perform(CodexRequest.marketplaceUpgrade(params))
    }

    public func pluginInstalled(
        _ params: CodexSchemaPluginInstalledParams
    ) async throws -> CodexSchemaPluginInstalledResponse {
        try await perform(CodexRequest.pluginInstalled(params))
    }

    public func pluginRead(
        _ params: CodexSchemaPluginReadParams
    ) async throws -> CodexSchemaPluginReadResponse {
        try await perform(CodexRequest.pluginRead(params))
    }

    public func pluginSkillRead(
        _ params: CodexSchemaPluginSkillReadParams
    ) async throws -> CodexSchemaPluginSkillReadResponse {
        try await perform(CodexRequest.pluginSkillRead(params))
    }

    public func pluginShareSave(
        _ params: CodexSchemaPluginShareSaveParams
    ) async throws -> CodexSchemaPluginShareSaveResponse {
        try await perform(CodexRequest.pluginShareSave(params))
    }

    public func pluginShareUpdateTargets(
        _ params: CodexSchemaPluginShareUpdateTargetsParams
    ) async throws -> CodexSchemaPluginShareUpdateTargetsResponse {
        try await perform(CodexRequest.pluginShareUpdateTargets(params))
    }

    public func pluginShareList(
        _ params: CodexSchemaPluginShareListParams
    ) async throws -> CodexSchemaPluginShareListResponse {
        try await perform(CodexRequest.pluginShareList(params))
    }

    public func pluginShareCheckout(
        _ params: CodexSchemaPluginShareCheckoutParams
    ) async throws -> CodexSchemaPluginShareCheckoutResponse {
        try await perform(CodexRequest.pluginShareCheckout(params))
    }

    public func pluginShareDelete(
        _ params: CodexSchemaPluginShareDeleteParams
    ) async throws -> CodexSchemaPluginShareDeleteResponse {
        try await perform(CodexRequest.pluginShareDelete(params))
    }

    public func pluginInstall(
        _ params: CodexSchemaPluginInstallParams
    ) async throws -> CodexSchemaPluginInstallResponse {
        try await perform(CodexRequest.pluginInstall(params))
    }

    public func pluginUninstall(
        _ params: CodexSchemaPluginUninstallParams
    ) async throws -> CodexSchemaPluginUninstallResponse {
        try await perform(CodexRequest.pluginUninstall(params))
    }
}
