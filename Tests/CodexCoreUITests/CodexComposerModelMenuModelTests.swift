import XCTest
@testable import CodexCoreUI

final class CodexComposerModelMenuModelTests: XCTestCase {
    func testModelMenuStateMatchesCapturedReasoningGptAndSpeedShape() {
        let gpt55 = CodexModelSelection(id: "gpt-5.5", displayName: "GPT-5.5", modelIdentifier: "gpt-5.5")
        let gpt54 = CodexModelSelection(id: "gpt-5.4", displayName: "GPT-5.4", modelIdentifier: "gpt-5.4")
        let mini = CodexModelSelection(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini", modelIdentifier: "gpt-5.4-mini")
        let spark = CodexModelSelection(id: "gpt-5.3-codex-spark", displayName: "GPT-5.3-Codex-Spark", modelIdentifier: "gpt-5.3-codex-spark")
        let speed = CodexModelSelection(
            id: "speed",
            displayName: "Speed",
            modelIdentifier: "speed",
            detail: "Fast preset",
            defaultReasoning: .minimal,
            supportedReasoning: [.none, .minimal],
            isFastModel: true
        )

        let state = CodexComposerModelMenuModel.state(
            modelOptions: [gpt55, gpt54, mini, spark, speed],
            selectedModel: gpt55,
            selectedReasoning: .medium
        )

        XCTAssertEqual(state.displayTitle, "GPT-5.5 Medium")
        XCTAssertEqual(state.reasoningTitle, "Reasoning")
        XCTAssertEqual(state.reasoningItems.map(\.title), ["Low", "Medium", "High", "Extra High"])
        XCTAssertEqual(state.reasoningItems.map(\.isSelected), [false, true, false, false])
        XCTAssertEqual(state.gptFamilyTitle, "GPT-5.5")
        XCTAssertEqual(state.gptFamilyItems.map(\.title), ["GPT-5.5", "GPT-5.4", "GPT-5.4-Mini", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(state.gptFamilyItems.map(\.isSelected), [true, false, false, false])
        XCTAssertEqual(state.speedTitle, "Speed")
        XCTAssertEqual(state.speedItems.map(\.title), ["Standard", "Fast"])
        XCTAssertEqual(state.speedItems.map(\.detail), ["Default speed", "1.5x speed, increased usage"])
        XCTAssertEqual(state.speedItems.map(\.isSelected), [true, false])
        XCTAssertEqual(state.speedItems.map(\.isEnabled), [true, true])
        XCTAssertEqual(state.speedItems.last?.selection, speed)
    }

    func testSpeedStateSelectsFastAndDisablesFastWhenAppServerDoesNotReturnSpeedModel() {
        let gpt = CodexModelSelection(id: "gpt-5.5", displayName: "GPT-5.5", modelIdentifier: "gpt-5.5")
        let speed = CodexModelSelection(id: "speed", displayName: "Speed", modelIdentifier: "speed", isFastModel: true)

        let fastState = CodexComposerModelMenuModel.state(
            modelOptions: [gpt, speed],
            selectedModel: speed,
            selectedReasoning: .minimal
        )

        XCTAssertEqual(fastState.displayTitle, "Speed Minimal")
        XCTAssertEqual(fastState.speedItems.map(\.isSelected), [false, true])
        XCTAssertEqual(fastState.speedItems.first?.selection, gpt)
        XCTAssertEqual(fastState.speedItems.last?.selection, speed)

        let missingSpeedState = CodexComposerModelMenuModel.state(
            modelOptions: [gpt],
            selectedModel: gpt,
            selectedReasoning: .medium
        )

        XCTAssertEqual(missingSpeedState.speedItems.map(\.isEnabled), [true, false])
        XCTAssertNil(missingSpeedState.speedItems.last?.selection)
    }

    func testReasoningReconciliationPreservesSupportedCurrentOrFallsBackToDefault() {
        let strict = CodexModelSelection(
            id: "strict",
            displayName: "Strict",
            defaultReasoning: .high,
            supportedReasoning: [.high, .extraHigh]
        )
        let noDefault = CodexModelSelection(
            id: "minimal-only",
            displayName: "Minimal Only",
            supportedReasoning: [.minimal]
        )

        XCTAssertEqual(CodexComposerModelMenuModel.reconciledReasoning(.extraHigh, for: strict), .extraHigh)
        XCTAssertEqual(CodexComposerModelMenuModel.reconciledReasoning(.medium, for: strict), .high)
        XCTAssertEqual(CodexComposerModelMenuModel.reconciledReasoning(.medium, for: noDefault), .minimal)
    }
}
