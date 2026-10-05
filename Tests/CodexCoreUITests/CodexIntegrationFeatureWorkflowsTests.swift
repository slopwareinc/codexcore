import XCTest
@testable import CodexCoreUI
import CodexCore

final class CodexIntegrationFeatureWorkflowsTests: XCTestCase {
    func testFailedControlPlaneMutationReportsFailureToHost() async {
        let actions = CodexIntegrationControlPlanePluginCatalogActionProvider(provider: FeatureProvider { _ in
            throw CodexIntegrationControlPlaneError("Denied")
        })
        let outcome = await actions.uninstallPlugin(.init(plugin: .init(id: "plugin", name: "plugin", marketplaceName: "workspace")))
        XCTAssertFalse(outcome.didSucceed)
        XCTAssertFalse(outcome.shouldRefresh)
    }

    func testHostedResourceNoAuthTargetWritesRequiredExplicitNull() throws {
        let params = CodexSchemaMCPResourceReadParams(server: "codex_apps", target: .init(connectorID: "public-app", linkID: nil), uri: "resource://public")
        let wire = try CodexJSONValue(encoding: params)
        XCTAssertEqual(wire.objectValue?["target"]?.objectValue?["linkId"], .null)
        XCTAssertEqual(wire.objectValue?["target"]?.objectValue?["connectorId"], .string("public-app"))
    }
    func testMCPHydrationRetainsUnknownSettingsAndPerToolFields() throws {
        let raw: CodexJSONValue = .dictionary([
            "url": .string("https://example.com/mcp"), "enabled": .bool(true),
            "env_http_headers": .dictionary(["Authorization": .string("API_TOKEN")]),
            "future_auth": .dictionary(["tenant": .string("one")]),
            "tools": .dictionary(["search": .dictionary(["approval_mode": .string("prompt"), "enabled": .bool(false), "future": .int(7)])]),
        ])
        var configuration = try XCTUnwrap(CodexMCPServerConfiguration(name: "example", value: raw))
        configuration.enabled = false
        configuration.toolApprovalModes["search"] = .approve
        let fields = try XCTUnwrap(configuration.configValue.objectValue)
        XCTAssertEqual(fields["url"], .string("https://example.com/mcp"))
        XCTAssertEqual(fields["future_auth"], raw.objectValue?["future_auth"])
        XCTAssertEqual(fields["env_http_headers"], raw.objectValue?["env_http_headers"])
        XCTAssertEqual(fields["enabled"], .bool(false))
        XCTAssertEqual(fields["tools"]?.objectValue?["search"]?.objectValue, ["enabled": .bool(false), "future": .int(7), "approval_mode": .string("approve")])
        configuration.toolApprovalModes = [:]
        XCTAssertNil(configuration.configValue.objectValue?["tools"]?.objectValue?["search"]?.objectValue?["approval_mode"])
        XCTAssertEqual(configuration.configValue.objectValue?["tools"]?.objectValue?["search"]?.objectValue?["future"], .int(7))
    }

    func testMCPLayerHydrationMergesNestedOverridesAndIgnoresDisabledLayer() {
        func layer(_ fields: [String: CodexJSONValue], disabled: String? = nil) -> CodexSchemaConfigLayer {
            .init(config: .dictionary(["mcp_servers": .dictionary(["example": .dictionary(fields)])]), disabledReason: disabled, name: .init(), version: "1")
        }
        let response = CodexSchemaConfigReadResponse(config: .init(), layers: [
            layer(["command": .string("server"), "env": .dictionary(["A": .string("one"), "B": .string("two")])]),
            layer(["env": .dictionary(["A": .string("updated")])]),
            layer(["command": .string("untrusted")], disabled: "untrusted project"),
        ], origins: [:])
        let config = CodexMCPServerConfiguration.configurations(from: response)["example"]
        XCTAssertEqual(config?.command, "server")
        XCTAssertEqual(config?.environment, ["A": "updated", "B": "two"])
        XCTAssertNil(CodexMCPServerConfiguration(name: "partial", value: .dictionary(["enabled": .bool(true)])))
    }

    func testUnknownMCPApprovalValuesSurviveEditingOtherSettings() throws {
        var configuration = try XCTUnwrap(CodexMCPServerConfiguration(name: "server", value: .dictionary([
            "command": .string("server"), "default_tools_approval_mode": .string("future-mode"),
            "tools": .dictionary(["search": .dictionary(["approval_mode": .string("future-mode")])]),
        ])))
        configuration.enabled = false
        XCTAssertEqual(configuration.configValue.objectValue?["default_tools_approval_mode"], .string("future-mode"))
        XCTAssertEqual(configuration.configValue.objectValue?["tools"]?.objectValue?["search"]?.objectValue?["approval_mode"], .string("future-mode"))
    }

    func testPluginSearchProjectsRemoteIdentityAndPagination() async throws {
        let recorder = IntegrationFeatureRecorder()
        let remote = CodexSchemaPluginSummary(authPolicy: .oNUSE, enabled: false, id: "plugin-1", installPolicy: .aVAILABLE,
                                              installed: false, mustShowInstallationInterstitial: true, name: "remote", remotePluginID: "shared-1",
                                              source: .init(.dictionary(["type": .string("remote")])))
        let provider = FeatureProvider { request in
            await recorder.record(request)
            return try CodexJSONValue(encoding: CodexSchemaPluginSearchResponse(data: [.init(marketplaceName: "workspace", plugin: remote)], nextCursor: "next"))
        }
        let result = try await CodexIntegrationFeatureWorkflows.searchPlugins(query: "search", cursor: "first", workingDirectories: ["/workspace"], provider: provider)
        XCTAssertEqual(result.nextCursor, "next")
        XCTAssertEqual(result.plugins.first?.protocolID, "plugin-1")
        XCTAssertEqual(result.plugins.first?.remotePluginID, "shared-1")
        XCTAssertEqual(result.plugins.first?.requiresInstallationConfirmation, true)
        let requests = await recorder.requests
        guard case .pluginSearch(let params) = requests.first else { return XCTFail("Expected remote search") }
        XCTAssertEqual(params.cursor, "first")
        XCTAssertEqual(params.searchTerm, "search")
        XCTAssertEqual(params.cwds?.first?.rawValue, .string("/workspace"))
    }

    func testInstalledPluginInventoryReconcilesCatalogAndKeepsInstalledOnlyEntries() throws {
        func raw(_ id: String, installed: Bool, enabled: Bool) -> CodexJSONValue {
            .dictionary(["id": .string(id), "name": .string(id), "installed": .bool(installed), "enabled": .bool(enabled),
                         "installPolicy": .string("AVAILABLE"), "authPolicy": .string("ON_USE"), "source": .dictionary(["type": .string("remote")])])
        }
        func response(_ plugins: [CodexJSONValue]) -> CodexJSONValue {
            .dictionary(["marketplaces": .array([.dictionary(["name": .string("workspace"), "plugins": .array(plugins)])])])
        }
        var session = CodexIntegrationCatalogSession()
        _ = session.applyPluginResponse(response([raw("one", installed: false, enabled: false)]),
                                        installedResponse: response([raw("one", installed: true, enabled: true), raw("two", installed: true, enabled: false)]))
        XCTAssertEqual(session.plugins.count, 2)
        XCTAssertEqual(session.plugins.first(where: { $0.protocolID == "one" })?.installed, true)
        XCTAssertEqual(session.plugins.first(where: { $0.protocolID == "one" })?.enabled, true)
    }

    func testPluginInstallationReturnsRequiredAuthenticationApps() async {
        let app = CodexSchemaAppSummary(id: "app-1", installUrl: "https://example.com/connect", name: "Connect me")
        let provider = FeatureProvider { _ in
            try CodexJSONValue(encoding: CodexSchemaPluginInstallResponse(appsNeedingAuth: [app], authPolicy: .oNINSTALL))
        }
        let actions = CodexIntegrationControlPlanePluginCatalogActionProvider(provider: provider)
        let result = await actions.installPlugin(.init(plugin: .init(id: "plugin", name: "plugin", marketplaceName: "workspace")))
        XCTAssertTrue(result.didSucceed)
        XCTAssertEqual(result.appsNeedingAuthentication, [app])
    }

    func testSkillDetailReadsLocalBodyAndFrontmatterThroughHost() async throws {
        let contents = "---\nallowed-tools: [Read, Bash]\ndisable-model-invocation: true\n---\nActual instructions"
        let recorder = IntegrationFeatureRecorder()
        let provider = FeatureProvider { request in
            await recorder.record(request)
            return try CodexJSONValue(encoding: CodexSchemaFSReadFileResponse(dataBase64: Data(contents.utf8).base64EncodedString()))
        }
        let document = try await CodexIntegrationFeatureWorkflows.skillDocument(.init(name: "example", path: "/tmp/skills/example/SKILL.md"), provider: provider)
        XCTAssertEqual(document.body, "Actual instructions")
        XCTAssertEqual(document.allowedTools, ["Read", "Bash"])
        XCTAssertTrue(document.disablesModelInvocation)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.operationID), ["fs/readFile"])
    }

    func testRemoteSkillUsesAuthoritativeIdentifiersAndMissingBodyFails() async throws {
        let recorder = IntegrationFeatureRecorder()
        let provider = FeatureProvider { request in
            await recorder.record(request)
            return try CodexJSONValue(encoding: CodexSchemaPluginSkillReadResponse(contents: "Remote instructions"))
        }
        let skill = CodexSkillSummary(name: "search", path: "/unused", remoteMarketplaceName: "shared", remotePluginID: "remote-1")
        let document = try await CodexIntegrationFeatureWorkflows.skillDocument(skill, provider: provider)
        XCTAssertEqual(document.body, "Remote instructions")
        let requests = await recorder.requests
        XCTAssertEqual(requests, [.pluginSkillRead(.init(remoteMarketplaceName: "shared", remotePluginID: "remote-1", skillName: "search"))])
        do {
            _ = try await CodexIntegrationFeatureWorkflows.skillDocument(skill, provider: FeatureProvider { _ in
                try CodexJSONValue(encoding: CodexSchemaPluginSkillReadResponse())
            })
            XCTFail("Missing body must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
    }

    func testSkillRemovalRejectsNonPersonalAndUnsafeTargetsBeforeRequest() async {
        let recorder = IntegrationFeatureRecorder()
        let provider = FeatureProvider { request in await recorder.record(request); return .dictionary([:]) }
        for skill in [
            CodexSkillSummary(name: "system", path: "/skills/system/SKILL.md", scope: "system"),
            CodexSkillSummary(name: "unsafe", path: "/SKILL.md", scope: "user"),
            CodexSkillSummary(name: "plugin:skill", path: "/skills/plugin/SKILL.md", scope: "user"),
        ] {
            do { try await CodexIntegrationFeatureWorkflows.removeSkill(skill, provider: provider); XCTFail("Removal must fail") }
            catch { }
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAppToolPolicyRetainsConfigConflictGuardAndReload() throws {
        let config = CodexSchemaConfigReadResponse(config: .init(), layers: [.init(
            config: .dictionary([:]), name: .init(.dictionary(["type": .string("user"), "file": .string("/home/config.toml")])), version: "version-2"
        )], origins: [:])
        let request = try CodexIntegrationFeatureWorkflows.appToolPolicyRequest(appID: "github", tool: "search", enabled: false, approval: .prompt, config: config)
        guard case .configBatchWrite(let params) = request else { return XCTFail("Expected config batch") }
        XCTAssertEqual(params.expectedVersion, "version-2")
        XCTAssertEqual(params.filePath, "/home/config.toml")
        XCTAssertEqual(params.reloadUserConfig, true)
        XCTAssertEqual(params.edits.map(\.keyPath), ["apps.github.tools.search.enabled", "apps.github.tools.search.approval_mode"])
        XCTAssertThrowsError(try CodexIntegrationFeatureWorkflows.appToolPolicyRequest(appID: "github", tool: "ambiguous.path", enabled: true, approval: nil, config: config))
    }

    func testSharingTargetsRejectMalformedLinesInsteadOfDroppingRecipients() throws {
        let targets = try CodexPluginSharingInput.targets("user alice reader\ngroup developers editor\n")
        XCTAssertEqual(targets.map(\.principalID), ["alice", "developers"])
        XCTAssertEqual(targets.map(\.role), [.reader, .editor])
        XCTAssertThrowsError(try CodexPluginSharingInput.targets("user alice reader\nmalformed recipient"))
        XCTAssertThrowsError(try CodexPluginSharingInput.targets("user alice owner"))
        XCTAssertEqual(CodexPluginSharingInput.text([
            .init(name: "Alice", principalID: "alice", principalType: .user, role: .reader),
            .init(name: "Owner", principalID: "owner", principalType: .user, role: .owner),
        ]), "user alice reader")
    }

    @MainActor func testEventStreamRegistersBeforeStartFiltersSubscriptionAndAlwaysStops() async throws {
        let recorder = IntegrationFeatureRecorder()
        let provider = EventFeatureProvider(recorder: recorder, cancelStart: false)
        var methods: [String] = []
        try await CodexMCPEventStreamWorkflow.run(.init(arguments: .dictionary([:]), name: "events", server: "server", subscriptionID: "mine", threadID: "thread"), provider: provider) { event in
            methods.append(event.method)
        }
        XCTAssertEqual(methods, ["mine-event"])
        let operations = await recorder.operations
        XCTAssertEqual(operations, ["observe", "mcpServer/event/stream/start", "mcpServer/event/stream/stop"])
    }

    func testCancelledAmbiguousEventStartStillStopsSubscription() async throws {
        let recorder = IntegrationFeatureRecorder()
        let provider = EventFeatureProvider(recorder: recorder, cancelStart: true)
        let task = Task {
            try await CodexMCPEventStreamWorkflow.run(.init(arguments: .dictionary([:]), name: "events", server: "server", subscriptionID: "mine", threadID: "thread"), provider: provider) { _ in }
        }
        for _ in 0..<100 {
            if await recorder.operations.contains("mcpServer/event/stream/start") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError { }
        let operations = await recorder.operations
        XCTAssertEqual(operations.last, "mcpServer/event/stream/stop")
    }
}

private struct FeatureProvider: CodexIntegrationControlPlaneProvider {
    let handler: @Sendable (CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue
    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue { try await handler(request) }
}

private actor IntegrationFeatureRecorder {
    private(set) var requests: [CodexIntegrationControlPlaneRequest] = []
    private(set) var operations: [String] = []
    func record(_ request: CodexIntegrationControlPlaneRequest) { requests.append(request); operations.append(request.operationID) }
    func observed() { operations.append("observe") }
}

private struct EventFeatureProvider: CodexIntegrationControlPlaneProvider {
    let recorder: IntegrationFeatureRecorder
    let cancelStart: Bool
    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        await recorder.record(request)
        if case .mcpEventStreamStart = request, cancelStart { try await Task.sleep(for: .seconds(30)) }
        return .dictionary([:])
    }
    func observeMCPServerEvents() async throws -> AsyncThrowingStream<CodexSchemaMCPServerEventStreamNotification, Error> {
        await recorder.observed()
        return AsyncThrowingStream { stream in
            stream.yield(.init(notification: .init(method: "other-event", params: .null), subscriptionID: "other"))
            stream.yield(.init(notification: .init(method: "mine-event", params: .null), subscriptionID: "mine"))
            stream.finish()
        }
    }
}
