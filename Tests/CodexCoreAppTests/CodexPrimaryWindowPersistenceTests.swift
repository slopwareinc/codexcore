import CoreGraphics
import XCTest
@testable import CodexCoreApp

final class CodexPrimaryWindowPersistenceTests: XCTestCase {
    func testFrameOnScreenRequiresNonZeroIntersection() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertTrue(CodexPrimaryWindowPersistence.isFrameOnScreen(
            CGRect(x: 1_000, y: 100, width: 800, height: 600),
            visibleFrames: [screen]
        ))
        XCTAssertFalse(CodexPrimaryWindowPersistence.isFrameOnScreen(
            CGRect(x: 1_440, y: 100, width: 800, height: 600),
            visibleFrames: [screen]
        ))
    }

    func testFrameOnScreenAcceptsAnyAttachedDisplay() {
        let displays = [
            CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
        ]

        XCTAssertTrue(CodexPrimaryWindowPersistence.isFrameOnScreen(
            CGRect(x: -1_200, y: 200, width: 800, height: 600),
            visibleFrames: displays
        ))
        XCTAssertFalse(CodexPrimaryWindowPersistence.isFrameOnScreen(
            CGRect(x: 3_000, y: 200, width: 800, height: 600),
            visibleFrames: displays
        ))
    }

    func testInvalidSavedFrameFallsBackWithoutZoomState() {
        let plan = CodexPrimaryWindowPersistence.restorationPlan(
            savedFrame: CGRect(x: 2_000, y: 200, width: 800, height: 600),
            savedIsZoomed: true,
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_440, height: 900)]
        )

        XCTAssertEqual(plan, CodexPrimaryWindowRestorationPlan(frame: nil, isZoomed: false))
    }

    func testValidSavedFramePreservesZoomState() {
        let frame = CGRect(x: 100, y: 100, width: 1_200, height: 700)
        let plan = CodexPrimaryWindowPersistence.restorationPlan(
            savedFrame: frame,
            savedIsZoomed: true,
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_440, height: 900)]
        )

        XCTAssertEqual(plan, CodexPrimaryWindowRestorationPlan(frame: frame, isZoomed: true))
    }

    func testNormalCloseHidesButExplicitTerminationCloses() {
        XCTAssertEqual(
            CodexPrimaryWindowPersistence.closeAction(isTerminationInProgress: false),
            .hide
        )
        XCTAssertEqual(
            CodexPrimaryWindowPersistence.closeAction(isTerminationInProgress: true),
            .close
        )
    }
}
