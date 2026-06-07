import XCTest
import SwiftUI
@testable import CodexCoreUI

final class CodexAgentUITests: XCTestCase {
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
                authLabel: "Testing",
                isAuthenticated: false,
                isThreadReady: false,
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

private struct AgentUIFixture {
    var sideChat: CodexSideChatState
    var subagents: [CodexSubagentState]
    var lifecycleEvents: [CodexAgentLifecycleEvent]

    static func make() -> AgentUIFixture {
        let now = Date(timeIntervalSince1970: 1_000)
        let sideChat = CodexSideChatState(
            messages: [
                CodexChatMessage(role: .user, text: "Open a focused branch", createdAt: now),
                CodexChatMessage(role: .assistant, text: "Branch ready", createdAt: now.addingTimeInterval(1))
            ],
            createdAt: now
        )

        let subagents = [
            CodexSubagentState(
                name: "Chandrasekhar",
                title: "Chat and composer inspection",
                prompt: "Inspect chat/composer UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Chat/composer findings", createdAt: now.addingTimeInterval(2))],
                createdAt: now,
                completedAt: now.addingTimeInterval(2)
            ),
            CodexSubagentState(
                name: "Copernicus",
                title: "Side panel inspection",
                prompt: "Inspect side panel UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Side-panel findings", createdAt: now.addingTimeInterval(3))],
                createdAt: now,
                completedAt: now.addingTimeInterval(3)
            )
        ]

        let lifecycleEvents = [
            CodexAgentLifecycleEvent(
                status: .spawning,
                title: "Spawned 2 agents",
                agentNames: subagents.map(\.name),
                createdAt: now.addingTimeInterval(1)
            ),
            CodexAgentLifecycleEvent(
                status: .closed,
                title: "Closed 2 agents",
                agentNames: subagents.map(\.name),
                createdAt: now.addingTimeInterval(4)
            )
        ]

        return AgentUIFixture(sideChat: sideChat, subagents: subagents, lifecycleEvents: lifecycleEvents)
    }
}
