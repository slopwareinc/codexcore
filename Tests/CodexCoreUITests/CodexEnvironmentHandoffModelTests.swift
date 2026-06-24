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

    func testEnvironmentPanelSessionPreparesRowsAndModalDefaults() {
        var session = CodexProjectEnvironmentPanelSession(environment: CodexProjectEnvironmentState(
            workspacePath: "/Users/me/repo",
            branchName: "main",
            usageRemainingLabel: "80% remaining"
        ))

        XCTAssertEqual(session.rows, [
            CodexProjectEnvironmentPanelRow(title: "Mode", value: "Local"),
            CodexProjectEnvironmentPanelRow(title: "Branch", value: "main"),
            CodexProjectEnvironmentPanelRow(title: "Path", value: "/Users/me/repo"),
            CodexProjectEnvironmentPanelRow(title: "Usage", value: "80% remaining")
        ])

        session.prepareModal(threadTitle: "Review PR #42")

        XCTAssertEqual(session.modal, CodexWorktreeHandoffModalState(
            threadTitle: "Review PR #42",
            sourcePath: "/Users/me/repo",
            targetPath: "/Users/me/repo-worktrees/review-pr-42"
        ))
    }

    func testEnvironmentPanelSessionAppliesCompletionActivityAndResultCard() async throws {
        var session = CodexProjectEnvironmentPanelSession(environment: CodexProjectEnvironmentState(
            workspacePath: "/repo",
            branchName: "main"
        ))
        session.prepareModal(threadTitle: "Implement stats", targetPath: "/repo-worktrees/stats")

        let modal = try XCTUnwrap(session.modal)
        let completion = await CodexWorktreeHandoffSession.perform(
            modal: modal,
            environment: session.environment,
            provider: MockWorktreeHandoffProvider(result: CodexWorktreeHandoffResult(
                title: "Implement stats",
                branchName: "codex/implement-stats",
                worktreePath: "/repo-worktrees/stats"
            ))
        )
        session.apply(completion)

        XCTAssertEqual(session.environment.selection, .worktree)
        XCTAssertEqual(session.lastActivity?.title, "Handed-off to worktree")
        XCTAssertEqual(session.resultCard?.detail, "codex/implement-stats at /repo-worktrees/stats")
    }

    func testWorktreeHandoffTranscriptEntryBuildsSuccessNoticeMessage() async {
        let completion = await CodexWorktreeHandoffSession.perform(
            modal: CodexWorktreeHandoffModalState(
                threadTitle: "Implement stats",
                sourcePath: "/repo",
                targetPath: "/repo-worktrees/stats"
            ),
            environment: CodexProjectEnvironmentState(workspacePath: "/repo"),
            provider: MockWorktreeHandoffProvider(result: CodexWorktreeHandoffResult(
                title: "Implement stats",
                branchName: "codex/implement-stats",
                worktreePath: "/repo-worktrees/stats"
            ))
        )

        let entry = CodexWorktreeHandoffTranscriptEntry(completion: completion)
        let message = entry.message

        XCTAssertEqual(message.role, .notice)
        XCTAssertEqual(message.notice?.title, "Handed-off to worktree")
        XCTAssertEqual(message.notice?.detail, "codex/implement-stats at /repo-worktrees/stats")
        XCTAssertEqual(message.notice?.metadata, [
            "Branch: codex/implement-stats",
            "Path: /repo-worktrees/stats"
        ])
        XCTAssertEqual(message.notice?.severity, .success)
        XCTAssertEqual(message.text, [
            "Handed-off to worktree",
            "codex/implement-stats at /repo-worktrees/stats",
            "Branch: codex/implement-stats",
            "Path: /repo-worktrees/stats"
        ].joined(separator: "\n"))
    }

    func testWorktreeHandoffTranscriptEntryBuildsUnsupportedNoticeMessage() async {
        let completion = await CodexWorktreeHandoffSession.perform(
            modal: CodexWorktreeHandoffModalState(
                threadTitle: "Implement stats",
                sourcePath: "/repo",
                targetPath: "/repo-worktrees/stats"
            ),
            environment: CodexProjectEnvironmentState(workspacePath: "/repo"),
            provider: CodexUnsupportedWorktreeHandoffProvider()
        )

        let message = CodexWorktreeHandoffTranscriptEntry(completion: completion).message

        XCTAssertEqual(message.role, .notice)
        XCTAssertEqual(message.notice?.title, "Worktree handoff unavailable")
        XCTAssertEqual(message.notice?.detail, "Worktree handoff is not available in this build")
        XCTAssertEqual(message.notice?.metadata, [])
        XCTAssertEqual(message.notice?.severity, .warning)
    }
}

private struct MockWorktreeHandoffProvider: CodexWorktreeHandoffProviding {
    var result: CodexWorktreeHandoffResult

    func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        XCTAssertEqual(request.branchName, result.branchName)
        return result
    }
}
