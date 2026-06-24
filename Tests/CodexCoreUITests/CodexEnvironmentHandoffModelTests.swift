import XCTest
@testable import CodexCoreUI

final class CodexEnvironmentHandoffModelTests: XCTestCase {
    func testEnvironmentSelectorExposesCapturedModesAndAppliesWorktreeResult() {
        XCTAssertEqual(CodexProjectEnvironmentSelection.allCases.map(\.title), [
            "Local",
            "Worktree",
            "Cloud"
        ])

        var environment = CodexProjectEnvironmentState(
            workspacePath: "/repo",
            branchName: "main",
            usageRemainingLabel: "80% remaining"
        )
        environment.apply(CodexWorktreeHandoffResult(
            title: "Implement stats",
            branchName: "codex/implement-stats",
            worktreePath: "/repo-worktrees/implement-stats"
        ))

        XCTAssertEqual(environment.selection, .worktree)
        XCTAssertEqual(environment.workspacePath, "/repo-worktrees/implement-stats")
        XCTAssertEqual(environment.worktreePath, "/repo-worktrees/implement-stats")
        XCTAssertEqual(environment.branchName, "codex/implement-stats")
        XCTAssertEqual(environment.usageRemainingLabel, "80% remaining")
    }

    func testWorktreeModalDefaultsBranchNameFromThreadTitle() {
        XCTAssertEqual(
            CodexWorktreeHandoffModalState.defaultBranchName(for: "Fix parser: tables & code!"),
            "codex/fix-parser-tables-code"
        )
        XCTAssertEqual(
            CodexWorktreeHandoffModalState.defaultBranchName(for: "   "),
            "codex/thread"
        )

        let modal = CodexWorktreeHandoffModalState(
            threadTitle: "Review PR #42",
            sourcePath: "/repo",
            targetPath: "/repo-worktrees/review-pr-42"
        )

        XCTAssertEqual(modal.title, "Review PR #42")
        XCTAssertEqual(modal.branchName, "codex/review-pr-42")
    }

    func testWorktreeModalValidationCoversTitlePathsAndBranch() {
        let invalid = CodexWorktreeHandoffModalState(
            threadTitle: " ",
            sourcePath: " ",
            targetPath: "",
            branchName: "codex/bad branch"
        )

        XCTAssertEqual(invalid.validationErrors, [
            .titleRequired,
            .sourcePathRequired,
            .targetPathRequired,
            .branchInvalid
        ])
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.request())

        let valid = CodexWorktreeHandoffModalState(
            threadTitle: " Implement stats ",
            sourcePath: " /repo ",
            targetPath: " /repo-worktrees/stats ",
            branchName: "codex/implement-stats"
        )

        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.request(), CodexWorktreeHandoffRequest(
            title: "Implement stats",
            sourcePath: "/repo",
            targetPath: "/repo-worktrees/stats",
            branchName: "codex/implement-stats"
        ))
    }

    func testWorktreeHandoffSessionSuccessUpdatesEnvironmentAndResultCard() async {
        let modal = CodexWorktreeHandoffModalState(
            threadTitle: "Implement stats",
            sourcePath: "/repo",
            targetPath: "/repo-worktrees/stats"
        )
        let environment = CodexProjectEnvironmentState(workspacePath: "/repo", branchName: "main")
        let completion = await CodexWorktreeHandoffSession.perform(
            modal: modal,
            environment: environment,
            provider: MockWorktreeHandoffProvider(result: CodexWorktreeHandoffResult(
                title: "Implement stats",
                branchName: "codex/implement-stats",
                worktreePath: "/repo-worktrees/stats"
            ))
        )

        XCTAssertEqual(completion.environment.selection, .worktree)
        XCTAssertEqual(completion.environment.branchName, "codex/implement-stats")
        XCTAssertEqual(completion.environment.workspacePath, "/repo-worktrees/stats")
        XCTAssertEqual(completion.activity.title, "Handed-off to worktree")
        XCTAssertEqual(completion.activity.detail, "codex/implement-stats at /repo-worktrees/stats")
        XCTAssertEqual(completion.resultCard, CodexWorktreeHandoffResultCard(
            title: "Handed-off to worktree",
            detail: "codex/implement-stats at /repo-worktrees/stats",
            branchName: "codex/implement-stats",
            worktreePath: "/repo-worktrees/stats"
        ))
    }

    func testWorktreeHandoffSessionSurfacesUnsupportedProviderWithoutMutatingEnvironment() async {
        let modal = CodexWorktreeHandoffModalState(
            threadTitle: "Implement stats",
            sourcePath: "/repo",
            targetPath: "/repo-worktrees/stats"
        )
        let environment = CodexProjectEnvironmentState(workspacePath: "/repo", branchName: "main")

        let completion = await CodexWorktreeHandoffSession.perform(
            modal: modal,
            environment: environment,
            provider: CodexUnsupportedWorktreeHandoffProvider()
        )

        XCTAssertEqual(completion.environment, environment)
        XCTAssertEqual(completion.activity.title, "Worktree handoff unavailable")
        XCTAssertEqual(completion.activity.detail, "Worktree handoff is not available in this build")
        XCTAssertNil(completion.resultCard)
    }
}

private struct MockWorktreeHandoffProvider: CodexWorktreeHandoffProviding {
    var result: CodexWorktreeHandoffResult

    func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        XCTAssertEqual(request.branchName, result.branchName)
        return result
    }
}
