import XCTest
import SwiftUI
@testable import CodexCore
@testable import CodexCoreUI

extension CodexAgentUITests {
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

}
