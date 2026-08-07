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

        #expect(
            !CodexWorkspaceResponsivePanelState(
                availableWidth: 1_979,
                sidePanelWidth: 680
            ).supportsDockedOverviewWithSidePanel
        )
        #expect(
            CodexWorkspaceResponsivePanelState(
                availableWidth: 1_980,
                sidePanelWidth: 680
            ).supportsDockedOverviewWithSidePanel
        )
    }

    @Test func onlyAnOverlaySidePanelOwnsAnInternalCloseButton() {
        let overlay = CodexWorkspaceResponsivePanelState(availableWidth: 1_191)
        #expect(overlay.usesOverlaySidePanel)
        #expect(overlay.showsCloseButtonInsideSidePanel)

        let persistent = CodexWorkspaceResponsivePanelState(availableWidth: 1_192)
        #expect(persistent.usesPersistentSidePanel)
        #expect(!persistent.showsCloseButtonInsideSidePanel)
    }

    @Test func resizedPanelOnlyDocksWhenTheChatKeepsItsReadableWidth() {
        let overlay = CodexWorkspaceResponsivePanelState(
            availableWidth: 1_471,
            sidePanelWidth: 680
        )
        #expect(overlay.usesOverlaySidePanel)
        #expect(overlay.showsCloseButtonInsideSidePanel)

        let persistent = CodexWorkspaceResponsivePanelState(
            availableWidth: 1_472,
            sidePanelWidth: 680
        )
        #expect(persistent.usesPersistentSidePanel)
        #expect(!persistent.showsCloseButtonInsideSidePanel)
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
