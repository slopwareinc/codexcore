import AppKit
@testable import CodexCoreUI
import SwiftUI
import Testing

@MainActor
struct CodexSidebarHoverPerformanceTests {
    @Test func hoverTogglesNativeChromeWithoutReplacingSwiftUIContent() {
        let view = SidebarChatRowContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 34)
        )
        view.configure(
            content: AnyView(Text("Task")),
            actions: AnyView(Text("Actions")),
            isSelected: false,
            baseColor: .black,
            selectedColor: .darkGray,
            hoverColor: .gray
        )
        let contentIdentity = view.contentHostIdentityForTesting

        #expect(!view.actionControlsAreVisibleForTesting)
        view.setHoveredForTesting(true)
        #expect(view.actionControlsAreVisibleForTesting)
        #expect(view.contentHostIdentityForTesting == contentIdentity)
        view.setHoveredForTesting(false)
        #expect(!view.actionControlsAreVisibleForTesting)
        #expect(view.contentHostIdentityForTesting == contentIdentity)
    }

    @Test func hiddenSidebarOverlayDismissesOnlyAfterPointerLeavesItsRevealRegion() async throws {
        let session = CodexSidebarOverlaySession(dismissalDelay: .milliseconds(30))

        session.pointerEnteredRevealRegion()
        #expect(session.isPresented)

        session.pointerExitedRevealRegion()
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.isPresented)

        session.pointerEnteredRevealRegion()
        try await Task.sleep(for: .milliseconds(35))
        #expect(session.isPresented)

        session.pointerExitedRevealRegion()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!session.isPresented)
    }

    @Test func hiddenSidebarOverlayCanBeDismissedImmediately() {
        let session = CodexSidebarOverlaySession()

        session.pointerEnteredRevealRegion()
        #expect(session.isPresented)

        session.dismissImmediately()
        #expect(!session.isPresented)
    }

    @Test func defaultOverlayDismissalHasOnlyAHitTestingGracePeriod() async throws {
        let session = CodexSidebarOverlaySession()

        session.pointerEnteredRevealRegion()
        session.pointerExitedRevealRegion()

        try await Task.sleep(for: .milliseconds(25))
        #expect(session.isPresented)

        try await Task.sleep(for: .milliseconds(100))
        #expect(!session.isPresented)
    }

    @Test func windowChromeUsesRoomyTopLeadingInsets() {
        #expect(CodexWindowChromeMetrics.trafficLightLeadingInset == 18)
        #expect(CodexWindowChromeMetrics.trafficLightTopInset == 14)
        #expect(CodexWindowChromeMetrics.sidebarControlTopInset == 7)
        #expect(CodexWindowChromeMetrics.sidebarTrafficLightReserveWidth == 104)
    }
}
