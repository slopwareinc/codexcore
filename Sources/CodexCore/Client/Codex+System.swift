import Foundation

extension Codex {
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
