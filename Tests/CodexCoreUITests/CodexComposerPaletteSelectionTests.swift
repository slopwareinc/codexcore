import XCTest
@testable import CodexCoreUI

final class CodexComposerPaletteSelectionTests: XCTestCase {
    func testSelectionReconcilesAndWrapsAcrossPaletteRows() {
        var selection = CodexComposerPaletteSelection()

        selection.reconcile(availableIDs: ["code-review", "compact", "fast"])
        XCTAssertEqual(selection.selectedID, "code-review")

        selection.moveDown(availableIDs: ["code-review", "compact", "fast"])
        XCTAssertEqual(selection.selectedID, "compact")

        selection.moveUp(availableIDs: ["code-review", "compact", "fast"])
        XCTAssertEqual(selection.selectedID, "code-review")

        selection.moveUp(availableIDs: ["code-review", "compact", "fast"])
        XCTAssertEqual(selection.selectedID, "fast")

        selection.reconcile(availableIDs: ["reasoning"])
        XCTAssertEqual(selection.selectedID, "reasoning")

        selection.reconcile(availableIDs: [])
        XCTAssertNil(selection.selectedID)
    }
}
