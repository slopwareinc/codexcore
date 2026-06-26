import Foundation

extension CodexClient {
    @discardableResult
    public func configMCPServerReload() async throws -> CodexJSONValue {
        try await request(
            method: CodexAppServerClientMethod.configMCPServerReload.rawValue,
            params: [String: CodexJSONValue]()
        )
    }
    public func configRead(_ params: CodexSchemaConfigReadParams) async throws -> CodexSchemaConfigReadResponse {
        try await request(
            method: CodexAppServerClientMethod.configRead.rawValue,
            params: params,
            response: CodexSchemaConfigReadResponse.self
        )
    }
    @discardableResult
    public func configValueWrite(_ params: CodexSchemaConfigValueWriteParams) async throws -> CodexJSONValue {
        let encoded = try CodexJSONValue(encoding: params)
        return try await request(
            method: CodexAppServerClientMethod.configValueWrite.rawValue,
            params: encoded.objectValue ?? [:]
        )
    }
    @discardableResult
    public func configBatchWrite(_ params: CodexSchemaConfigBatchWriteParams) async throws -> CodexJSONValue {
        let encoded = try CodexJSONValue(encoding: params)
        return try await request(
            method: CodexAppServerClientMethod.configBatchWrite.rawValue,
            params: encoded.objectValue ?? [:]
        )
    }
    public func skillsConfigWrite(_ params: CodexSchemaSkillsConfigWriteParams) async throws -> CodexSchemaSkillsConfigWriteResponse {
        try await request(
            method: CodexAppServerClientMethod.skillsConfigWrite.rawValue,
            params: params,
            response: CodexSchemaSkillsConfigWriteResponse.self
        )
    }
    public func marketplaceAdd(_ params: CodexSchemaMarketplaceAddParams) async throws -> CodexSchemaMarketplaceAddResponse {
        try await request(
            method: CodexAppServerClientMethod.marketplaceAdd.rawValue,
            params: params,
            response: CodexSchemaMarketplaceAddResponse.self
        )
    }
    public func marketplaceRemove(_ params: CodexSchemaMarketplaceRemoveParams) async throws -> CodexSchemaMarketplaceRemoveResponse {
        try await request(
            method: CodexAppServerClientMethod.marketplaceRemove.rawValue,
            params: params,
            response: CodexSchemaMarketplaceRemoveResponse.self
        )
    }
    public func marketplaceUpgrade(_ params: CodexSchemaMarketplaceUpgradeParams) async throws -> CodexSchemaMarketplaceUpgradeResponse {
        try await request(
            method: CodexAppServerClientMethod.marketplaceUpgrade.rawValue,
            params: params,
            response: CodexSchemaMarketplaceUpgradeResponse.self
        )
    }
    public func pluginInstalled(_ params: CodexSchemaPluginInstalledParams) async throws -> CodexSchemaPluginInstalledResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginInstalled.rawValue,
            params: params,
            response: CodexSchemaPluginInstalledResponse.self
        )
    }
    public func pluginRead(_ params: CodexSchemaPluginReadParams) async throws -> CodexSchemaPluginReadResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginRead.rawValue,
            params: params,
            response: CodexSchemaPluginReadResponse.self
        )
    }
    public func pluginSkillRead(_ params: CodexSchemaPluginSkillReadParams) async throws -> CodexSchemaPluginSkillReadResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginSkillRead.rawValue,
            params: params,
            response: CodexSchemaPluginSkillReadResponse.self
        )
    }
    public func pluginShareSave(_ params: CodexSchemaPluginShareSaveParams) async throws -> CodexSchemaPluginShareSaveResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginShareSave.rawValue,
            params: params,
            response: CodexSchemaPluginShareSaveResponse.self
        )
    }
    public func pluginShareUpdateTargets(_ params: CodexSchemaPluginShareUpdateTargetsParams) async throws -> CodexSchemaPluginShareUpdateTargetsResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginShareUpdateTargets.rawValue,
            params: params,
            response: CodexSchemaPluginShareUpdateTargetsResponse.self
        )
    }
    public func pluginShareList(_ params: CodexSchemaPluginShareListParams) async throws -> CodexSchemaPluginShareListResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginShareList.rawValue,
            params: params,
            response: CodexSchemaPluginShareListResponse.self
        )
    }
    public func pluginShareCheckout(_ params: CodexSchemaPluginShareCheckoutParams) async throws -> CodexSchemaPluginShareCheckoutResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginShareCheckout.rawValue,
            params: params,
            response: CodexSchemaPluginShareCheckoutResponse.self
        )
    }
    public func pluginShareDelete(_ params: CodexSchemaPluginShareDeleteParams) async throws -> CodexSchemaPluginShareDeleteResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginShareDelete.rawValue,
            params: params,
            response: CodexSchemaPluginShareDeleteResponse.self
        )
    }
    public func pluginInstall(_ params: CodexSchemaPluginInstallParams) async throws -> CodexSchemaPluginInstallResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginInstall.rawValue,
            params: params,
            response: CodexSchemaPluginInstallResponse.self
        )
    }
    public func pluginUninstall(_ params: CodexSchemaPluginUninstallParams) async throws -> CodexSchemaPluginUninstallResponse {
        try await request(
            method: CodexAppServerClientMethod.pluginUninstall.rawValue,
            params: params,
            response: CodexSchemaPluginUninstallResponse.self
        )
    }
}

extension Codex {
    @discardableResult
    public func configMCPServerReload() async throws -> CodexJSONValue {
        try await client.configMCPServerReload()
    }
    public func configRead(_ params: CodexSchemaConfigReadParams) async throws -> CodexSchemaConfigReadResponse {
        try await client.configRead(params)
    }
    @discardableResult
    public func configValueWrite(_ params: CodexSchemaConfigValueWriteParams) async throws -> CodexJSONValue {
        try await client.configValueWrite(params)
    }
    @discardableResult
    public func configBatchWrite(_ params: CodexSchemaConfigBatchWriteParams) async throws -> CodexJSONValue {
        try await client.configBatchWrite(params)
    }
    public func skillsConfigWrite(_ params: CodexSchemaSkillsConfigWriteParams) async throws -> CodexSchemaSkillsConfigWriteResponse {
        try await client.skillsConfigWrite(params)
    }
    public func marketplaceAdd(_ params: CodexSchemaMarketplaceAddParams) async throws -> CodexSchemaMarketplaceAddResponse {
        try await client.marketplaceAdd(params)
    }
    public func marketplaceRemove(_ params: CodexSchemaMarketplaceRemoveParams) async throws -> CodexSchemaMarketplaceRemoveResponse {
        try await client.marketplaceRemove(params)
    }
    public func marketplaceUpgrade(_ params: CodexSchemaMarketplaceUpgradeParams) async throws -> CodexSchemaMarketplaceUpgradeResponse {
        try await client.marketplaceUpgrade(params)
    }
    public func pluginInstalled(_ params: CodexSchemaPluginInstalledParams) async throws -> CodexSchemaPluginInstalledResponse {
        try await client.pluginInstalled(params)
    }
    public func pluginRead(_ params: CodexSchemaPluginReadParams) async throws -> CodexSchemaPluginReadResponse {
        try await client.pluginRead(params)
    }
    public func pluginSkillRead(_ params: CodexSchemaPluginSkillReadParams) async throws -> CodexSchemaPluginSkillReadResponse {
        try await client.pluginSkillRead(params)
    }
    public func pluginShareSave(_ params: CodexSchemaPluginShareSaveParams) async throws -> CodexSchemaPluginShareSaveResponse {
        try await client.pluginShareSave(params)
    }
    public func pluginShareUpdateTargets(_ params: CodexSchemaPluginShareUpdateTargetsParams) async throws -> CodexSchemaPluginShareUpdateTargetsResponse {
        try await client.pluginShareUpdateTargets(params)
    }
    public func pluginShareList(_ params: CodexSchemaPluginShareListParams) async throws -> CodexSchemaPluginShareListResponse {
        try await client.pluginShareList(params)
    }
    public func pluginShareCheckout(_ params: CodexSchemaPluginShareCheckoutParams) async throws -> CodexSchemaPluginShareCheckoutResponse {
        try await client.pluginShareCheckout(params)
    }
    public func pluginShareDelete(_ params: CodexSchemaPluginShareDeleteParams) async throws -> CodexSchemaPluginShareDeleteResponse {
        try await client.pluginShareDelete(params)
    }
    public func pluginInstall(_ params: CodexSchemaPluginInstallParams) async throws -> CodexSchemaPluginInstallResponse {
        try await client.pluginInstall(params)
    }
    public func pluginUninstall(_ params: CodexSchemaPluginUninstallParams) async throws -> CodexSchemaPluginUninstallResponse {
        try await client.pluginUninstall(params)
    }
}
