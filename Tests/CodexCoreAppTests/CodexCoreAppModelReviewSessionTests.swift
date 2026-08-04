import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import XCTest

@MainActor
final class CodexCoreAppModelReviewSessionTests: XCTestCase {
    func testGitCheckoutExposesReviewBeforeTheTurnProducesEdits() throws {
        let model = makeModel()
        model.setGitBranchForTesting("main")

        // No turn diff yet. Review, and the summary's Commit or push and
        // Create pull request rows, must still be reachable.
        let session = try XCTUnwrap(model.gitReviewSession)
        XCTAssertEqual(session.snapshot.branchName, "main")
        XCTAssertTrue(session.snapshot.files.isEmpty)
    }

    func testNonGitWorkspaceHasNoReviewSession() {
        let model = makeModel()
        model.setGitBranchForTesting(nil)

        XCTAssertNil(model.gitReviewSession)
    }

    func testBlankBranchIsNotTreatedAsACheckout() {
        let model = makeModel()
        model.setGitBranchForTesting("   ")

        XCTAssertNil(model.gitReviewSession)
    }

    private func makeModel() -> CodexCoreAppModel {
        CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
    }
}
