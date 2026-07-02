import XCTest
@testable import CodexCoreUI

final class CodexMessageFooterChromeStateTests: XCTestCase {
    func testIdleFooterReservesWidthWithoutVisibleActions() {
        let state = CodexMessageFooterChromeState(actions: [.copy, .edit], isHovered: false)

        XCTAssertEqual(state.visibleActions, [])
        XCTAssertEqual(state.actionBarWidth, 46)
        XCTAssertEqual(state.timestampOpacity, 0.55)
    }

    func testHoveredFooterShowsActionsInReservedWidth() {
        let state = CodexMessageFooterChromeState(actions: [.copy, .edit], isHovered: true)

        XCTAssertEqual(state.visibleActions, [.copy, .edit])
        XCTAssertEqual(state.actionBarWidth, 46)
        XCTAssertEqual(state.timestampOpacity, 0.95)
    }
}
