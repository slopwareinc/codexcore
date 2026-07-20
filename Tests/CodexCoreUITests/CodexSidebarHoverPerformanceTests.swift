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
}
