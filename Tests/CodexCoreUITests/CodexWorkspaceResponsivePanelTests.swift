@testable import CodexCoreUI
import Testing

struct CodexWorkspaceResponsivePanelTests {
    @Test func overviewWaitsForAWideWorkspaceBeforeDocking() {
        #expect(!CodexWorkspaceResponsivePanelState(availableWidth: 1_299).supportsDockedOverviewWithoutSidePanel)
        #expect(CodexWorkspaceResponsivePanelState(availableWidth: 1_300).supportsDockedOverviewWithoutSidePanel)

        #expect(!CodexWorkspaceResponsivePanelState(availableWidth: 1_739).supportsDockedOverviewWithSidePanel)
        #expect(CodexWorkspaceResponsivePanelState(availableWidth: 1_740).supportsDockedOverviewWithSidePanel)
    }
}
