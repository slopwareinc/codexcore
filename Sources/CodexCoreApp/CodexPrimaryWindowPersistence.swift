import Foundation

/// The action to take when AppKit asks the primary window to close.
///
/// Closing the last window is a hide operation in the normal app lifecycle;
/// an explicit application termination request is the only path that closes
/// it for real. Keeping this decision separate from AppKit makes the lifecycle
/// contract testable without creating windows in a test process.
enum CodexPrimaryWindowCloseAction: Equatable {
    case hide
    case close
}

/// The result of validating an autosaved primary-window frame.
struct CodexPrimaryWindowRestorationPlan: Equatable {
    let frame: CGRect?
    let isZoomed: Bool
}

enum CodexPrimaryWindowPersistence {
    /// Returns true when at least some usable area of the frame is on a
    /// visible display. A frame that only touches a display edge is not
    /// considered visible because it has no non-zero intersection.
    static func isFrameOnScreen(_ frame: CGRect, visibleFrames: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return visibleFrames.contains { visibleFrame in
            visibleFrame.width > 0
                && visibleFrame.height > 0
                && visibleFrame.intersects(frame)
        }
    }

    /// Rejects stale autosaved frames left behind by a display that is no
    /// longer attached. Zoom state is returned only with a valid frame so a
    /// bad restore cannot accidentally re-maximize the fallback frame.
    static func restorationPlan(
        savedFrame: CGRect?,
        savedIsZoomed: Bool,
        visibleFrames: [CGRect]
    ) -> CodexPrimaryWindowRestorationPlan {
        guard let savedFrame, isFrameOnScreen(savedFrame, visibleFrames: visibleFrames) else {
            return CodexPrimaryWindowRestorationPlan(frame: nil, isZoomed: false)
        }
        return CodexPrimaryWindowRestorationPlan(frame: savedFrame, isZoomed: savedIsZoomed)
    }

    static func closeAction(isTerminationInProgress: Bool) -> CodexPrimaryWindowCloseAction {
        isTerminationInProgress ? .close : .hide
    }
}
