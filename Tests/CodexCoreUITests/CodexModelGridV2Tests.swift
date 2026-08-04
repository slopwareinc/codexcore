import XCTest
@testable import CodexCoreUI

final class CodexModelGridV2Tests: XCTestCase {
    func testGroupingOrderingUnsupportedCellsAndSelectionMapping() throws {
        let sol = model("gpt-5.6-sol", "GPT 5.6 Sol", [.medium, .low, .ultra, .high, .extraHigh])
        let solSpeed = model("gpt-5.6-sol-speed", "GPT 5.6 Sol Speed", [.low, .medium])
        let terra = model("gpt-5.6-terra", "GPT 5.6 Terra", [.low, .medium, .high])
        let legacy = model("gpt-5.5", "GPT 5.5", [.medium, .extraHigh])

        let grid = CodexModelGridV2(
            modelOptions: [sol, solSpeed, terra, legacy],
            selectedModel: sol,
            selectedReasoning: .medium
        )

        XCTAssertEqual(grid.columns.map(\.id), ["sol", "terra", "gpt-5.5"])
        XCTAssertEqual(grid.efforts, [.low, .medium, .high, .extraHigh, .ultra])
        XCTAssertEqual(grid.cell(columnID: "terra", effort: .extraHigh)?.isEnabled, false)
        XCTAssertEqual(grid.cell(columnID: "sol", effort: .medium)?.isSelected, true)

        let enabled = try XCTUnwrap(grid.cell(columnID: "gpt-5.5", effort: .extraHigh))
        XCTAssertEqual(grid.selection(for: enabled)?.modelID, "gpt-5.5")
        XCTAssertEqual(grid.selection(for: enabled)?.reasoningEffort, .extraHigh)

        let disabled = try XCTUnwrap(grid.cell(columnID: "terra", effort: .ultra))
        XCTAssertNil(grid.selection(for: disabled))
    }

    func testCatalogGenerationAndReasoningEffortsAreDerivedFromModelData() {
        var current = model(
            "nova-2.1-alpha",
            "Nova 2.1 Alpha",
            [.minimal, .none, .high]
        )
        current.isDefault = true
        let currentVariant = model(
            "nova-2.1-beta",
            "Nova 2.1 Beta",
            [.minimal, .none]
        )
        let older = model("nova-2.0", "Nova 2.0", [.medium])

        let options = [current, currentVariant, older]
        XCTAssertEqual(
            CodexModelGridV2.currentGenerationOptions(from: options).map(\.id),
            [current.id, currentVariant.id]
        )

        let grid = CodexModelGridV2(
            modelOptions: options,
            selectedModel: current,
            selectedReasoning: .minimal
        )
        XCTAssertEqual(grid.columns.map(\.id), ["alpha", "beta", "nova-2.0"])
        XCTAssertEqual(grid.efforts, [.medium, .high, .none, .minimal])
    }

    private func model(_ id: String, _ name: String, _ efforts: [CodexReasoningSelection]) -> CodexModelSelection {
        CodexModelSelection(id: id, displayName: name, modelIdentifier: id, supportedReasoning: efforts)
    }
}
