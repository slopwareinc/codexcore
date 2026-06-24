import XCTest
@testable import CodexCoreUI

final class CodexComposerDictationModelTests: XCTestCase {
    func testDictationButtonMatchesCapturedBoundaryControl() {
        let state = CodexComposerDictationModel.buttonState

        XCTAssertEqual(state.title, "Dictate")
        XCTAssertEqual(state.systemImage, "mic")
        XCTAssertEqual(state.accessibilityLabel, "Dictate")
        XCTAssertEqual(state.help, "Dictate")
        XCTAssertTrue(state.isEnabled)
    }

    func testDictationRouteStaysExplicitlyUnavailableUntilNativePermissionFlowExists() {
        let route = CodexComposerDictationModel.route()

        XCTAssertEqual(route.activities.map(\.title), ["Dictation unavailable"])
        XCTAssertEqual(route.activities.first?.kind, .notice)
        XCTAssertTrue(route.activities.first?.detail.contains("microphone permission") == true)
        XCTAssertTrue(route.activities.first?.detail.contains("not wired") == true)
        XCTAssertEqual(route.noticeMessage.role, .notice)
        XCTAssertEqual(route.noticeMessage.notice?.title, "Dictation unavailable")
        XCTAssertEqual(route.noticeMessage.notice?.severity, .warning)
        XCTAssertTrue(route.noticeMessage.notice?.detail.contains("microphone permission") == true)
    }
}
