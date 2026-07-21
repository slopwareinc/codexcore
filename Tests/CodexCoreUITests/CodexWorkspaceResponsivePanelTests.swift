@testable import CodexCoreUI
import Testing

struct CodexWorkspaceResponsivePanelTests {
    @MainActor
    @Test func minimumExpandedShellKeepsTheSidebarBesideTheWorkspace() {
        #expect(
            CodexProjectSidebar.minimumExpandedShellWidth
                >= CodexProjectSidebar.minExpandedWidth + 540
        )
    }

    @Test func overviewWaitsForAWideWorkspaceBeforeDocking() {
        #expect(!CodexWorkspaceResponsivePanelState(availableWidth: 1_299).supportsDockedOverviewWithoutSidePanel)
        #expect(CodexWorkspaceResponsivePanelState(availableWidth: 1_300).supportsDockedOverviewWithoutSidePanel)

        #expect(!CodexWorkspaceResponsivePanelState(availableWidth: 1_739).supportsDockedOverviewWithSidePanel)
        #expect(CodexWorkspaceResponsivePanelState(availableWidth: 1_740).supportsDockedOverviewWithSidePanel)
    }
}
