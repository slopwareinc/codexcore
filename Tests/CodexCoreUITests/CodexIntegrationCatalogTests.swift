import XCTest
import AppKit
@testable import CodexCore
@testable import CodexCoreUI

final class CodexIntegrationCatalogTests: XCTestCase {
    func testOfficialPluginNavigationUsesSeparateMarketplaceManageAndDetailPages() {
        XCTAssertNotEqual(CodexPluginRoutePage.plugins, .skills)
        XCTAssertNotEqual(CodexPluginRoutePage.plugins, .manage)
        XCTAssertEqual(CodexPluginRoutePage.pluginDetail("github"), .pluginDetail("github"))
    }

    func testOfficialCatalogLayoutAndExpansionMetricsStayConsistentAcrossTabs() {
        XCTAssertEqual(CodexPluginLayoutMetrics.contentWidth, 736)
        XCTAssertEqual(CodexPluginLayoutMetrics.rowHeight, 64)
        XCTAssertEqual(CodexPluginLayoutMetrics.rowSpacing, 8)
        XCTAssertEqual(
            CodexCatalogSectionPresentation.visibleCount(total: 12, collapsedLimit: 5, isExpanded: false),
            5
        )
        XCTAssertEqual(
            CodexCatalogSectionPresentation.visibleCount(total: 12, collapsedLimit: 5, isExpanded: true),
            12
        )
        XCTAssertEqual(
            CodexCatalogSectionPresentation.moreLabel(
                names: ["One", "Two", "Three", "GitHub", "Slack", "Gmail", "Drive", "Linear"],
                collapsedLimit: 3,
                isExpanded: false
            ),
            "See GitHub, Slack, and 3 more"
        )
        XCTAssertEqual(
            CodexCatalogSectionPresentation.moreLabel(names: ["One", "Two"], collapsedLimit: 5, isExpanded: false),
            nil
        )
        XCTAssertEqual(
            CodexCatalogSectionPresentation.moreLabel(names: ["One", "Two"], collapsedLimit: 1, isExpanded: true),
            "Show less"
        )
    }

    func testSlashCommandsMatchObservedCodexPaletteAndFilter() throws {
        XCTAssertEqual(CodexSlashCommand.observedCommands.map(\.title), [
            "Compact",
            "Fast",
            "Feedback",
            "Fork",
            "Goal",
            "Init",
            "MCP",
            "Model",
            "New chat",
            "Plan mode",
            "Reasoning",
            "Review",
            "Side",
            "Status"
        ])
        let compact = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "compact" })
        XCTAssertNil(compact.draftText)
        XCTAssertTrue(compact.requiresEmptyComposer)
        let mcp = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "mcp" })
        XCTAssertNil(mcp.draftText)
        XCTAssertFalse(mcp.requiresEmptyComposer)

        XCTAssertEqual(CodexSlashCommand.query(from: "/sta"), "sta")
        XCTAssertEqual(CodexSlashCommand.query(from: "  /side please"), "side")
        XCTAssertEqual(CodexSlashCommand.query(from: "Ask about /status"), "status")
        XCTAssertNil(CodexSlashCommand.query(from: "https://example.com/status"))

        XCTAssertEqual(
            CodexSlashCommand.invocation(from: "Ask about /status")?.replacementDraft,
            "Ask about"
        )
        XCTAssertEqual(
            CodexSlashCommand.invocation(from: "/side please")?.replacementDraft,
            "please"
        )

        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/sta").map(\.title),
            ["Status"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/rea").map(\.title),
            ["Reasoning"]
        )
        let precedenceCommands = [
            CodexSlashCommand(id: "prefix", title: "Needle", detail: "detail needle", systemImage: "1"),
            CodexSlashCommand(id: "contains", title: "Contains needle", detail: "detail", systemImage: "2"),
            CodexSlashCommand(id: "detail", title: "Other", detail: "Needle detail", systemImage: "3")
        ]
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(from: precedenceCommands, matching: "/needle").map(\.id),
            ["prefix"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(from: Array(precedenceCommands.dropFirst()), matching: "/needle").map(\.id),
            ["contains"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(from: [precedenceCommands[2]], matching: "/needle").map(\.id),
            ["detail"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/").map(\.title),
            CodexSlashCommand.observedCommands.map(\.title)
        )
        XCTAssertFalse(
            CodexSlashCommand.filteredCommands(matching: "Keep this /")
                .contains(where: { $0.id == "compact" || $0.id == "fork" })
        )
        XCTAssertTrue(
            CodexSlashCommand.filteredCommands(matching: "Keep this /")
                .contains(where: { $0.id == "status" || $0.id == "model" })
        )

        let disabledStatus = try XCTUnwrap(
            CodexSlashCommand.observedCommands.first(where: { $0.id == "status" })
        ).withAvailability(false)
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(from: [disabledStatus], matching: "/"),
            []
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
                                "logo": .string("/tmp/plugins/resume-from-opencode/logo.png"),
                                "logoUrl": .string("https://cdn.example.com/resume.png"),
                                "logoUrlDark": .string("https://cdn.example.com/resume-dark.png"),
                                "composerIconUrl": .string("https://cdn.example.com/resume-composer.png"),
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
            "featuredPluginIds": .array([.string("resume-from-opencode")])
        ])

        let plugins = CodexPluginSummary.plugins(from: response)

        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(plugins[0].name, "resume-from-opencode")
        XCTAssertEqual(plugins[0].protocolID, "resume-from-opencode")
        XCTAssertTrue(plugins[0].isFeatured)
        XCTAssertEqual(plugins[0].displayName, "Resume OpenCode")
        XCTAssertEqual(plugins[0].statusLabel, "Enabled")
        XCTAssertEqual(plugins[0].sourceLabel, "Local")
        XCTAssertEqual(plugins[0].sourceDetail, "/tmp/plugins/resume-from-opencode")
        XCTAssertEqual(plugins[0].marketplaceDisplayName, "Local marketplace")
        XCTAssertEqual(plugins[0].icon.logo, "https://cdn.example.com/resume.png")
        XCTAssertEqual(plugins[0].icon.logoDark, "https://cdn.example.com/resume-dark.png")
        XCTAssertEqual(plugins[0].icon.composerIcon, "https://cdn.example.com/resume-composer.png")
        XCTAssertEqual(
            plugins[0].icon.url(prefersDark: true)?.absoluteString,
            "https://cdn.example.com/resume-dark.png"
        )
        XCTAssertEqual(CodexPluginRouteDetail(plugin: plugins[0]).icon, plugins[0].icon)
        XCTAssertEqual(plugins[0].capabilities, ["skills", "prompts"])
        XCTAssertEqual(plugins[0].detail, "Resume a previous OpenCode session")
        XCTAssertEqual(plugins[1].statusLabel, "Available")
        XCTAssertEqual(plugins[1].sourceLabel, "Remote")
        XCTAssertEqual(
            CodexPluginSummary.loadErrorMessages(from: response),
            ["/tmp/bad-marketplace.json: invalid manifest"]
        )
    }

    func testPluginSummaryResolvesRelativeManifestIconsAgainstPublishedSourcePath() throws {
        let raw: CodexJSONValue = .dictionary([
            "id": .string("gmail@openai-curated-remote"),
            "name": .string("gmail"),
            "installed": .bool(true),
            "enabled": .bool(true),
            "installPolicy": .string("AVAILABLE"),
            "authPolicy": .string("ON_USE"),
            "source": .dictionary([
                "type": .string("local"),
                "path": .string("/tmp/plugins/gmail/0.1.5")
            ]),
            "interface": .dictionary([
                "logo": .string("./assets/gmail.png"),
                "logoDark": .string("assets/gmail-dark.png"),
                "composerIcon": .string("./assets/gmail-small.svg"),
                "capabilities": .array([])
            ])
        ])

        let plugin = try XCTUnwrap(CodexPluginSummary(
            raw: raw,
            marketplace: .init(name: "openai-curated-remote")
        ))

        XCTAssertEqual(plugin.icon.logo, "/tmp/plugins/gmail/0.1.5/assets/gmail.png")
        XCTAssertEqual(plugin.icon.logoDark, "/tmp/plugins/gmail/0.1.5/assets/gmail-dark.png")
        XCTAssertEqual(plugin.icon.composerIcon, "/tmp/plugins/gmail/0.1.5/assets/gmail-small.svg")
    }

    @MainActor
    func testPluginImageRepositoryLoadsAndCachesPublishedLocalAssetOffMain() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-plugin-icon-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let symbol = try XCTUnwrap(NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil))
        try XCTUnwrap(symbol.tiffRepresentation).write(to: temporaryURL)

        let loadedImage = await CodexPluginImageRepository.image(for: temporaryURL)
        XCTAssertNotNil(loadedImage)
        XCTAssertNotNil(CodexPluginImageRepository.cachedOrLocalImage(for: temporaryURL))
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
                    ]),
                    "resources": .array([]),
                    "resourceTemplates": .array([])
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
                            "installPolicy": .string("AVAILABLE"),
                            "authPolicy": .string("ON_USE"),
                            "source": .dictionary(["type": .string("local")]),
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

        let failedMCP = session.failMCPRefresh(message: "server unavailable")
        XCTAssertEqual(failedMCP.title, "MCP status unavailable")
        XCTAssertEqual(session.mcpServers.map(\.displayName), ["Filesystem"])
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

        XCTAssertEqual(
            session.setPluginEnabledOptimistically(id: "resume-from-opencode", enabled: false),
            true
        )
        XCTAssertFalse(session.plugins[0].enabled)
        XCTAssertNil(session.setPluginEnabledOptimistically(id: "missing", enabled: true))

        let failedPlugins = session.failPluginRefresh(message: "bad marketplace")
        XCTAssertEqual(failedPlugins.title, "Plugin list unavailable")
        XCTAssertEqual(session.plugins.map(\.displayName), ["Resume OpenCode"])
        XCTAssertEqual(session.pluginLoadErrors, ["/tmp/bad-marketplace.json: invalid manifest"])
        XCTAssertEqual(session.pluginErrorMessage, "bad marketplace")
    }

    func testCatalogRefreshMergesOnlyTheInventoryThatFinished() {
        let originalPlugin = plugin(
            name: "github",
            displayName: "GitHub",
            detail: "Repositories",
            installed: true,
            enabled: true
        )
        let refreshedPlugin = plugin(
            name: "linear",
            displayName: "Linear",
            detail: "Projects",
            installed: true,
            enabled: true
        )
        let originalSkill = skill(name: "writer", displayName: "Writer", enabled: true)
        var current = CodexIntegrationCatalogSession(plugins: [originalPlugin], skills: [originalSkill])
        let refreshed = CodexIntegrationCatalogSession(plugins: [refreshedPlugin])

        current.merge(refreshed, inventory: .plugins)

        XCTAssertEqual(current.plugins.map(\.displayName), ["Linear"])
        XCTAssertEqual(current.skills.map(\.displayName), ["Writer"])
    }

    func testCatalogSessionOptimisticallyTogglesAndRestoresPluginsAndSkillsByCanonicalIdentity() throws {
        let firstPlugin = plugin(
            name: "github",
            displayName: "GitHub",
            detail: "Triage pull requests",
            installed: true,
            enabled: true
        )
        let secondPlugin = plugin(
            name: "gmail",
            displayName: "Gmail",
            detail: "Manage email",
            installed: true,
            enabled: false
        )
        let firstSkill = skill(name: "shared-name", displayName: "Personal Skill", enabled: true)
        var secondSkill = skill(name: "shared-name", displayName: "System Skill", enabled: false)
        secondSkill.path = "/tmp/system-skills/shared-name/SKILL.md"
        secondSkill.scope = "system"
        var session = CodexIntegrationCatalogSession(
            plugins: [firstPlugin, secondPlugin],
            skills: [firstSkill, secondSkill]
        )

        let pluginPrevious = session.setPluginEnabledOptimistically(id: firstPlugin.protocolID, enabled: false)
        XCTAssertEqual(pluginPrevious, true)
        XCTAssertEqual(session.plugins.map(\.enabled), [false, false])
        _ = session.setPluginEnabledOptimistically(id: firstPlugin.protocolID, enabled: try XCTUnwrap(pluginPrevious))
        XCTAssertEqual(session.plugins.map(\.enabled), [true, false])

        let skillPrevious = session.setSkillEnabledOptimistically(path: secondSkill.path, enabled: true)
        XCTAssertEqual(skillPrevious, false)
        XCTAssertEqual(session.skills.map(\.enabled), [true, true])
        _ = session.setSkillEnabledOptimistically(path: secondSkill.path, enabled: try XCTUnwrap(skillPrevious))
        XCTAssertEqual(session.skills.map(\.enabled), [true, false])

        XCTAssertNil(session.setPluginEnabledOptimistically(id: "missing", enabled: true))
        XCTAssertNil(session.setSkillEnabledOptimistically(path: "/missing/SKILL.md", enabled: true))
    }

    func testBrowserLauncherUsesCatalogDetailWithOracleMetadata() throws {
        let browser = CodexPluginSummary(
            id: "local:browser",
            name: "browser",
            displayName: "Browser",
            shortDescription: "Control the in-app browser with Codex",
            longDescription: "Open and control the in-app browser for local development pages and files; navigate, inspect, click, type, and take screenshots.",
            marketplaceName: "local",
            marketplaceDisplayName: "Local",
            category: "Engineering",
            developerName: "OpenAI",
            installed: true,
            enabled: true,
            installPolicy: "INSTALLED_BY_DEFAULT",
            sourceType: "local",
            localVersion: "26.616.81150",
            defaultPrompt: "Browser\nTest my checkout flow on localhost",
            websiteURL: "https://openai.com",
            privacyPolicyURL: "https://openai.com/privacy",
            termsOfServiceURL: "https://openai.com/terms",
            capabilities: ["Interactive", "Read", "Write"]
        )
        let detail = CodexPluginRouteDetail(plugin: browser)

        XCTAssertEqual(detail.title, "Browser")
        XCTAssertEqual(detail.detail, "Control the in-app browser with Codex")
        XCTAssertEqual(detail.prompt, "Browser\nTest my checkout flow on localhost")
        XCTAssertEqual(detail.tryInChatAction, .tryInChat(prompt: "Browser\nTest my checkout flow on localhost"))
        XCTAssertEqual(detail.capabilities, ["Interactive", "Read", "Write"])
        XCTAssertTrue(detail.metadata.contains("Developer: OpenAI"))
        XCTAssertTrue(detail.metadata.contains("Category: Engineering"))
        XCTAssertTrue(detail.metadata.contains("Version: 26.616.81150"))
        XCTAssertTrue(detail.legalLinks.contains("Website: https://openai.com"))
        XCTAssertTrue(detail.legalLinks.contains("Privacy: https://openai.com/privacy"))
        XCTAssertTrue(detail.legalLinks.contains("Terms: https://openai.com/terms"))
    }

    func testComputerUseLauncherFallsBackToInstallAndPermissionBoundary() throws {
        let detail = CodexComposerPluginLauncher.computerUse.fallbackDetail

        XCTAssertEqual(detail.title, "Computer Use")
        XCTAssertEqual(detail.detail, "Control Mac apps")
        XCTAssertEqual(detail.statusLabel, "Install boundary")
        XCTAssertEqual(detail.boundaryActionTitle, "Add")
        XCTAssertNil(detail.primaryAction)
        XCTAssertTrue(detail.description.contains("does not invoke the permission flow"))
        XCTAssertTrue(detail.capabilities.contains("Appshot boundary"))
        XCTAssertTrue(detail.metadata.contains("Package: Computer Use"))
        XCTAssertTrue(detail.metadata.contains("Package: Appshot"))
    }

    func testArtifactLauncherFallsBackToNonCodeBoundaryCard() throws {
        let target = CodexComposerPluginLauncher.artifact(.documents)
        let detail = target.fallbackDetail

        XCTAssertEqual(detail.title, "Documents")
        XCTAssertEqual(detail.statusLabel, "Artifact boundary")
        XCTAssertEqual(detail.capabilities, ["Document artifacts"])
        XCTAssertTrue(detail.description.contains("does not invoke artifact generation"))
    }

    func testSkillRouteDetailUsesAuthoritativeSkillState() {
        let enabled = skill(
            name: "browser:control",
            displayName: "Control Browser",
            detail: "Operate browser tabs",
            description: "Control the in-app browser.",
            enabled: true,
            prompt: "Use the browser to inspect localhost."
        )
        let detail = CodexPluginRouteDetail(skill: enabled)
        XCTAssertEqual(detail.title, "Control Browser")
        XCTAssertEqual(detail.statusLabel, "Enabled")
        XCTAssertEqual(detail.prompt, "Use the browser to inspect localhost.")
        XCTAssertEqual(detail.primaryAction, .setSkillEnabled(CodexSkillActionTarget(skill: enabled), enabled: false))
        XCTAssertEqual(detail.tryInChatAction, .tryInChat(prompt: "Use the browser to inspect localhost."))
        XCTAssertTrue(detail.canUninstall)
    }

    func testPluginProtocolMutationsUseServerIdentityAndExplicitControlPlaneSeams() throws {
        let available = plugin(
            name: "github",
            displayName: "GitHub",
            detail: "Triage PRs and issues",
            installed: false,
            enabled: false,
            installPolicy: "AVAILABLE"
        )
        let target = CodexPluginActionTarget(plugin: available)

        XCTAssertEqual(target.id, "github@local")

        let install = CodexPluginProtocolMutation.installParams(for: target)
        XCTAssertEqual(install.pluginName, "github")
        XCTAssertEqual(install.marketplacePath?.rawValue, .string("/tmp/marketplace.json"))
        XCTAssertNil(install.remoteMarketplaceName)

        let remote = CodexPluginSummary(
            id: "openai-curated-remote:gmail",
            protocolID: "gmail@openai-curated-remote",
            name: "gmail",
            marketplaceName: "openai-curated-remote",
            installed: false,
            enabled: false,
            installPolicy: "AVAILABLE"
        )
        let remoteInstall = CodexPluginProtocolMutation.installParams(for: .init(plugin: remote))
        XCTAssertNil(remoteInstall.marketplacePath)
        XCTAssertEqual(remoteInstall.remoteMarketplaceName, "openai-curated-remote")
        XCTAssertEqual(remoteInstall.pluginName, "gmail")

        let uninstall = CodexPluginProtocolMutation.uninstallParams(for: target)
        XCTAssertEqual(uninstall.pluginID, "github@local")

        let configTarget = CodexPluginProtocolMutation.ConfigWriteTarget(
            filePath: "/tmp/config.toml",
            expectedVersion: "sha256:current"
        )
        let toggle = CodexPluginProtocolMutation.pluginEnabledParams(
            for: target,
            enabled: false,
            configTarget: configTarget
        )
        XCTAssertEqual(toggle.edits.count, 1)
        XCTAssertEqual(toggle.edits[0].keyPath, "plugins.github@local.enabled")
        XCTAssertEqual(toggle.edits[0].mergeStrategy, .upsert)
        XCTAssertEqual(toggle.edits[0].value, .bool(false))
        XCTAssertEqual(toggle.filePath, configTarget.filePath)
        XCTAssertEqual(toggle.expectedVersion, configTarget.expectedVersion)
        XCTAssertEqual(toggle.reloadUserConfig, true)

        let skillTarget = CodexSkillActionTarget(skill: skill(
            name: "browser:control",
            displayName: "Control Browser",
            enabled: true
        ))
        let skillToggle = CodexPluginProtocolMutation.skillEnabledParams(for: skillTarget, enabled: false)
        XCTAssertEqual(skillToggle.name, "browser:control")
        XCTAssertNil(skillToggle.path, "Namespaced plugin skills are addressed by name in the official control plane")
        XCTAssertFalse(skillToggle.enabled)

        let personalSkillTarget = CodexSkillActionTarget(skill: skill(
            name: "release-notes",
            displayName: "Release Notes",
            enabled: true
        ))
        let personalSkillToggle = CodexPluginProtocolMutation.skillEnabledParams(
            for: personalSkillTarget,
            enabled: false
        )
        XCTAssertNil(personalSkillToggle.name)
        XCTAssertEqual(personalSkillToggle.path?.rawValue, .string(personalSkillTarget.path))

        // Codex exposes no generated skill-uninstall operation. The UI must not
        // substitute recursive filesystem deletion for one.
    }

    func testPluginConfigUsesLatestUserLayerAsAuthoritativeEnablement() throws {
        let old = CodexSchemaConfigLayer(
            config: .dictionary(["plugins": .dictionary([
                "github@openai-curated-remote": .dictionary(["enabled": .bool(true)])
            ])]),
            name: .init(.dictionary([
                "type": .string("user"),
                "file": .string("/tmp/old.toml")
            ])),
            version: "old"
        )
        let current = CodexSchemaConfigLayer(
            config: .dictionary(["plugins": .dictionary([
                "github@openai-curated-remote": .dictionary(["enabled": .bool(false)])
            ])]),
            name: .init(.dictionary([
                "type": .string("user"),
                "file": .string("/tmp/config.toml")
            ])),
            version: "current"
        )
        let response = CodexSchemaConfigReadResponse(
            config: .init(),
            layers: [old, current],
            origins: [:]
        )

        XCTAssertEqual(
            CodexPluginProtocolMutation.userConfigTarget(from: response),
            .init(filePath: "/tmp/config.toml", expectedVersion: "current")
        )
        XCTAssertEqual(
            CodexPluginProtocolMutation.configuredPluginEnabled(from: response),
            ["github@openai-curated-remote": false]
        )
    }

    func testSkillSummariesParseAppServerSkillsForRoute() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "cwd": .string("/tmp/CodexCore"),
                    "skills": .array([
                        .dictionary([
                            "name": .string("browser:control"),
                            "description": .string("Control the in-app browser."),
                            "shortDescription": .string("Browser control"),
                            "interface": .dictionary([
                                "displayName": .string("Control Browser"),
                                "shortDescription": .string("Operate browser tabs"),
                                "defaultPrompt": .array([.string("Use the browser"), .string("Inspect localhost")])
                            ]),
                            "path": .string("/tmp/skills/browser/SKILL.md"),
                            "scope": .string("user"),
                            "enabled": .bool(true),
                            "dependencies": .dictionary([
                                "tools": .array([
                                    .dictionary([
                                        "type": .string("binary"),
                                        "value": .string("playwright")
                                    ])
                                ])
                            ])
                        ])
                    ]),
                    "errors": .array([])
                ])
            ])
        ])

        let skills = CodexSkillSummary.skills(from: response)

        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].displayName, "Control Browser")
        XCTAssertEqual(skills[0].detail, "Operate browser tabs")
        XCTAssertEqual(skills[0].defaultPrompt, "Use the browser\nInspect localhost")
        XCTAssertEqual(skills[0].scopeLabel, "Personal")
        XCTAssertEqual(skills[0].dependencies, ["binary: playwright"])

        var session = CodexIntegrationCatalogSession()
        let activity = session.applySkillResponse(response)
        XCTAssertEqual(activity, CodexIntegrationCatalogActivity(title: "Loaded skills", detail: "1 available"))
        XCTAssertEqual(session.skills, skills)
    }


    func testMCPProtocolMutationsUseGeneratedConfigWriteAndReloadSeams() throws {
        let configuration = CodexMCPServerConfiguration(
            name: "filesystem",
            enabled: true,
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            workingDirectory: "/workspace",
            environment: ["TOKEN": "secret"],
            environmentPassthrough: ["HOME", "PATH"],
            startupTimeoutSeconds: 10,
            toolTimeoutSeconds: 60,
            enabledTools: ["read_file"],
            disabledTools: ["delete_file"]
        )
        let save = try CodexMCPProtocolMutation.save(configuration)
        guard case .configValueWrite(let params) = save else {
            return XCTFail("MCP save must use config/value/write")
        }
        XCTAssertEqual(save.operationID, "config/value/write")
        XCTAssertEqual(params.keyPath, "mcp_servers.filesystem")
        XCTAssertEqual(params.mergeStrategy, .replace)
        XCTAssertEqual(params.value, .dictionary([
            "enabled": .bool(true),
            "command": .string("npx"),
            "args": .array([
                .string("-y"),
                .string("@modelcontextprotocol/server-filesystem"),
                .string("/tmp")
            ]),
            "env": .dictionary(["TOKEN": .string("secret")]),
            "env_vars": .array([.string("HOME"), .string("PATH")]),
            "cwd": .string("/workspace"),
            "enabled_tools": .array([.string("read_file")]),
            "disabled_tools": .array([.string("delete_file")]),
            "startup_timeout_sec": .double(10),
            "tool_timeout_sec": .double(60)
        ]))

        let toggle = try CodexMCPProtocolMutation.setEnabled(name: "filesystem", enabled: false)
        guard case .configValueWrite(let toggleParams) = toggle else {
            return XCTFail("MCP enablement must use config/value/write")
        }
        XCTAssertEqual(toggleParams.keyPath, "mcp_servers.filesystem.enabled")
        XCTAssertEqual(toggleParams.value, .bool(false))

        let remove = try CodexMCPProtocolMutation.remove(name: "filesystem")
        guard case .configValueWrite(let removeParams) = remove else {
            return XCTFail("MCP removal must use config/value/write")
        }
        XCTAssertEqual(removeParams.keyPath, "mcp_servers.filesystem")
        XCTAssertEqual(removeParams.value, .null)
        XCTAssertThrowsError(try CodexMCPProtocolMutation.remove(name: "not valid"))
    }

    func testMCPHTTPConfigurationAndOAuthUseCurrentProtocolInventory() throws {
        let configuration = CodexMCPServerConfiguration(
            name: "remote-tools",
            transport: .streamableHTTP,
            url: "https://example.test/mcp",
            bearerTokenEnvironmentVariable: "MCP_TOKEN",
            httpHeaders: ["X-Workspace": "demo"],
            environmentHTTPHeaders: ["Authorization": "MCP_AUTH_HEADER"]
        )
        let request = try CodexMCPProtocolMutation.save(configuration)
        guard case .configValueWrite(let params) = request else {
            return XCTFail("MCP HTTP save must use config/value/write")
        }
        XCTAssertEqual(params.value, .dictionary([
            "enabled": .bool(true),
            "url": .string("https://example.test/mcp"),
            "http_headers": .dictionary(["X-Workspace": .string("demo")]),
            "env_http_headers": .dictionary(["Authorization": .string("MCP_AUTH_HEADER")]),
            "bearer_token_env_var": .string("MCP_TOKEN")
        ]))

        let oauth = CodexIntegrationControlPlaneRequest.mcpOAuthLogin(.init(name: "remote-tools"))
        XCTAssertEqual(oauth.operationID, "mcpServer/oauth/login")
        XCTAssertEqual(CodexIntegrationControlPlaneRequest.mcpReload.operationID, "config/mcpServer/reload")
    }

}

private func plugin(
    name: String,
    displayName: String,
    detail: String,
    installed: Bool,
    enabled: Bool,
    installPolicy: String = "INSTALLED_BY_DEFAULT",
    category: String? = nil,
    developer: String? = nil,
    version: String? = nil,
    prompt: String? = nil,
    capabilities: [String] = [],
    website: String? = nil,
    privacy: String? = nil,
    terms: String? = nil
) -> CodexPluginSummary {
    CodexPluginSummary(
        id: "local:\(name)",
        protocolID: "\(name)@local",
        name: name,
        displayName: displayName,
        shortDescription: detail,
        longDescription: "\(detail). Long description.",
        marketplaceName: "local",
        marketplaceDisplayName: "Local",
        marketplacePath: "/tmp/marketplace.json",
        category: category,
        developerName: developer,
        installed: installed,
        enabled: enabled,
        installPolicy: installPolicy,
        sourceType: "local",
        sourceDetail: "/tmp/plugins/\(name)",
        localVersion: version,
        defaultPrompt: prompt,
        websiteURL: website,
        privacyPolicyURL: privacy,
        termsOfServiceURL: terms,
        capabilities: capabilities,
        keywords: [name]
    )
}

private func skill(
    name: String,
    displayName: String,
    detail: String = "Skill detail",
    description: String = "Skill description",
    enabled: Bool,
    prompt: String? = nil
) -> CodexSkillSummary {
    CodexSkillSummary(
        name: name,
        displayName: displayName,
        detail: detail,
        description: description,
        path: "/tmp/skills/\(name)/SKILL.md",
        scope: "user",
        enabled: enabled,
        defaultPrompt: prompt,
        dependencies: ["skill"]
    )
}
