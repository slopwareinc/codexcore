import CoreGraphics
@testable import CodexCoreUI
import Testing

struct CodexAgentPanelTabStripLayoutTests {
    @Test func tabsShareTheAvailableStripWidth() {
        #expect(
            CodexAgentPanelTabStripLayout.tabWidth(
                availableWidth: 480,
                tabCount: 4
            ) == 120
        )
        #expect(
            CodexAgentPanelTabStripLayout.tabWidth(
                availableWidth: 480,
                tabCount: 2
            ) == 240
        )
    }

    @Test func crowdedTabsRemainReadableAndScroll() {
        #expect(
            CodexAgentPanelTabStripLayout.tabWidth(
                availableWidth: 480,
                tabCount: 6
            ) == 112
        )
    }

    @Test func separatorsDoNotCutThroughTheSelectedTab() {
        #expect(
            !CodexAgentPanelTabStripLayout.showsLeadingDivider(
                tabID: "selected",
                precedingTabID: "first",
                selectedTabID: "selected"
            )
        )
        #expect(
            !CodexAgentPanelTabStripLayout.showsLeadingDivider(
                tabID: "after-selected",
                precedingTabID: "selected",
                selectedTabID: "selected"
            )
        )
        #expect(
            CodexAgentPanelTabStripLayout.showsLeadingDivider(
                tabID: "third",
                precedingTabID: "second",
                selectedTabID: "first"
            )
        )
    }
}
