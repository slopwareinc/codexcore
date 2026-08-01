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
            hoverColor: .gray.opacity(0.08),
            selectionColor: .blue.opacity(0.08),
            isSelected: false
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

    /// Regression coverage for a solid-black chat row appearing in a light
    /// window: `configure` used to pre-resolve `baseColor`/`elevatedColor` to
    /// `NSColor` immediately, inside SwiftUI's update pass rather than a draw
    /// pass, which froze them against whatever appearance happened to be
    /// ambient at that moment rather than this view's own. `configure` now
    /// takes SwiftUI `Color`s and resolves them lazily against
    /// `effectiveAppearance` inside `updateChrome()`. This forces the view
    /// into a window with a known, mismatched appearance and asserts the
    /// painted hover color still matches what that window asked for.
    @Test func hoverColorMatchesTheViewsOwnAppearanceNotTheAmbientOne() {
        let elevated = CodexColorPair(light: 0xEEEEEE, dark: 0x111111)

        let previousAmbient = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .darkAqua)
        defer { NSAppearance.current = previousAmbient }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 34),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)

        let view = SidebarChatRowContainerView(frame: NSRect(x: 0, y: 0, width: 260, height: 34))
        window.contentView?.addSubview(view)
        view.configure(
            content: AnyView(Text("Task")),
            actions: AnyView(Text("Actions")),
            hoverColor: elevated.color.opacity(0.08),
            selectionColor: .clear,
            isSelected: false
        )

        view.setHoveredForTesting(true)
        let painted = view.backgroundColorForTesting

        // The window is pinned to Light; the process-ambient appearance is
        // Dark. A resolution that leaked the ambient appearance would paint
        // something close to `elevated.dark` (near-black); the correct
        // result is close to `elevated.light` (near-white).
        #expect(isNear(painted, hex: 0xEEEEEE), "painted \(painted) should resolve to the window's Light appearance")
        #expect(!isNear(painted, hex: 0x111111), "painted \(painted) leaked the ambient Dark appearance")
        #expect(painted.alphaComponent < 0.1)
    }

    @Test func selectedRowUsesOneTranslucentSelectionOverlayWhenHovered() {
        let view = SidebarChatRowContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 34)
        )
        view.configure(
            content: AnyView(Text("Selected task")),
            actions: AnyView(Text("Actions")),
            hoverColor: .gray.opacity(0.08),
            selectionColor: .red.opacity(0.08),
            isSelected: true
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.contentHostWidthForTesting == 260)

        view.setHoveredForTesting(true)
        view.layoutSubtreeIfNeeded()

        #expect(view.backgroundColorForTesting.alphaComponent < 0.1)
        #expect(view.contentHostWidthForTesting == 200)
        #expect(view.actionControlsAreVisibleForTesting)
    }

    private func isNear(_ color: NSColor, hex: UInt32) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return abs(Double(rgb.redComponent) - r) < 0.1
            && abs(Double(rgb.greenComponent) - g) < 0.1
            && abs(Double(rgb.blueComponent) - b) < 0.1
    }

    @Test func rowsKeepActionsHiddenUntilHovered() {
        let view = SidebarChatRowContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 31)
        )
        view.configure(
            content: AnyView(Text("Selected task")),
            actions: AnyView(Text("Actions")),
            hoverColor: .gray.opacity(0.08),
            selectionColor: .blue.opacity(0.08),
            isSelected: false
        )

        #expect(!view.actionControlsAreVisibleForTesting)
        view.setHoveredForTesting(true)
        #expect(view.actionControlsAreVisibleForTesting)
    }

    @Test func scrollReconciliationKeepsOnlyThePointerRowHovered() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = SidebarChatRowContainerView(frame: NSRect(x: 24, y: 24, width: 260, height: 34))
        window.contentView?.addSubview(view)
        view.configure(
            content: AnyView(Text("Task")),
            actions: AnyView(Text("Actions")),
            hoverColor: .gray.opacity(0.08),
            selectionColor: .clear,
            isSelected: false
        )

        view.setHoveredForTesting(true)
        #expect(view.actionControlsAreVisibleForTesting)

        view.reconcileHoverForTesting(pointerLocationInWindow: NSPoint(x: 390, y: 190))
        #expect(!view.actionControlsAreVisibleForTesting)

        view.reconcileHoverForTesting(pointerLocationInWindow: NSPoint(x: 40, y: 40))
        #expect(view.actionControlsAreVisibleForTesting)
    }

    @Test func idleRowsDoNotReserveTrailingStatusWidth() {
        #expect(
            !SidebarChatRowLayout.hasTrailingStatus(
                attentionState: .idle,
                showsRecency: false,
                recencyLabel: ""
            )
        )
        #expect(
            SidebarChatRowLayout.hasTrailingStatus(
                attentionState: .running,
                showsRecency: false,
                recencyLabel: ""
            )
        )
        #expect(
            SidebarChatRowLayout.hasTrailingStatus(
                attentionState: .idle,
                showsRecency: true,
                recencyLabel: "2m"
            )
        )
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
        for _ in 0..<100 where session.isPresented {
            try await Task.sleep(for: .milliseconds(10))
        }
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
