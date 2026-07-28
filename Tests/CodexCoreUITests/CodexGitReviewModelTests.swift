import XCTest
@testable import CodexCoreUI

final class CodexGitReviewModelTests: XCTestCase {
    func testDirtyFixtureSummaryReportsBranchCountsAndDiffStats() {
        let session = CodexGitReviewSession(snapshot: dirtySnapshot())

        XCTAssertEqual(session.branchSummary, CodexGitBranchDirtySummary(
            branchName: "codex/review-panel",
            dirtyFileCount: 3,
            stagedFileCount: 1,
            unstagedFileCount: 2,
            unpushedCommitCount: 2
        ))
        XCTAssertEqual(session.branchSummary.title, "codex/review-panel (3)")
        XCTAssertEqual(session.commitStats, CodexGitReviewDiffStats(changedFiles: 3, addedLines: 15, removedLines: 4))
        XCTAssertEqual(session.commitStats.summary, "3 files +15 -4")
    }

    func testBranchPickerShowsDirtyCountAndDisablesCreateCheckoutWhenDirty() {
        let snapshot = CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel",
            branchOptions: [
                CodexGitBranchPickerOption(branchName: "main"),
                CodexGitBranchPickerOption(branchName: "codex/review-panel")
            ],
            files: [
                CodexGitReviewFileChange(path: "Sources/Review.swift", status: .modified, isStaged: true),
                CodexGitReviewFileChange(path: "Sources/Panel.swift", status: .added, isStaged: false)
            ]
        )

        let picker = snapshot.branchPicker

        XCTAssertEqual(picker.currentTitle, "codex/review-panel (2)")
        XCTAssertEqual(picker.options.map(\.title), ["main", "codex/review-panel (2)"])
        XCTAssertEqual(picker.options.map(\.isCurrent), [false, true])
        XCTAssertFalse(picker.canCreateOrCheckout)
        XCTAssertEqual(picker.createOrCheckoutDisabledReason, "Commit or discard changes before switching branches")
    }

    func testBranchPickerEnablesCreateCheckoutWhenCleanAndAddsCurrentBranch() {
        let snapshot = CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel",
            branchOptions: [
                CodexGitBranchPickerOption(branchName: "main")
            ]
        )

        let picker = snapshot.branchPicker

        XCTAssertEqual(picker.options.map(\.title), ["codex/review-panel", "main"])
        XCTAssertEqual(picker.options.map(\.isCurrent), [true, false])
        XCTAssertTrue(picker.canCreateOrCheckout)
        XCTAssertNil(picker.createOrCheckoutDisabledReason)
    }

    func testIncludeUnstagedToggleChangesCommitStatsAndCommitAvailability() {
        var session = CodexGitReviewSession(
            snapshot: dirtySnapshot(),
            commitDraft: CodexGitCommitDraft(message: "Land review panel", includeUnstaged: false)
        )

        XCTAssertEqual(session.commitStats, CodexGitReviewDiffStats(changedFiles: 1, addedLines: 8, removedLines: 1))
        XCTAssertTrue(session.actionState.isCommitEnabled)

        session.setIncludeUnstaged(true)

        XCTAssertEqual(session.commitStats, CodexGitReviewDiffStats(changedFiles: 3, addedLines: 15, removedLines: 4))
        XCTAssertTrue(session.actionState.isCommitEnabled)
    }

    func testCommitMessageValidationAndNoStagedChangesDisableCommit() {
        var session = CodexGitReviewSession(
            snapshot: dirtySnapshot(),
            commitDraft: CodexGitCommitDraft(message: "  ", includeUnstaged: false)
        )

        XCTAssertFalse(session.commitDraft.isValid)
        XCTAssertEqual(session.commitDraft.validationError, "Commit message is required")
        XCTAssertFalse(session.actionState.isCommitEnabled)
        XCTAssertEqual(session.actionState.commitDisabledReason, "Commit message is required")

        session.setCommitMessage("Land review panel")
        session.refresh(CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel",
            files: [
                CodexGitReviewFileChange(path: "Sources/New.swift", status: .modified, isStaged: false, addedLines: 4)
            ]
        ))

        XCTAssertFalse(session.actionState.isCommitEnabled)
        XCTAssertEqual(session.actionState.commitDisabledReason, "No staged changes to commit")
    }

    func testPushAndPullRequestStatesUseDirtyRemoteAndUnpushedState() {
        let dirty = CodexGitReviewSession(
            snapshot: dirtySnapshot(),
            commitDraft: CodexGitCommitDraft(message: "Land review panel")
        ).actionState

        XCTAssertTrue(dirty.isCommitAndPushEnabled)
        XCTAssertFalse(dirty.isPushEnabled)
        XCTAssertEqual(dirty.pushDisabledReason, "Commit or discard changes before pushing")
        XCTAssertFalse(dirty.isCreatePullRequestEnabled)
        XCTAssertEqual(dirty.createPullRequestDisabledReason, "Commit or discard changes before creating a PR")

        let readyToPush = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel",
            unpushedCommitCount: 2
        )).actionState

        XCTAssertTrue(readyToPush.isPushEnabled)
        XCTAssertFalse(readyToPush.isCreatePullRequestEnabled)
        XCTAssertEqual(readyToPush.createPullRequestDisabledReason, "Push commits before creating a PR")

        let readyForPR = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel"
        )).actionState

        XCTAssertFalse(readyForPR.isPushEnabled)
        XCTAssertEqual(readyForPR.pushDisabledReason, "No commits to push")
        XCTAssertTrue(readyForPR.isCreatePullRequestEnabled)
    }

    func testMissingRemoteDisablesCommitAndPushPushAndPullRequest() {
        let state = CodexGitReviewSession(
            snapshot: CodexGitReviewSnapshot(
                branchName: "codex/review-panel",
                files: [
                    CodexGitReviewFileChange(path: "Sources/New.swift", status: .added, isStaged: true, addedLines: 3)
                ]
            ),
            commitDraft: CodexGitCommitDraft(message: "Land review panel")
        ).actionState

        XCTAssertTrue(state.isCommitEnabled)
        XCTAssertFalse(state.isCommitAndPushEnabled)
        XCTAssertEqual(state.commitAndPushDisabledReason, "Push target is unavailable")
        XCTAssertFalse(state.isPushEnabled)
        XCTAssertEqual(state.pushDisabledReason, "Commit or discard changes before pushing")
        XCTAssertFalse(state.isCreatePullRequestEnabled)
        XCTAssertEqual(state.createPullRequestDisabledReason, "Commit or discard changes before creating a PR")
    }

    func testReviewFileListShowsEmptyAndMismatchStates() {
        let cleanList = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(branchName: "main")).fileList

        XCTAssertEqual(cleanList.files, [])
        XCTAssertEqual(cleanList.emptyState, CodexGitReviewEmptyState(
            title: "No changes",
            detail: "The worktree has no dirty files.",
            isMismatch: false
        ))

        let mismatch = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            files: [
                CodexGitReviewFileChange(path: "Sources/New.swift", status: .modified, isStaged: false, addedLines: 4)
            ],
            reviewFilePaths: []
        )).fileList

        XCTAssertEqual(mismatch.files, [])
        XCTAssertEqual(mismatch.emptyState, CodexGitReviewEmptyState(
            title: "No matching files",
            detail: "Dirty worktree state exists, but the review file list is empty.",
            isMismatch: true
        ))
    }

    func testTurnDiffBuildsReviewSnapshotForVisiblePanelSeed() throws {
        let diff = """
        diff --git a/Sources/One.swift b/Sources/One.swift
        index 1111111..2222222 100644
        --- a/Sources/One.swift
        +++ b/Sources/One.swift
        @@ -1,2 +1,3 @@
        -old
        +new
        +more
        diff --git a/Tests/OneTests.swift b/Tests/OneTests.swift
        index 3333333..4444444 100644
        --- a/Tests/OneTests.swift
        +++ b/Tests/OneTests.swift
        @@ -1 +1 @@
        -old test
        +new test
        """

        let snapshot = try XCTUnwrap(CodexGitReviewSnapshot.fromTurnDiff(
            branchName: "codex/review-panel",
            turnDiff: diff
        ))

        XCTAssertEqual(snapshot.branchSummary.title, "codex/review-panel (2)")
        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/One.swift", "Tests/OneTests.swift"])
        XCTAssertEqual(snapshot.commitStats(includeUnstaged: true), CodexGitReviewDiffStats(changedFiles: 2, addedLines: 3, removedLines: 2))
        XCTAssertNil(CodexGitReviewSnapshot.fromTurnDiff(branchName: "main", turnDiff: " "))
    }

    func testTurnDiffUsesCanonicalStatusesAndHunkHeaderPrecedence() throws {
        let diff = """
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1 @@
        +++source text
        diff --git a/Sources/Old.swift b/Sources/Renamed.swift
        similarity index 100%
        rename from Sources/Old.swift
        rename to Sources/Renamed.swift
        """

        let snapshot = try XCTUnwrap(CodexGitReviewSnapshot.fromTurnDiff(
            branchName: "codex/review-panel",
            turnDiff: diff
        ))

        XCTAssertEqual(snapshot.files.map(\.status), [.added, .renamed])
        XCTAssertEqual(snapshot.files.map(\.path), [
            "Sources/New.swift",
            "Sources/Renamed.swift",
        ])
        XCTAssertEqual(snapshot.files.first?.addedLines, 1)
    }

    func testTurnDiffFailsClosedWhenFileRecordCapIsExceeded() {
        let diff = (0...CodexUnifiedDiffParser.defaultMaximumRetainedFileCount)
            .map { index in
                """
                diff --git a/File\(index).swift b/File\(index).swift
                @@ -0,0 +1 @@
                +value
                """
            }
            .joined(separator: "\n")

        XCTAssertNil(CodexGitReviewSnapshot.fromTurnDiff(
            branchName: "codex/review-panel",
            turnDiff: diff
        ))
    }

    private func dirtySnapshot() -> CodexGitReviewSnapshot {
        CodexGitReviewSnapshot(
            branchName: "codex/review-panel",
            upstreamBranchName: "origin/codex/review-panel",
            files: [
                CodexGitReviewFileChange(path: "Sources/Review.swift", status: .modified, isStaged: true, addedLines: 8, removedLines: 1),
                CodexGitReviewFileChange(path: "Sources/Panel.swift", status: .added, isStaged: false, addedLines: 6, removedLines: 0),
                CodexGitReviewFileChange(path: "Tests/ReviewTests.swift", status: .modified, isStaged: false, addedLines: 1, removedLines: 3)
            ],
            unpushedCommitCount: 2
        )
    }
}
