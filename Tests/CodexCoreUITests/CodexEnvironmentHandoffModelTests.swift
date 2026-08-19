import XCTest
@testable import CodexCoreUI

final class CodexEnvironmentHandoffModelTests: XCTestCase {
    func testEnvironmentSelectorExposesCapturedModesAndAppliesWorktreeResult() {
        XCTAssertEqual(CodexProjectEnvironmentSelection.allCases.map(\.title), [
            "Local",
            "Worktree"
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

    func testWorktreeResultCarriesWorkingDirectoryAndPathOutcomes() {
        let result = CodexWorktreeHandoffResult(
            title: "Implement stats",
            branchName: "codex/implement-stats",
            worktreePath: "/repo-worktrees/abcd/implement-stats",
            workingDirectoryPath: "/repo-worktrees/abcd/implement-stats/packages/web",
            pathOutcomes: [
                CodexWorktreeHandoffPathOutcome(path: "Sources/App.swift", status: .applied),
                CodexWorktreeHandoffPathOutcome(
                    path: "Sources/Conflict.swift",
                    status: .conflicted,
                    detail: "Git reported a merge conflict."
                ),
            ]
        )
        var environment = CodexProjectEnvironmentState(
            workspacePath: "/repo/packages/web",
            branchName: "main"
        )

        environment.apply(result)

        XCTAssertEqual(environment.worktreePath, "/repo-worktrees/abcd/implement-stats")
        XCTAssertEqual(
            environment.workspacePath,
            "/repo-worktrees/abcd/implement-stats/packages/web"
        )
        XCTAssertEqual(result.resultCard.pathOutcomes.map(\.status), [.applied, .conflicted])
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
        guard case .success(let result) = completion.outcome else {
            return XCTFail("Expected a typed handoff success")
        }
        XCTAssertEqual(result.branchName, "codex/implement-stats")
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
        guard case .failure(let failure) = completion.outcome else {
            return XCTFail("Expected a typed handoff failure")
        }
        XCTAssertEqual(failure.message, "Worktree handoff is not available in this build")
        XCTAssertEqual(completion.activity.title, "Worktree handoff failed")
        XCTAssertEqual(
            completion.activity.detail,
            "Worktree handoff is not available in this build The source tree was left untouched."
        )
        XCTAssertNil(completion.resultCard)
    }

    func testEnvironmentPanelSessionPreparesRowsAndModalDefaults() throws {
        var session = CodexProjectEnvironmentPanelSession(environment: CodexProjectEnvironmentState(
            workspacePath: "/Users/me/repo",
            branchName: "main",
            usageRemainingLabel: "80% remaining"
        ))

        XCTAssertEqual(session.rows, [
            CodexProjectEnvironmentPanelRow(title: "Mode", value: "Local"),
            CodexProjectEnvironmentPanelRow(title: "Branch", value: "main"),
            CodexProjectEnvironmentPanelRow(title: "Path", value: "/Users/me/repo"),
            CodexProjectEnvironmentPanelRow(title: "Usage", value: "80% remaining"),
            CodexProjectEnvironmentPanelRow(title: "Runtime", value: "Unavailable")
        ])

        session.prepareModal(threadTitle: "Review PR #42")

        let modal = try XCTUnwrap(session.modal)
        XCTAssertEqual(modal.title, "Review PR #42")
        XCTAssertEqual(modal.sourcePath, "/Users/me/repo")
        XCTAssertEqual(URL(fileURLWithPath: modal.targetPath).lastPathComponent, "review-pr-42")
        XCTAssertEqual(
            URL(fileURLWithPath: modal.targetPath).deletingLastPathComponent().lastPathComponent.count,
            4
        )
        XCTAssertEqual(
            URL(fileURLWithPath: modal.targetPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent,
            "repo-worktrees"
        )
    }

    func testModalTargetPathRefinementPreservesUserEdits() throws {
        var session = CodexProjectEnvironmentPanelSession(environment: CodexProjectEnvironmentState(
            workspacePath: "/repo/packages/web"
        ))
        let fallback = "/repo/packages/web-worktrees/abcd/thread"
        session.prepareModal(threadTitle: "Thread", targetPath: fallback)

        session.replaceModalTargetPath(
            "/repo-worktrees/ef01/thread",
            replacing: fallback
        )
        XCTAssertEqual(session.modal?.targetPath, "/repo-worktrees/ef01/thread")

        session.modal?.targetPath = "/Users/me/custom-worktree"
        session.replaceModalTargetPath(
            "/repo-worktrees/1234/thread",
            replacing: fallback
        )
        XCTAssertEqual(session.modal?.targetPath, "/Users/me/custom-worktree")
    }

    func testRepositoryRootLookupRunsAsynchronouslyForNestedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-git-root-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("packages/web")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let resolved = await CodexWorkspaceGitProbe.repositoryRoot(at: nested)
        XCTAssertEqual(resolved, root.standardizedFileURL)
    }

    func testEnvironmentPanelRowsRepresentRuntimeLoadingAvailableAndFailure() {
        var environment = CodexProjectEnvironmentState(workspacePath: "/repo", runtimeInfo: .loading)
        var session = CodexProjectEnvironmentPanelSession(environment: environment)
        XCTAssertEqual(session.rows.last, CodexProjectEnvironmentPanelRow(title: "Runtime", value: "Loading…"))

        environment.runtimeInfo = .available(cwd: "/remote/repo", shellName: "zsh", shellPath: "/bin/zsh")
        session.environment = environment
        XCTAssertEqual(Array(session.rows.suffix(2)), [
            CodexProjectEnvironmentPanelRow(title: "Shell", value: "zsh · /bin/zsh"),
            CodexProjectEnvironmentPanelRow(title: "CWD", value: "/remote/repo")
        ])

        environment.runtimeInfo = .failed("environment disconnected")
        session.environment = environment
        XCTAssertEqual(session.rows.last, CodexProjectEnvironmentPanelRow(
            title: "Runtime",
            value: "Error · environment disconnected"
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
        XCTAssertNil(session.handoffFailure)
    }

    func testWorktreeHandoffFailurePreservesPerPathOutcomes() async {
        let modal = CodexWorktreeHandoffModalState(
            threadTitle: "Implement stats",
            sourcePath: "/repo",
            targetPath: "/repo-worktrees/stats"
        )
        let outcomes = [
            CodexWorktreeHandoffPathOutcome(path: "Applied.swift", status: .applied),
            CodexWorktreeHandoffPathOutcome(path: "Conflict.swift", status: .conflicted),
            CodexWorktreeHandoffPathOutcome(path: "Skipped.swift", status: .skipped),
        ]

        let completion = await CodexWorktreeHandoffSession.perform(
            modal: modal,
            environment: CodexProjectEnvironmentState(workspacePath: "/repo"),
            provider: FailingWorktreeHandoffProvider(outcomes: outcomes)
        )

        guard case .failure(let failure) = completion.outcome else {
            return XCTFail("Expected a typed handoff failure")
        }
        XCTAssertEqual(failure.pathOutcomes, outcomes)
        XCTAssertEqual(completion.environment.workspacePath, "/repo")
        XCTAssertTrue(completion.activity.detail.hasSuffix("The source tree was left untouched."))
    }

}

private struct FailingWorktreeHandoffProvider: CodexWorktreeHandoffProviding {
    var outcomes: [CodexWorktreeHandoffPathOutcome]

    func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        throw CodexLocalProjectEnvironmentError.handoffFailed(
            message: "Git reported conflicts.",
            pathOutcomes: outcomes
        )
    }
}

private struct MockWorktreeHandoffProvider: CodexWorktreeHandoffProviding {
    var result: CodexWorktreeHandoffResult

    func handOffToWorktree(_ request: CodexWorktreeHandoffRequest) async throws -> CodexWorktreeHandoffResult {
        XCTAssertEqual(request.branchName, result.branchName)
        return result
    }
}
