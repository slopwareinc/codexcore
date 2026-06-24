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

        XCTAssertEqual(panel.tabs.map(\.title), ["Side chat", "Review", "Chandrasekhar", "Copernicus"])
        XCTAssertEqual(panel.tabs[1].id, "review")
        XCTAssertEqual(panel.tabs[1].messages, [])
    }

    func testLifecycleFixtureModelsClosedSubagentsWithoutRuntimeDemoCode() {
        let fixture = AgentUIFixture.make()

        XCTAssertEqual(fixture.lifecycleEvents.count, 2)
        XCTAssertEqual(fixture.lifecycleEvents[0].status, .spawning)
        XCTAssertEqual(fixture.lifecycleEvents[0].agentNames, ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(fixture.lifecycleEvents[1].status, .closed)
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
        XCTAssertEqual(theme.radii.composer, 25)
        XCTAssertEqual(theme.radii.panel, 25)
        XCTAssertTrue(theme.effects.usesLiquidGlass)
        XCTAssertEqual(theme.effects.surfaceOpacity, 0.94)
    }

}
