import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexLocalProjectEnvironmentProviderTests: XCTestCase {
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
        let result = try await CodexLocalProjectEnvironmentProvider(
            workspaceURL: sourceSubdirectory
        ).handOffToWorktree(CodexWorktreeHandoffRequest(
            title: "Implement",
            sourcePath: sourceSubdirectory.path,
            targetPath: target.path,
            branchName: "codex/implement"
        ))

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

    func testSummaryUsesGitMetadataForLinkedWorktreesOutsideCodexDefaultRoot() throws {
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
            "Worktree"
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
