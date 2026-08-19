import XCTest
import CodexCore
@testable import CodexCoreUI

final class CodexExtensibilitySurfaceTests: XCTestCase {
    func testStdioMCPConfigurationPreservesTransportTimeoutsAndPermissions() throws {
        let configuration = CodexMCPServerConfiguration(
            name: "local_tools",
            enabled: false,
            command: "node",
            arguments: ["server.js", "--stdio"],
            workingDirectory: "/tmp/tools",
            environment: ["MODE": "test"],
            environmentPassthrough: ["HOME_TOKEN"],
            startupTimeoutSeconds: 12,
            toolTimeoutSeconds: 45,
            enabledTools: ["read"],
            disabledTools: ["delete"],
            defaultToolsApprovalMode: .prompt,
            toolApprovalModes: ["read": .approve]
        )

        guard case .dictionary(let value) = configuration.configValue else {
            return XCTFail("Expected MCP config object")
        }
        XCTAssertEqual(value["command"], .string("node"))
        XCTAssertEqual(value["args"], .array([.string("server.js"), .string("--stdio")]))
        XCTAssertEqual(value["cwd"], .string("/tmp/tools"))
        XCTAssertEqual(value["env"], .dictionary(["MODE": .string("test")]))
        XCTAssertEqual(value["env_vars"], .array([.string("HOME_TOKEN")]))
        XCTAssertEqual(value["startup_timeout_sec"], .double(12))
        XCTAssertEqual(value["tool_timeout_sec"], .double(45))
        XCTAssertEqual(value["enabled_tools"], .array([.string("read")]))
        XCTAssertEqual(value["disabled_tools"], .array([.string("delete")]))
        XCTAssertEqual(value["default_tools_approval_mode"], .string("prompt"))
        XCTAssertEqual(value["tools"], .dictionary([
            "read": .dictionary(["approval_mode": .string("approve")]),
        ]))

        guard case .configValueWrite(let params) = try CodexMCPProtocolMutation.save(configuration) else {
            return XCTFail("Expected config write")
        }
        XCTAssertEqual(params.keyPath, "mcp_servers.local_tools")
        XCTAssertEqual(params.value, configuration.configValue)
    }

    func testHTTPMCPConfigurationPreservesAuthenticationHeaders() {
        let configuration = CodexMCPServerConfiguration(
            name: "remote",
            transport: .streamableHTTP,
            url: "https://example.com/mcp",
            bearerTokenEnvironmentVariable: "MCP_TOKEN",
            httpHeaders: ["X-Client": "Codex"],
            environmentHTTPHeaders: ["X-Secret": "MCP_SECRET"]
        )
        guard case .dictionary(let value) = configuration.configValue else {
            return XCTFail("Expected MCP config object")
        }
        XCTAssertEqual(value["url"], .string("https://example.com/mcp"))
        XCTAssertEqual(value["bearer_token_env_var"], .string("MCP_TOKEN"))
        XCTAssertEqual(value["http_headers"], .dictionary(["X-Client": .string("Codex")]))
        XCTAssertEqual(value["env_http_headers"], .dictionary(["X-Secret": .string("MCP_SECRET")]))
        XCTAssertNil(value["command"])
    }

    func testMCPMutationWritesBeforeReload() async throws {
        let provider = RecordingIntegrationProvider()
        var session = CodexIntegrationCatalogSession()
        let activity = await session.performMCPMutation(
            try CodexMCPProtocolMutation.setEnabled(name: "github", enabled: false),
            using: provider,
            errorMessage: { $0.localizedDescription }
        )

        XCTAssertEqual(activity.title, "Updated MCP servers")
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        guard case .configValueWrite = requests[0] else { return XCTFail("Write must be first") }
        XCTAssertEqual(requests[1], .mcpReload)
    }

    func testMCPToolSchemaAndUnknownStartupStateRemainHonest() throws {
        let raw: CodexJSONValue = .dictionary([
            "name": .string("schema-server"),
            "pluginId": .string("marketplace:plugin"),
            "enabled": .bool(true),
            "status": .string("degraded"),
            "resources": .array([]),
            "resourceTemplates": .array([]),
            "tools": .dictionary([
                "search": .dictionary([
                    "name": .string("search"),
                    "inputSchema": .dictionary([
                        "type": .string("object"),
                        "properties": .dictionary(["query": .dictionary(["type": .string("string")])]),
                        "required": .array([.string("query")]),
                    ]),
                    "annotations": .dictionary([
                        "readOnlyHint": .bool(true),
                        "destructiveHint": .bool(false),
                        "openWorldHint": .bool(true),
                    ]),
                ]),
            ]),
        ])
        let status = try XCTUnwrap(CodexMCPServerStatus(raw: raw))
        XCTAssertEqual(status.startupState, .unrecognized("degraded"))
        XCTAssertEqual(status.pluginID, "marketplace:plugin")
        XCTAssertEqual(status.ownershipLabel, "Provided by plugin marketplace:plugin")
        XCTAssertEqual(status.tools.first?.parameters, ["query *"])
        XCTAssertEqual(status.tools.first?.readOnlyHint, true)
        XCTAssertEqual(status.tools.first?.destructiveHint, false)
        XCTAssertEqual(status.tools.first?.openWorldHint, true)
    }

    func testStartupNotificationKeepsFailureReasonAndEnabledStateSeparate() {
        var session = CodexIntegrationCatalogSession(mcpServers: [
            .init(name: "github", enabled: true, startupStatus: "ready"),
        ])
        XCTAssertTrue(session.applyMCPStartupStatus(.init(
            error: "Login required",
            failureReason: .reauthenticationRequired,
            name: "github",
            status: .failed
        )))
        XCTAssertEqual(session.mcpServers[0].startupState, .failed)
        XCTAssertEqual(session.mcpServers[0].failureReason, .reauthenticationRequired)
        XCTAssertEqual(session.mcpServers[0].enabled, true)
        XCTAssertEqual(CodexMCPStatusPanelServerRow(server: session.mcpServers[0]).enabledLabel, "Enabled")
    }

    func testOAuthErrorTaxonomyExtractsActionableScope() {
        let error = CodexMCPAuthenticationError(
            message: #"InsufficientScope required_scope=repo upgrade_url=https://example.com/upgrade"#
        )
        XCTAssertEqual(error, .insufficientScope(
            requiredScope: "repo",
            upgradeURL: URL(string: "https://example.com/upgrade")
        ))
        XCTAssertEqual(CodexMCPAuthenticationError(message: "TokenExpired"), .tokenExpired)
        XCTAssertEqual(CodexMCPAuthenticationError(message: "TokenRefreshFailed"), .tokenRefreshFailed)
        XCTAssertEqual(CodexMCPAuthenticationError(message: "AuthorizationServerMismatch"), .authorizationServerMismatch)
    }

    func testSkillDocumentParsesSecurityFrontmatterAndBody() {
        let document = CodexSkillDocument(contents: """
        ---
        name: deploy
        allowed-tools: [Read, Bash, mcp__github]
        disable-model-invocation: true
        ---
        # Deploy

        Follow the release checklist.
        """)
        XCTAssertEqual(document.allowedTools, ["Read", "Bash", "mcp__github"])
        XCTAssertTrue(document.disablesModelInvocation)
        XCTAssertTrue(document.body.hasPrefix("# Deploy"))
    }

    func testSkillSummaryUsesSchemaIconURLsWithoutPluginNameGuessing() throws {
        let raw: CodexJSONValue = .dictionary([
            "name": .string("review"),
            "path": .string("/skills/review/SKILL.md"),
            "description": .string("Review changes"),
            "enabled": .bool(true),
            "interface": .dictionary([
                "iconSmallUrl": .string("https://example.com/review-small.png"),
                "iconLargeUrl": .string("https://example.com/review-large.png"),
            ]),
            "allowed-tools": .array([.string("Read")]),
            "disable-model-invocation": .bool(true),
        ])
        let skill = try XCTUnwrap(CodexSkillSummary(raw: raw))
        XCTAssertEqual(skill.icon.logo, "https://example.com/review-small.png")
        XCTAssertEqual(skill.icon.logoDark, "https://example.com/review-large.png")
        XCTAssertEqual(skill.allowedTools, ["Read"])
        XCTAssertTrue(skill.disablesModelInvocation)
    }

    func testMarketplaceVersionComparisonSurfacesUpdate() {
        let plugins = [CodexPluginSummary(
            id: "market:plugin",
            name: "plugin",
            marketplaceName: "market",
            marketplaceDisplayName: "Market",
            localVersion: "1.9.0",
            availableVersion: "1.10.0"
        )]
        let marketplace = CodexMarketplaceSummary.summaries(from: plugins)[0]
        XCTAssertTrue(marketplace.hasKnownUpdate)
    }

    func testHooksCatalogPreservesEventMatcherSourceAndTrust() throws {
        let response: CodexJSONValue = .dictionary([
            "data": .array([.dictionary([
                "cwd": .string("/repo"),
                "warnings": .array([]),
                "errors": .array([]),
                "hooks": .array([.dictionary([
                    "key": .string("deny-shell"),
                    "eventName": .string("preToolUse"),
                    "matcher": .string("Bash|Shell"),
                    "source": .string("project"),
                    "sourcePath": .string("/repo/.codex/hooks.json"),
                    "trustStatus": .string("untrusted"),
                    "enabled": .bool(true),
                    "isManaged": .bool(false),
                    "handlerType": .string("command"),
                    "command": .string("policy-check"),
                    "async": .bool(true),
                    "timeoutSec": .int(9),
                    "additionalContextLimit": .int(4096),
                    "currentHash": .string("trusted-command-hash"),
                    "statusMessage": .string("Shell use blocked by project hook"),
                ]), .dictionary([
                    "key": .string("mcp-audit"),
                    "eventName": .string("postToolUse"),
                    "source": .string("plugin"),
                    "sourcePath": .string("/repo/.codex/hooks.json"),
                    "pluginId": .string("audit@market"),
                    "trustStatus": .string("trusted"),
                    "enabled": .bool(true),
                    "isManaged": .bool(false),
                    "handlerType": .string("mcpTool"),
                    "server": .string("audit-server"),
                    "tool": .string("record"),
                    "timeoutSec": .int(5),
                    "currentHash": .string("trusted-mcp-hash"),
                ])]),
            ])]),
        ])
        let catalog = CodexHooksCatalog(raw: response)
        XCTAssertEqual(catalog.hooks.count, 2)
        let command = try XCTUnwrap(catalog.hooks.first(where: { $0.handlerType == .command }))
        XCTAssertEqual(command.event, .preToolUse)
        XCTAssertEqual(command.matcher, "Bash|Shell")
        XCTAssertEqual(command.sourceLabel, "Project")
        XCTAssertEqual(command.trustStatus, .untrusted)
        XCTAssertEqual(command.statusMessage, "Shell use blocked by project hook")
        XCTAssertTrue(command.isAsync)
        XCTAssertEqual(command.handlerDescription, "policy-check · Async")
        XCTAssertEqual(command.timeoutSeconds, 9)
        XCTAssertEqual(command.additionalContextLimit, 4096)

        let mcp = try XCTUnwrap(catalog.hooks.first(where: { $0.handlerType == .mcpTool }))
        XCTAssertEqual(mcp.pluginID, "audit@market")
        XCTAssertEqual(mcp.handlerDescription, "MCP · audit-server/record")

        guard case .configBatchWrite(let disable) = CodexHookProtocolMutation.setEnabled(
            false,
            for: command
        ) else { return XCTFail("Expected hook state batch write") }
        XCTAssertEqual(disable.reloadUserConfig, true)
        XCTAssertEqual(disable.edits.first?.keyPath, "hooks.state")
        XCTAssertEqual(disable.edits.first?.mergeStrategy, .upsert)
        XCTAssertEqual(disable.edits.first?.value, .dictionary([
            "deny-shell": .dictionary(["enabled": .bool(false)]),
        ]))

        guard case .configBatchWrite(let trust) = try CodexHookProtocolMutation.trust(command) else {
            return XCTFail("Expected hook trust batch write")
        }
        XCTAssertEqual(trust.edits.first?.value, .dictionary([
            "deny-shell": .dictionary(["trusted_hash": .string("trusted-command-hash")]),
        ]))
    }
}

private actor RecordingIntegrationProvider: CodexIntegrationControlPlaneProvider {
    private(set) var requests: [CodexIntegrationControlPlaneRequest] = []

    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        requests.append(request)
        return .dictionary([:])
    }
}
