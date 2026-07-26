import CoreGraphics
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

    @Test func loadingChatNeverEscapesItsLiveTranscriptViewportAtAnySupportedWidth() {
        let maximumContentWidth = CodexAgentTheme.officialDark.spacing.transcriptMaxWidth
        for width in stride(from: CGFloat(540), through: 2_500, by: 17) {
            for contentOffset in [CGFloat(-240), -120, 0, 120, 240] {
                let layout = CodexTranscriptEmptyStateLayout(
                    viewportWidth: width,
                    requestedHorizontalOffset: contentOffset,
                    horizontalPadding: 28,
                    maximumContentWidth: maximumContentWidth
                )
                #expect(layout.contentWidth <= maximumContentWidth)
                #expect(layout.contentFrame.minX >= 28)
                #expect(layout.contentFrame.maxX <= width - 28)
            }
        }
    }
}
