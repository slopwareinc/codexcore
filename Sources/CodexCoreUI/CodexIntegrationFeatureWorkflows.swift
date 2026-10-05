import Foundation
import CodexCore

/// Operations shared by the integration detail views, kept separate from view lifecycle state.
enum CodexIntegrationFeatureWorkflows {
    static func skillDocument(
        _ skill: CodexSkillSummary,
        provider: any CodexIntegrationControlPlaneProvider
    ) async throws -> CodexSkillDocument {
        let contents: String
        if let marketplace = skill.remoteMarketplaceName, let pluginID = skill.remotePluginID {
            let response = try await provider.perform(.pluginSkillRead(.init(
                remoteMarketplaceName: marketplace, remotePluginID: pluginID, skillName: skill.name
            ))).decode(CodexSchemaPluginSkillReadResponse.self)
            guard let value = response.contents else { throw CodexIntegrationControlPlaneError("The skill body is unavailable.") }
            contents = value
        } else {
            let response = try await provider.perform(.fsReadFile(.init(path: .init(.string(skill.path)))))
                .decode(CodexSchemaFSReadFileResponse.self)
            guard response.dataBase64.utf8.count <= 1_398_104,
                  let data = Data(base64Encoded: response.dataBase64), data.count <= 1_048_576,
                  let value = String(data: data, encoding: .utf8) else {
                throw CodexIntegrationControlPlaneError("The skill must be UTF-8 text smaller than 1 MiB.")
            }
            contents = value
        }
        guard contents.utf8.count <= 1_048_576 else { throw CodexIntegrationControlPlaneError("The skill body exceeds 1 MiB.") }
        try Task.checkCancellation()
        return CodexSkillDocument(contents: contents)
    }

    static func canRemove(_ skill: CodexSkillSummary) -> Bool {
        let file = URL(fileURLWithPath: skill.path).standardizedFileURL
        return skill.scope == "user" && skill.remotePluginID == nil && !skill.name.contains(":")
            && file.lastPathComponent == "SKILL.md" && file.deletingLastPathComponent().path != "/"
    }

    static func removeSkill(_ skill: CodexSkillSummary, provider: any CodexIntegrationControlPlaneProvider) async throws {
        guard canRemove(skill) else { throw CodexIntegrationControlPlaneError("Only personal skills can be removed here.") }
        _ = try await provider.perform(.fsRemove(CodexPluginProtocolMutation.skillUninstallParams(for: .init(skill: skill))))
    }

    static func searchPlugins(
        query: String, cursor: String? = nil, workingDirectories: [String],
        provider: any CodexIntegrationControlPlaneProvider
    ) async throws -> (plugins: [CodexPluginSummary], nextCursor: String?) {
        let response = try await provider.perform(.pluginSearch(.init(
            cursor: cursor, cwds: workingDirectories.isEmpty ? nil : workingDirectories.map { .init(.string($0)) },
            limit: 50, searchTerm: query
        ))).decode(CodexSchemaPluginSearchResponse.self)
        try Task.checkCancellation()
        return (try response.data.compactMap { result in
            CodexPluginSummary(raw: try CodexJSONValue(encoding: result.plugin), marketplace: .init(
                name: result.marketplaceName, displayName: result.marketplaceName,
                path: result.marketplacePath?.rawValue.stringValue
            ))
        }, response.nextCursor)
    }

    static func appToolPolicyRequest(
        appID: String, tool: String, enabled: Bool?, approval: CodexSchemaAppToolApproval?,
        config: CodexSchemaConfigReadResponse
    ) throws -> CodexIntegrationControlPlaneRequest {
        // IDs and tool names form TOML key paths. Refuse ambiguous path components.
        for component in [appID, tool] where component.isEmpty || component.contains(".") || component.contains("\"") {
            throw CodexIntegrationControlPlaneError("This tool name requires editing the configuration file directly.")
        }
        var edits: [CodexSchemaConfigEdit] = []
        if let enabled { edits.append(.init(keyPath: "apps.\(appID).tools.\(tool).enabled", mergeStrategy: .upsert, value: .bool(enabled))) }
        if let approval { edits.append(.init(keyPath: "apps.\(appID).tools.\(tool).approval_mode", mergeStrategy: .upsert, value: .string(approval.rawValue))) }
        let target = CodexPluginProtocolMutation.userConfigTarget(from: config)
        return .configBatchWrite(.init(edits: edits, expectedVersion: target?.expectedVersion, filePath: target?.filePath, reloadUserConfig: true))
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
