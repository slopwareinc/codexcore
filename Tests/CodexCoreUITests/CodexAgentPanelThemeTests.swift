import XCTest
import SwiftUI
@testable import CodexCore
@testable import CodexCoreUI

final class CodexAgentPanelThemeTests: XCTestCase {
    func testAgentPanelStateBuildsSideChatAndSubagentTabs() {
        let fixture = AgentUIFixture.make()
        let panel = CodexAgentPanelState(
            isOpen: true,
            selectedTabID: fixture.subagents[0].id,
            sideChat: fixture.sideChat,
            subagents: fixture.subagents
        )

        XCTAssertTrue(panel.isOpen)
        XCTAssertEqual(panel.tabs.map(\.title), ["Side chat", "Chandrasekhar", "Copernicus"])
        XCTAssertEqual(panel.tabs[1].messages.last?.text, "Chat/composer findings")
        XCTAssertEqual(panel.tabs[2].messages.last?.text, "Side-panel findings")
    }

    func testAgentPanelStateAddsReviewTabWhenGitReviewSessionExists() {
        let fixture = AgentUIFixture.make()
        let review = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            files: [
                CodexGitReviewFileChange(path: "Sources/Review.swift", status: .modified, isStaged: false, addedLines: 2)
            ]
        ))
        let panel = CodexAgentPanelState(
            isOpen: true,
            sideChat: fixture.sideChat,
            subagents: fixture.subagents,
            gitReviewSession: review
        )

        XCTAssertEqual(panel.tabs.map(\.title), ["Review", "Side chat", "Chandrasekhar", "Copernicus"])
        XCTAssertEqual(panel.tabs[0].id, "review")
        XCTAssertEqual(panel.tabs[0].messages, [])
        XCTAssertEqual(panel.tabs[1].id, CodexSideChatState.defaultID)
    }

    func testAgentPanelStateSelectsSideChatBesideReviewWhenOpened() {
        let fixture = AgentUIFixture.make()
        let review = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            files: [
                CodexGitReviewFileChange(path: "Sources/Review.swift", status: .modified, isStaged: false)
            ]
        ))

        let panel = CodexAgentPanelState(
            isOpen: true,
            selectedTabID: CodexSideChatState.defaultID,
            sideChat: CodexSideChatState(createdAt: fixture.sideChat.createdAt),
            subagents: fixture.subagents,
            gitReviewSession: review
        )

        XCTAssertEqual(panel.tabs.map(\.title), ["Review", "Side chat", "Chandrasekhar", "Copernicus"])
        XCTAssertEqual(panel.selectedTab?.id, CodexSideChatState.defaultID)
        XCTAssertEqual(panel.selectedTab?.messages, [])
    }

    func testWorkspaceResponsivePanelStateSwitchesSummaryAndSidePanelModes() {
        let wide = CodexWorkspaceResponsivePanelState(availableWidth: 1_180)

        XCTAssertTrue(wide.usesFloatingSummaryPanel)
        XCTAssertTrue(wide.usesPersistentSidePanel)
        XCTAssertFalse(wide.usesOverlaySummaryPanel)
        XCTAssertFalse(wide.usesOverlaySidePanel)

        let narrow = CodexWorkspaceResponsivePanelState(availableWidth: 860)

        XCTAssertFalse(narrow.usesFloatingSummaryPanel)
        XCTAssertFalse(narrow.usesPersistentSidePanel)
        XCTAssertTrue(narrow.usesOverlaySummaryPanel)
        XCTAssertTrue(narrow.usesOverlaySidePanel)
    }

    @MainActor
    func testThemePresetsExposeUserSelectableThemes() {
        XCTAssertEqual(CodexAgentThemePreset.allCases.map(\.displayName), [
            "Official Dark",
            "Native Light",
            "Midnight",
            "Warm Minimal",
            "High Contrast"
        ])

        for preset in CodexAgentThemePreset.allCases {
            let view = CodexChatWorkspaceView(
                messages: [],
                lifecycleEvents: [],
                sideChat: nil,
                subagents: [],
                activities: [],
                connectionState: .disconnected,
                workspacePath: "/tmp",
                draft: .constant(""),
                isSending: false,
                canSend: false,
                onSend: {},
                onInterrupt: {},
                onDisconnect: {}
            )
            .codexAgentTheme(preset.theme)

            withExtendedLifetime(view) {}
        }
    }

    func testOfficialDarkThemeTracksObservedCodexAppDesignInvariants() {
        let theme = CodexAgentTheme.officialDark

        XCTAssertEqual(theme.spacing.transcriptMaxWidth, 736)
        XCTAssertEqual(theme.spacing.composerMaxWidth, 736)
        XCTAssertEqual(theme.spacing.sidePanelWidth, 320)
        XCTAssertEqual(theme.spacing.summaryPanelWidth, 300)
        XCTAssertEqual(theme.spacing.toolbarHeight, 46)
        XCTAssertEqual(theme.spacing.chatLineSpacing, 4.8)
        XCTAssertEqual(theme.radii.composer, 28)
        XCTAssertEqual(theme.radii.panel, 28)
        XCTAssertTrue(theme.effects.usesLiquidGlass)
        XCTAssertEqual(theme.effects.surfaceOpacity, 0.85)
    }

    func testOfficialThemeCentralizesSidebarTypographyTokens() throws {
        let typography = CodexAgentTheme.officialDark.fonts.sidebar

        XCTAssertEqual(typography.commandTitle.size, 12)
        XCTAssertEqual(typography.commandTitle.weight, .medium)
        XCTAssertEqual(typography.projectTitle.size, 12)
        XCTAssertEqual(typography.chatTitle.size, 12)
        XCTAssertEqual(typography.sectionHeader.size, 10)
        XCTAssertEqual(typography.chatRecency.size, 9)
        XCTAssertEqual(typography.chatActionIcon.size, 8)
        XCTAssertEqual(typography.commandRowHeight, 32)
        XCTAssertEqual(typography.projectRowHeight, 31)
        XCTAssertEqual(typography.chatRowHeight, 30)
        XCTAssertEqual(typography.sectionHeaderHeight, 26)
        XCTAssertEqual(typography.accountFooterHeight, 44)

        let largerTypography = CodexAgentTheme.Fonts.SidebarTypography.official(baseTextSize: 16)
        XCTAssertEqual(largerTypography.commandTitle.size, 16)
        XCTAssertEqual(largerTypography.sectionHeader.size, 14)
        XCTAssertEqual(largerTypography.commandRowHeight, 36)
        XCTAssertEqual(largerTypography.chatRowHeight, 34)

        let encoded = try JSONEncoder().encode(typography)
        let decoded = try JSONDecoder().decode(CodexAgentTheme.Fonts.SidebarTypography.self, from: encoded)
        XCTAssertEqual(decoded, typography)
    }

    func testAppearanceSettingsCodableAndBuildTheme() throws {
        var settings = CodexAppearanceSettings.official
        settings.mode = .dark
        settings.uiFontSize = 16
        settings.reduceMotion = true
        settings.darkTheme.accent = CodexThemeColorValue(hex: "#339CFF")
        settings.darkTheme.background = CodexThemeColorValue(hex: "#111111")
        settings.darkTheme.foreground = CodexThemeColorValue(hex: "#F7F7F7")
        settings.darkTheme.translucentSidebar = false
        settings.darkTheme.contrast = 72

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CodexAppearanceSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.darkTheme.accent.hexString, "#339CFF")
        XCTAssertEqual(decoded.uiFontSize, 16)

        let theme = decoded.effectiveTheme(systemIsDark: false)
        XCTAssertFalse(theme.effects.usesLiquidGlass)
        XCTAssertEqual(theme.effects.surfaceOpacity, 0.98)
        XCTAssertEqual(theme.fonts.sidebar.commandTitle.size, 12)
    }

    func testAppearanceSettingsDefaultToCodexDark() {
        let settings = CodexAppearanceSettings.official

        XCTAssertEqual(settings.mode, .dark)
        XCTAssertEqual(settings.darkTheme.background.hexString, "#111111")
    }

    func testSettingsRoutesExposeProductionShellPages() {
        XCTAssertEqual(CodexSettingsRoute.allCases.map(\.title), [
            "General",
            "Appearance",
            "Profile",
            "Configuration",
            "Git",
            "Integrations",
            "About"
        ])

        XCTAssertTrue(CodexSettingsRoute.appearance.searchTerms.contains("theme"))
        XCTAssertTrue(CodexSettingsRoute.integrations.searchTerms.contains("mcp"))
    }

    func testGitSettingsCodableDefaults() throws {
        var settings = CodexGitSettings.defaults
        settings.branchPrefix = "codex/"
        settings.mergeMethod = .squash
        settings.createsDraftPullRequests = true
        settings.commitInstructions = "Use concise messages"

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CodexGitSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.branchPrefix, "codex/")
        XCTAssertEqual(decoded.mergeMethod.displayName, "Squash")
    }

}
