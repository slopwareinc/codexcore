import Foundation
import Observation

/// Owns the transient, non-layout-affecting presentation of a hidden sidebar.
/// The durable pinned/hidden preference remains in `CodexSidebarNavigationSession`.
@MainActor
@Observable
public final class CodexSidebarOverlaySession {
    public private(set) var isPresented = false

    private let dismissalDelay: Duration
    private var dismissalTask: Task<Void, Never>?

    /// A tiny grace period lets the pointer cross from the 8pt reveal strip into
    /// the overlay without flicker. It is deliberately short enough to feel
    /// immediate; the previous 450ms delay made the sidebar feel unresponsive
    /// after the pointer had clearly left it.
    public init(dismissalDelay: Duration = .milliseconds(45)) {
        self.dismissalDelay = dismissalDelay
    }

    public func pointerEnteredRevealRegion() {
        dismissalTask?.cancel()
        dismissalTask = nil
        isPresented = true
    }

    public func pointerExitedRevealRegion() {
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self, dismissalDelay] in
            try? await Task.sleep(for: dismissalDelay)
            guard !Task.isCancelled else { return }
            self?.isPresented = false
            self?.dismissalTask = nil
        }
    }

    public func dismissImmediately() {
        dismissalTask?.cancel()
        dismissalTask = nil
        isPresented = false
    }
}
