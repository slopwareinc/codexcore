import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexIntegrationCatalogTests: XCTestCase {
    func testSlashCommandsMatchObservedCodexPaletteAndFilter() throws {
        XCTAssertEqual(CodexSlashCommand.observedCommands.map(\.title), [
            "Code review",
            "Compact",
            "Fast",
            "Feedback",
            "Fork",
            "Goal",
            "MCP",
            "Model",
            "Personality",
            "Pet",
            "Plan mode",
            "Reasoning",
            "Side",
            "Status"
        ])
        let compact = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "compact" })
        XCTAssertNil(compact.draftText)
        let mcp = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "mcp" })
        XCTAssertNil(mcp.draftText)

        XCTAssertEqual(CodexSlashCommand.query(from: "/sta"), "sta")
        XCTAssertEqual(CodexSlashCommand.query(from: "  /side please"), "side")
        XCTAssertNil(CodexSlashCommand.query(from: "Ask about /status"))

        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/sta").map(\.title),
            ["Status"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/rea").map(\.title),
            ["Reasoning"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/").map(\.title),
            CodexSlashCommand.observedCommands.map(\.title)
        )

        let personalSkill = CodexSlashCommand(
            id: "resume-from-opencode",
            title: "resume-from-opencode",
            detail: "Resume an OpenCode session",
            systemImage: "hammer",
            section: "Skills",
            scopeBadge: "Personal"
        )
        let filtered = CodexSlashCommand.filteredCommands(
            from: CodexSlashCommand.observedCommands + [personalSkill],
            matching: "/resume"
        )

        XCTAssertEqual(filtered, [personalSkill])
        XCTAssertEqual(filtered.first?.section, "Skills")
        XCTAssertEqual(filtered.first?.scopeBadge, "Personal")
    }

    func testSlashCommandsParseAppServerSkillsListResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "cwd": .string("/tmp/CodexCore"),
                    "skills": .array([
                        .dictionary([
                            "name": .string("resume-from-opencode"),
                            "description": .string("Resume an OpenCode session from Codex."),
                            "shortDescription": .string("Resume OpenCode"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Continue the last OpenCode run"),
                                "defaultPrompt": .string("Resume the last OpenCode session.")
                            ]),
                            "path": .string("/tmp/skills/resume-from-opencode/SKILL.md"),
                            "scope": .string("user"),
                            "enabled": .bool(true)
                        ]),
                        .dictionary([
                            "name": .string("disabled-skill"),
                            "description": .string("Should not show"),
                            "path": .string("/tmp/skills/disabled/SKILL.md"),
                            "scope": .string("repo"),
                            "enabled": .bool(false)
                        ])
                    ]),
                    "errors": .array([])
                ])
            ])
        ])

        let commands = CodexSlashCommand.skillCommands(from: response)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.id, "skill:resume-from-opencode")
        XCTAssertEqual(commands.first?.title, "Resume OpenCode")
        XCTAssertEqual(commands.first?.detail, "Continue the last OpenCode run")
        XCTAssertEqual(commands.first?.section, "Skills")
        XCTAssertEqual(commands.first?.scopeBadge, "Personal")
        XCTAssertEqual(commands.first?.draftText, "Resume the last OpenCode session.")
        XCTAssertEqual(commands.first?.skillName, "resume-from-opencode")
        XCTAssertEqual(commands.first?.skillPath, "/tmp/skills/resume-from-opencode/SKILL.md")
    }

    func testMCPServerStatusesParseAppServerResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("filesystem"),
                    "authStatus": .string("unsupported"),
                    "serverInfo": .dictionary([
                        "name": .string("filesystem"),
                        "title": .string("Filesystem"),
                        "version": .string("1.0.0"),
                        "description": .string("Local file access")
                    ]),
                    "tools": .dictionary([
                        "read_file": .dictionary([
                            "name": .string("read_file"),
                            "title": .string("Read file"),
                            "description": .string("Read a file")
                        ]),
                        "list_directory": .dictionary([
                            "name": .string("list_directory"),
                            "title": .string("List files"),
                            "description": .string("List files")
                        ])
                    ]),
                    "resources": .array([
                        .dictionary([
                            "name": .string("workspace"),
                            "title": .string("Workspace"),
                            "uri": .string("file:///tmp/CodexCore")
                        ])
                    ]),
                    "resourceTemplates": .array([
                        .dictionary([
                            "name": .string("repo-file"),
                            "uriTemplate": .string("file:///{path}")
                        ])
                    ])
                ])
            ]),
            "nextCursor": .null
        ])

        let servers = CodexMCPServerStatus.statuses(from: response)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "filesystem")
        XCTAssertEqual(servers[0].displayName, "Filesystem")
        XCTAssertEqual(servers[0].version, "1.0.0")
        XCTAssertEqual(servers[0].detail, "Local file access")
        XCTAssertEqual(servers[0].authStatusLabel, "Auth unsupported")
        XCTAssertEqual(servers[0].tools.map(\.displayName), ["List files", "Read file"])
        XCTAssertEqual(servers[0].resources.map(\.displayName), ["Workspace"])
        XCTAssertEqual(servers[0].resourceTemplates.map(\.name), ["repo-file"])
        XCTAssertEqual(servers[0].inventorySummary, "2 tools · 2 resources")

        let updated = servers[0].applyingStartupStatus("failed", error: "node missing")
        XCTAssertEqual(updated.startupStatus, "failed")
        XCTAssertEqual(updated.error, "node missing")
    }

    func testPluginSummariesParseAppServerPluginListResponse() {
        let response: CodexJSONValue = .dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("local"),
                    "interface": .dictionary([
                        "displayName": .string("Local marketplace")
                    ]),
                    "path": .string("/tmp/marketplace.json"),
                    "plugins": .array([
                        .dictionary([
                            "authPolicy": .string("ON_USE"),
                            "enabled": .bool(true),
                            "id": .string("resume-from-opencode"),
                            "installPolicy": .string("INSTALLED_BY_DEFAULT"),
                            "installed": .bool(true),
                            "name": .string("resume-from-opencode"),
                            "source": .dictionary([
                                "type": .string("local"),
                                "path": .string("/tmp/plugins/resume-from-opencode")
                            ]),
                            "availability": .string("AVAILABLE"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Resume a previous OpenCode session"),
                                "longDescription": .string("Resume long running agent work."),
                                "developerName": .string("OpenAI"),
                                "category": .string("Agents"),
                                "capabilities": .array([.string("skills"), .string("prompts")]),
                                "screenshots": .array([]),
                                "screenshotUrls": .array([])
                            ]),
                            "keywords": .array([.string("agents")]),
                            "localVersion": .string("1.0.0")
                        ]),
                        .dictionary([
                            "authPolicy": .string("ON_INSTALL"),
                            "enabled": .bool(false),
                            "id": .string("example-remote"),
                            "installPolicy": .string("AVAILABLE"),
                            "installed": .bool(false),
                            "name": .string("example-remote"),
                            "source": .dictionary([
                                "type": .string("remote")
                            ]),
                            "availability": .string("AVAILABLE"),
                            "interface": .dictionary([
                                "displayName": .string("Example Remote"),
                                "shortDescription": .string("Remote plugin"),
                                "capabilities": .array([]),
                                "screenshots": .array([]),
                                "screenshotUrls": .array([])
                            ])
                        ])
                    ])
                ])
            ]),
            "marketplaceLoadErrors": .array([
                .dictionary([
                    "marketplacePath": .string("/tmp/bad-marketplace.json"),
                    "message": .string("invalid manifest")
                ])
            ]),
            "featuredPluginIds": .array([])
        ])

        let plugins = CodexPluginSummary.plugins(from: response)

        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(plugins[0].name, "resume-from-opencode")
        XCTAssertEqual(plugins[0].displayName, "Resume OpenCode")
        XCTAssertEqual(plugins[0].statusLabel, "Installed")
        XCTAssertEqual(plugins[0].sourceLabel, "Local")
        XCTAssertEqual(plugins[0].sourceDetail, "/tmp/plugins/resume-from-opencode")
        XCTAssertEqual(plugins[0].marketplaceDisplayName, "Local marketplace")
        XCTAssertEqual(plugins[0].capabilities, ["skills", "prompts"])
        XCTAssertEqual(plugins[0].detail, "Resume a previous OpenCode session")
        XCTAssertEqual(plugins[1].statusLabel, "Available")
        XCTAssertEqual(plugins[1].sourceLabel, "Remote")
        XCTAssertEqual(
            CodexPluginSummary.loadErrorMessages(from: response),
            ["/tmp/bad-marketplace.json: invalid manifest"]
        )
    }

    func testIntegrationCatalogSessionOwnsMCPAndPluginLoadingState() {
        let mcpResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("filesystem"),
                    "authStatus": .string("unsupported"),
                    "serverInfo": .dictionary([
                        "title": .string("Filesystem")
                    ]),
                    "tools": .dictionary([
                        "read_file": .dictionary([
                            "name": .string("read_file"),
                            "title": .string("Read file")
                        ])
                    ])
                ])
            ])
        ])
        let pluginResponse: CodexJSONValue = .dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("local"),
                    "plugins": .array([
                        .dictionary([
                            "enabled": .bool(true),
                            "id": .string("resume-from-opencode"),
                            "installed": .bool(true),
                            "name": .string("resume-from-opencode"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Resume a previous OpenCode session")
                            ])
                        ])
                    ])
                ])
            ]),
            "marketplaceLoadErrors": .array([
                .dictionary([
                    "marketplacePath": .string("/tmp/bad-marketplace.json"),
                    "message": .string("invalid manifest")
                ])
            ])
        ])

        var session = CodexIntegrationCatalogSession()

        session.requireMCPConnection(message: "Connect first")
        XCTAssertEqual(session.mcpErrorMessage, "Connect first")
        XCTAssertFalse(session.isLoadingMCPServers)

        session.beginMCPRefresh()
        XCTAssertTrue(session.isLoadingMCPServers)
        XCTAssertNil(session.mcpErrorMessage)

        let mcpActivity = session.applyMCPResponse(mcpResponse)
        XCTAssertEqual(mcpActivity, CodexIntegrationCatalogActivity(title: "Loaded MCP servers", detail: "1 configured"))
        XCTAssertEqual(session.mcpServers.map(\.displayName), ["Filesystem"])
        XCTAssertFalse(session.isLoadingMCPServers)

        session.applyMCPStartupStatus(CodexMCPServerStartupStatus(name: "filesystem", status: "ready", error: nil))
        XCTAssertEqual(session.mcpServers[0].startupStatus, "ready")
        session.applyMCPStartupStatus(CodexMCPServerStartupStatus(name: "github", status: "failed", error: "missing token"))
        XCTAssertEqual(session.mcpServers.map(\.name), ["filesystem", "github"])
        XCTAssertEqual(session.mcpServers[1].error, "missing token")

        let failedMCP = session.failMCPRefresh(message: "server unavailable")
        XCTAssertEqual(failedMCP.title, "MCP status unavailable")
        XCTAssertEqual(session.mcpServers, [])
        XCTAssertEqual(session.mcpErrorMessage, "server unavailable")

        session.requirePluginConnection(message: "Connect first")
        XCTAssertEqual(session.pluginErrorMessage, "Connect first")
        XCTAssertEqual(session.pluginLoadErrors, [])
        XCTAssertFalse(session.isLoadingPlugins)

        session.beginPluginRefresh()
        XCTAssertTrue(session.isLoadingPlugins)
        XCTAssertNil(session.pluginErrorMessage)

        let pluginActivity = session.applyPluginResponse(pluginResponse)
        XCTAssertEqual(pluginActivity, CodexIntegrationCatalogActivity(title: "Loaded plugins", detail: "1 available"))
        XCTAssertEqual(session.plugins.map(\.displayName), ["Resume OpenCode"])
        XCTAssertEqual(session.pluginLoadErrors, ["/tmp/bad-marketplace.json: invalid manifest"])
        XCTAssertFalse(session.isLoadingPlugins)

        let failedPlugins = session.failPluginRefresh(message: "bad marketplace")
        XCTAssertEqual(failedPlugins.title, "Plugin list unavailable")
        XCTAssertEqual(session.plugins, [])
        XCTAssertEqual(session.pluginLoadErrors, [])
        XCTAssertEqual(session.pluginErrorMessage, "bad marketplace")
    }

}
