import SwiftUI
import XCTest
@testable import CodexCoreUI

final class CodexMessageHoverRevealTests: XCTestCase {
    @MainActor
    func testHoverRevealWaitsBeforeShowingChrome() async throws {
        var isHovered = false
        var hoverTask: Task<Void, Never>?
        let isHoveredBinding = Binding(get: { isHovered }, set: { isHovered = $0 })
        let taskBinding = Binding(get: { hoverTask }, set: { hoverTask = $0 })

        CodexMessageHoverReveal.reveal(
            isHoveredBinding,
            hoverTask: taskBinding,
            hovering: true
        )

        XCTAssertFalse(isHovered)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(isHovered)
    }

    @MainActor
    func testHoverRevealIgnoresFastFlyByRows() async throws {
        var isHovered = false
        var hoverTask: Task<Void, Never>?
        let isHoveredBinding = Binding(get: { isHovered }, set: { isHovered = $0 })
        let taskBinding = Binding(get: { hoverTask }, set: { hoverTask = $0 })

        CodexMessageHoverReveal.reveal(
            isHoveredBinding,
            hoverTask: taskBinding,
            hovering: true
        )
        CodexMessageHoverReveal.reveal(
            isHoveredBinding,
            hoverTask: taskBinding,
            hovering: false
        )

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(isHovered)
    }
}
