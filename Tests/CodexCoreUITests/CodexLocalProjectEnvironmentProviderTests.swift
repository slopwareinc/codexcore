import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexLocalProjectEnvironmentProviderTests: XCTestCase {
    func testCancelledBranchHookReportsUncertainOutcomeAndPreservesSwitchedBranch() async throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }
        _ = try runGit(["branch", "other"], at: fixture.root)
        let hook = fixture.root.appendingPathComponent(".git/hooks/post-checkout")
        try """
        #!/bin/sh
        trap '' TERM INT
        printf '%s' "$$" > .git/checkout-started
        while :; do /bin/sleep 1; done
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.root)
        let task = Task { try await provider.checkoutBranch("other") }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".git/checkout-started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".git/checkout-started").path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected interrupted switch")
        } catch let error as CodexLocalProjectEnvironmentError {
            XCTAssertTrue(error.localizedDescription.contains("may already be on other"))
            XCTAssertTrue(error.localizedDescription.contains("Refresh and inspect"))
        }
        XCTAssertEqual(try runGit(["symbolic-ref", "--short", "HEAD"], at: fixture.root), "other\n")
        XCTAssertEqual(try runGit(["status", "--porcelain"], at: fixture.root), "")
    }

    @MainActor
    func testCancelledHandoffCleansOwnedDestinationAndBranchWithSourceIntact() async throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }
        try Data("let value = 2\n".utf8).write(to: fixture.root.appendingPathComponent("packages/web/App.swift"))
        let target = fixture.root.deletingLastPathComponent().appendingPathComponent("cancelled-\(UUID().uuidString)")
        defer { fixture.removeWorktree(target: target, branch: "codex/cancelled") }
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.root)
        let cancellation = HandoffTestCancellation()
        let task = Task {
            try await provider.handOffToWorktree(.init(title: "Cancel", sourcePath: fixture.root.path,
                targetPath: target.path, branchName: "codex/cancelled"), progress: { stage in
                    if stage == .applyingTrackedChanges { cancellation.cancel() }
                })
        }
        cancellation.task = task

        do {
            _ = try await task.value
            XCTFail("Expected interrupted handoff")
        } catch let error as CodexLocalProjectEnvironmentError {
            XCTAssertFalse(error.localizedDescription.contains("cleanup failed"), error.localizedDescription)
            XCTAssertFalse(error.pathOutcomes.contains { $0.status == .conflicted }, "Cancellation is not evidence of a merge conflict")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try runGit(["branch", "--list", "codex/cancelled"], at: fixture.root).contains("codex/cancelled"))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("packages/web/App.swift"), encoding: .utf8), "let value = 2\n")
        XCTAssertEqual(try runGit(["status", "--porcelain"], at: fixture.root), " M packages/web/App.swift\n")
    }

    @MainActor
    func testCleanHandoffCancellationAtFinalProgressStageCleansDestination() async throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }
        let target = fixture.root.deletingLastPathComponent().appendingPathComponent("final-cancel-\(UUID().uuidString)")
        defer { fixture.removeWorktree(target: target, branch: "codex/final-cancel") }
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.root)
        let cancellation = HandoffTestCancellation()
        let task = Task {
            try await provider.handOffToWorktree(.init(title: "Cancel", sourcePath: fixture.root.path,
                targetPath: target.path, branchName: "codex/final-cancel"), progress: { stage in
                    if stage == .finalizing { cancellation.cancel() }
                })
        }
        cancellation.task = task
        do {
            _ = try await task.value
            XCTFail("Expected cancellation at finalization")
        } catch let error as CodexLocalProjectEnvironmentError {
            XCTAssertFalse(error.localizedDescription.contains("cleanup failed"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try runGit(["branch", "--list", "codex/final-cancel"], at: fixture.root), "")
        XCTAssertEqual(try runGit(["status", "--porcelain"], at: fixture.root), "")
    }

    func testAlreadyCancelledRepositoryReadReturnsCancellation() async throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.root)
        let gate = HandoffTestGate()
        let task = Task {
            await gate.wait()
            return try await provider.repositorySnapshot()
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    @MainActor
    func testHandoffLeavesSourceUntouchedCopiesChangesAndPreservesRepositoryPrefix() async throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }

        let sourceSubdirectory = fixture.root.appendingPathComponent("packages/web")
        let trackedFile = sourceSubdirectory.appendingPathComponent("App.swift")
        let untrackedFile = sourceSubdirectory.appendingPathComponent("Local.swift")
        try Data("let value = 2\n".utf8).write(to: trackedFile)
        try Data("let local = true\n".utf8).write(to: untrackedFile)

        let target = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("Project-worktrees/ab12/implement")
        var progressStages: [CodexWorktreeHandoffProgressStage] = []
        let result = try await CodexLocalProjectEnvironmentProvider(
            workspaceURL: sourceSubdirectory
        ).handOffToWorktree(
            CodexWorktreeHandoffRequest(
                title: "Implement",
                sourcePath: sourceSubdirectory.path,
                targetPath: target.path,
                branchName: "codex/implement"
            ),
            progress: { progressStages.append($0) }
        )

        XCTAssertEqual(result.worktreePath, target.standardizedFileURL.path)
        XCTAssertEqual(
            result.workingDirectoryPath,
            target.appendingPathComponent("packages/web").standardizedFileURL.path
        )
        XCTAssertEqual(
            try String(contentsOf: trackedFile, encoding: .utf8),
            "let value = 2\n"
        )
        XCTAssertEqual(
            try String(contentsOf: untrackedFile, encoding: .utf8),
            "let local = true\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: target.appendingPathComponent("packages/web/App.swift"),
                encoding: .utf8
            ),
            "let value = 2\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: target.appendingPathComponent("packages/web/Local.swift"),
                encoding: .utf8
            ),
            "let local = true\n"
        )
        XCTAssertEqual(
            try runGit(["symbolic-ref", "--short", "HEAD"], at: target),
            "codex/implement\n"
        )
        XCTAssertEqual(
            result.pathOutcomes.map(\.path),
            ["packages/web/App.swift", "packages/web/Local.swift"]
        )
        XCTAssertEqual(
            result.pathOutcomes.map(\.status),
            [.applied, .applied]
        )
        XCTAssertEqual(progressStages, CodexWorktreeHandoffProgressStage.allCases)
        XCTAssertEqual(
            try runGit(["status", "--porcelain", "-z", "--untracked-files=all"], at: fixture.root),
            " M packages/web/App.swift\0?? packages/web/Local.swift\0"
        )

        fixture.removeWorktree(target: target, branch: "codex/implement")
    }

    func testDefaultTargetPathUsesDistinctFourHexadecimalBuckets() {
        let first = CodexProjectEnvironmentPanelSession.defaultTargetPath(
            sourcePath: "/Users/me/Project",
            threadTitle: "Review PR"
        )
        let second = CodexProjectEnvironmentPanelSession.defaultTargetPath(
            sourcePath: "/Users/me/Project",
            threadTitle: "Review PR"
        )

        XCTAssertNotEqual(first, second)
        let firstURL = URL(fileURLWithPath: first)
        let secondURL = URL(fileURLWithPath: second)
        XCTAssertEqual(firstURL.lastPathComponent, "review-pr")
        XCTAssertEqual(secondURL.lastPathComponent, "review-pr")
        XCTAssertTrue(isFourHex(firstURL.deletingLastPathComponent().lastPathComponent))
        XCTAssertTrue(isFourHex(secondURL.deletingLastPathComponent().lastPathComponent))
        XCTAssertEqual(
            firstURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Project-worktrees"
        )
    }

    func testRenderSafeEnvironmentLabelsAvoidGitProbesForLinkedWorktreesOutsideCodexDefaultRoot() throws {
        let fixture = try makeRepository()
        defer { fixture.remove() }
        let linked = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("ordinary-linked-checkout")
        _ = try runGit(["worktree", "add", "--detach", linked.path, "HEAD"], at: fixture.root)

        XCTAssertEqual(
            CodexWorkspaceSummaryContext(workspacePath: fixture.root.path).environmentModeTitle,
            "Local"
        )
        XCTAssertEqual(
            CodexWorkspaceSummaryContext(workspacePath: linked.path).environmentModeTitle,
            "Local",
            "The render-safe summary uses path heuristics"
        )
        XCTAssertEqual(
            CodexProjectSidebarEnvironmentLabel.title(workspacePath: linked.path),
            nil,
            "Sidebar rendering must not launch a synchronous Git probe"
        )

        _ = try? runGit(["worktree", "remove", "--force", linked.path], at: fixture.root)
    }

    private func isFourHex(_ value: String) -> Bool {
        value.count == 4 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private func makeRepository() throws -> RepositoryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-environment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("packages/web"),
            withIntermediateDirectories: true
        )
        _ = try runGit(["init", "-q"], at: root)
        _ = try runGit(["config", "user.email", "codex-tests@example.com"], at: root)
        _ = try runGit(["config", "user.name", "Codex Tests"], at: root)
        try Data("let value = 1\n".utf8).write(
            to: root.appendingPathComponent("packages/web/App.swift")
        )
        _ = try runGit(["add", "."], at: root)
        _ = try runGit(["commit", "-qm", "initial"], at: root)
        return RepositoryFixture(root: root)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CodexLocalProjectEnvironmentProviderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
        return stdout
    }

    private struct RepositoryFixture {
        let root: URL

        func removeWorktree(target: URL, branch: String) {
            _ = try? runGit(["worktree", "remove", "--force", target.path], at: root)
            _ = try? runGit(["branch", "-D", branch], at: root)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func runGit(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            let stdout = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "CodexLocalProjectEnvironmentProviderTests",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            decoding: error.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self
                        ),
                    ]
                )
            }
            return stdout
        }
    }
}

@MainActor
private final class HandoffTestCancellation {
    var task: Task<CodexWorktreeHandoffResult, Error>?
    func cancel() { task?.cancel() }
}

private actor HandoffTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
