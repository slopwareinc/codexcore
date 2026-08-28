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

    func testCanonicalDiffRevisionRefreshesReviewFactsWithStableTurnSource() throws {
        let model = makeModel()
        model.setGitBranchForTesting("main")
        model.runtimeSession.selectThread("thread")
        model.runtimeSession.applyCanonicalSnapshot(reviewSnapshot(
            revision: 7,
            diff: """
            diff --git a/Sources/Review.swift b/Sources/Review.swift
            @@ -0,0 +1 @@
            +first
            """
        ))
        let first = try XCTUnwrap(model.gitReviewSession)

        model.runtimeSession.applyCanonicalSnapshot(reviewSnapshot(
            revision: 8,
            diff: """
            diff --git a/Sources/Review.swift b/Sources/Review.swift
            @@ -0,0 +1,2 @@
            +first
            +second
            """
        ))
        let refreshed = try XCTUnwrap(model.gitReviewSession)

        XCTAssertEqual(first.snapshot.revision.sourceID, "canonical/thread/turn")
        XCTAssertEqual(refreshed.snapshot.revision.sourceID, first.snapshot.revision.sourceID)
        XCTAssertEqual(first.snapshot.revision.value, 7)
        XCTAssertEqual(refreshed.snapshot.revision.value, 8)
        XCTAssertEqual(first.snapshot.files.first?.addedLines, 1)
        XCTAssertEqual(refreshed.snapshot.files.first?.addedLines, 2)
    }

    private func makeModel() -> CodexCoreAppModel {
        CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
    }

    private func reviewSnapshot(revision: UInt64, diff: String) -> CodexSessionStateSnapshot {
        let stateRevision = StateRevision(revision)
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        return CodexSessionStateSnapshot(
            stateRevision: stateRevision,
            canonical: CanonicalStateSnapshot(
                revision: stateRevision,
                threadOrder: [threadID],
                threads: [threadID: CanonicalThread(
                    id: threadID,
                    status: .idle,
                    turnOrder: [turnID],
                    history: .init(turnsCoverage: .full),
                    consistency: .authoritative,
                    lastChangedRevision: stateRevision
                )],
                turns: [turnKey: CanonicalTurn(
                    key: turnKey,
                    status: .completed,
                    diff: diff,
                    lastChangedRevision: stateRevision
                )]
            ),
            serverRequests: .init(revision: stateRevision, requests: []),
            lifecycle: .ready(connectionEpoch: 1)
        )
    }
}
