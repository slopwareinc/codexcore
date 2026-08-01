import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexGitRepositoryTests: XCTestCase {
    @MainActor
    func testCancellingReviewRefreshLeavesNoPermanentLoadingState() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let priorSnapshot = CodexGitReviewSnapshot(branchName: "main")
        let workbench = CodexGitReviewWorkbench(
            workspaceURL: fixture.url,
            lastTurnSession: CodexGitReviewSession(snapshot: priorSnapshot)
        )

        workbench.selectSource(.uncommitted)
        XCTAssertEqual(workbench.loadState, .loading)

        workbench.cancelAll()

        XCTAssertNotEqual(workbench.loadState, .loading)
        XCTAssertNil(workbench.snapshot, "A cancelled source change must not expose a stale Last Turn snapshot")
    }

    @MainActor
    func testReviewRefreshCanRestartAfterOverlayCancellation() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("changed after reopen\n", to: "tracked.txt")
        let workbench = CodexGitReviewWorkbench(
            workspaceURL: fixture.url,
            lastTurnSession: nil
        )

        workbench.selectSource(.uncommitted)
        workbench.cancelAll()
        workbench.refresh()

        for _ in 0..<200 where workbench.loadState == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workbench.loadState, .ready)
        XCTAssertEqual(workbench.snapshot?.files.map(\.path), ["tracked.txt"])
    }

    func testSnapshotsDistinguishStagedUnstagedPartialAndUntracked() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("base\nchanged\n", to: "tracked.txt")
        try fixture.write("staged\n", to: "staged.txt")
        try fixture.git("add", "staged.txt")
        try fixture.write("untracked\n", to: "untracked.txt")

        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let unstaged = try await repository.snapshot(source: .unstaged)
        let staged = try await repository.snapshot(source: .staged)
        let uncommitted = try await repository.snapshot(source: .uncommitted)

        XCTAssertEqual(Set(unstaged.files.map(\.path)), ["tracked.txt", "untracked.txt"])
        XCTAssertEqual(staged.files.map(\.path), ["staged.txt"])
        XCTAssertEqual(
            Set(uncommitted.files.map(\.path)),
            ["tracked.txt", "staged.txt", "untracked.txt"]
        )
        XCTAssertEqual(
            uncommitted.files.first(where: { $0.path == "staged.txt" })?.stagingState,
            .staged
        )
        XCTAssertEqual(
            uncommitted.files.first(where: { $0.path == "tracked.txt" })?.stagingState,
            .unstaged
        )

        try fixture.git("add", "tracked.txt")
        try fixture.write("base\nchanged again\n", to: "tracked.txt")
        let partial = try await repository.snapshot(source: .uncommitted)
        XCTAssertEqual(
            partial.files.first(where: { $0.path == "tracked.txt" })?.stagingState,
            .partiallyStaged
        )
    }

    func testUntrackedPatchIsLazyBoundedAndSynthetic() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("hello\nworld\n", to: "new file.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)

        let snapshot = try await repository.snapshot(source: .unstaged)
        XCTAssertEqual(snapshot.files.map(\.path), ["new file.txt"])

        let patch = try await repository.patch(
            source: .unstaged,
            path: "new file.txt"
        )
        XCTAssertTrue(patch.displayText.contains("--- /dev/null"))
        XCTAssertTrue(patch.displayText.contains("+++ b/new file.txt"))
        XCTAssertTrue(patch.displayText.contains("+hello"))
    }

    func testSnapshotDoesNotRequestBinaryPatchPayloadForMetadata() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        var initialBinary = Data([0])
        initialBinary.append(Data(repeating: 0x41, count: 256 * 1_024 - 1))
        try fixture.write(initialBinary, to: "asset.bin")
        try fixture.git("add", "asset.bin")
        try fixture.git("commit", "-q", "-m", "binary base")
        var changedBinary = Data([0])
        changedBinary.append(Data(repeating: 0x42, count: 256 * 1_024 - 1))
        try fixture.write(changedBinary, to: "asset.bin")

        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let started = ContinuousClock.now
        let snapshot = try await repository.snapshot(source: .uncommitted)

        XCTAssertEqual(snapshot.files.map(\.path), ["asset.bin"])
        XCTAssertEqual(snapshot.files.first?.isBinary, true)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testLargeUntrackedTreeIsBoundedAndDisclosed() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let generated = fixture.url.appending(path: "generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        for index in 0...CodexGitRepository.maximumVisibleUntrackedFiles {
            try Data("x".utf8).write(to: generated.appending(path: "file-\(index).txt"))
        }
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let started = ContinuousClock.now

        let snapshot = try await repository.snapshot(source: .uncommitted)

        XCTAssertEqual(snapshot.files.count, CodexGitRepository.maximumVisibleUntrackedFiles)
        XCTAssertEqual(snapshot.ignoredChangeCount, 1)
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
    }

    func testCommittedSourceReviewsExactlyTheSelectedCommit() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("base\ncommitted change\n", to: "tracked.txt")
        try fixture.git("add", "tracked.txt")
        try fixture.git("commit", "-q", "-m", "selected commit")
        let repository = CodexGitRepository(workspaceURL: fixture.url)

        let snapshot = try await repository.snapshot(source: .committed, commitRef: "HEAD")
        let patch = try await repository.patch(
            source: .committed,
            path: "tracked.txt",
            commitRef: snapshot.comparisonRef
        )

        XCTAssertEqual(snapshot.comparisonRef, "HEAD")
        XCTAssertEqual(snapshot.files.map(\.path), ["tracked.txt"])
        XCTAssertEqual(snapshot.commitOptions.first?.subject, "selected commit")
        XCTAssertFalse(snapshot.commitOptions.first?.shortSHA.isEmpty ?? true)
        XCTAssertTrue(patch.displayText.contains("+committed change"))
    }

    func testBranchSourceUsesExplicitMergeBaseComparison() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let baseBranch = try fixture.git("branch", "--show-current")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.write("base\nfeature change\n", to: "tracked.txt")
        try fixture.git("add", "tracked.txt")
        try fixture.git("commit", "-q", "-m", "feature")
        let repository = CodexGitRepository(workspaceURL: fixture.url)

        let snapshot = try await repository.snapshot(source: .branch, baseRef: baseBranch)
        let patch = try await repository.patch(
            source: .branch,
            path: "tracked.txt",
            baseRef: snapshot.comparisonRef
        )

        XCTAssertEqual(snapshot.comparisonRef, baseBranch)
        XCTAssertEqual(snapshot.files.map(\.path), ["tracked.txt"])
        XCTAssertTrue(patch.displayText.contains("+feature change"))
    }

    func testBranchSourceDoesNotSilentlyFallBackToHeadParent() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = CodexGitRepository(workspaceURL: fixture.url)

        do {
            _ = try await repository.snapshot(source: .branch)
            XCTFail("Expected an explicit base-branch requirement")
        } catch let error as CodexGitRepositoryError {
            guard case .comparisonRequired = error else {
                return XCTFail("Expected comparisonRequired, got \(error)")
            }
        }
    }

    func testMutationRejectsStaleRevisionThenStagesWithFreshRevision() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("change one\n", to: "tracked.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let stale = try await repository.snapshot(source: .unstaged)

        try fixture.write("change two\n", to: "tracked.txt")
        do {
            _ = try await repository.mutate(
                .stage(paths: ["tracked.txt"]),
                expectedRevision: stale.revision,
                source: .unstaged
            )
            XCTFail("Expected stale revision rejection")
        } catch let error as CodexGitRepositoryError {
            guard case .stale = error else {
                return XCTFail("Expected stale error, got \(error)")
            }
        }

        let fresh = try await repository.snapshot(source: .unstaged)
        _ = try await repository.mutate(
            .stage(paths: ["tracked.txt"]),
            expectedRevision: fresh.revision,
            source: .unstaged
        )
        let staged = try await repository.snapshot(source: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["tracked.txt"])
    }

    func testMutationRejectsTraversalAndUntrackedRevert() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("untracked\n", to: "new.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let snapshot = try await repository.snapshot(source: .unstaged)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.mutate(
                .stage(paths: ["../outside"]),
                expectedRevision: snapshot.revision,
                source: .unstaged
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.mutate(
                .revertTracked(paths: ["new.txt"]),
                expectedRevision: snapshot.revision,
                source: .unstaged
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: "new.txt").path
        ))
    }

    func testMutationRefusesRepositoryOperationMarkers() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("changed\n", to: "tracked.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let snapshot = try await repository.snapshot(source: .unstaged)
        let gitDirectory = try fixture.git("rev-parse", "--absolute-git-dir")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data().write(to: URL(fileURLWithPath: gitDirectory).appending(path: "index.lock"))

        do {
            _ = try await repository.mutate(
                .stage(paths: ["tracked.txt"]),
                expectedRevision: snapshot.revision,
                source: .unstaged
            )
            XCTFail("Expected unsafe repository state rejection")
        } catch let error as CodexGitRepositoryError {
            guard case .unsafeRepositoryState(let detail) = error else {
                return XCTFail("Expected unsafeRepositoryState, got \(error)")
            }
            XCTAssertTrue(detail.contains("index lock"))
        }
        XCTAssertEqual(try fixture.git("diff", "--cached", "--name-only"), "")
    }

    func testRevertClearsStagedAndUnstagedChangesTogether() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("staged change\n", to: "tracked.txt")
        try fixture.git("add", "tracked.txt")
        try fixture.write("unstaged after staged\n", to: "tracked.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let snapshot = try await repository.snapshot(source: .uncommitted)

        _ = try await repository.mutate(
            .revertTracked(paths: ["tracked.txt"]),
            expectedRevision: snapshot.revision,
            source: .uncommitted
        )

        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appending(path: "tracked.txt"), encoding: .utf8),
            "base\n"
        )
    }

    func testCommitAndPushCreatesUpstreamForNewBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let remote = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: remote) }
        try fixture.git("init", "-q", "--bare", remote.path)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.write("commit and push\n", to: "tracked.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let snapshot = try await repository.snapshot(source: .uncommitted)

        let result = try await repository.mutate(
            .commitAndPush(message: "ship feature", includeUnstaged: true),
            expectedRevision: snapshot.revision,
            source: .uncommitted
        )

        XCTAssertEqual(result.message, "Commit created and branch pushed.")
        XCTAssertEqual(
            try fixture.git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "origin/feature"
        )
    }

    func testCommitAndPushReportsPartialSuccessWithoutDuplicatingCommit() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", "/does/not/exist/codex-review.git")
        try fixture.write("local commit survives\n", to: "tracked.txt")
        let repository = CodexGitRepository(workspaceURL: fixture.url)
        let snapshot = try await repository.snapshot(source: .uncommitted)

        do {
            _ = try await repository.mutate(
                .commitAndPush(message: "local success", includeUnstaged: true),
                expectedRevision: snapshot.revision,
                source: .uncommitted
            )
            XCTFail("Expected push failure after commit")
        } catch let error as CodexGitRepositoryError {
            guard case .partialSuccess(let message) = error else {
                return XCTFail("Expected partialSuccess, got \(error)")
            }
            XCTAssertTrue(message.contains("do not recreate the commit"))
        }

        XCTAssertEqual(
            try fixture.git("log", "-1", "--format=%s")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "local success"
        )
        XCTAssertTrue(try fixture.git("status", "--porcelain").isEmpty)
    }

    func testPullRequestDetailsDecodeChecksAndReviewers() throws {
        let details = try CodexGitRepository.decodePullRequest("""
        {
          "number": 170,
          "title": "Review workbench",
          "url": "https://github.com/example/repo/pull/170",
          "isDraft": true,
          "state": "OPEN",
          "mergeStateStatus": "BLOCKED",
          "reviewDecision": "REVIEW_REQUIRED",
          "baseRefName": "main",
          "headRefName": "codex/review-workbench-170",
          "reviewRequests": [{"login":"alice"}],
          "reviews": [{"author":{"login":"bob"}}],
          "statusCheckRollup": [
            {"name":"Tests","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci.example/tests"},
            {"context":"Lint","status":"IN_PROGRESS","conclusion":""}
          ]
        }
        """)

        XCTAssertEqual(details.number, 170)
        XCTAssertEqual(details.reviewers, ["alice", "bob"])
        XCTAssertEqual(details.checks.map(\.name), ["Tests", "Lint"])
        XCTAssertTrue(details.checks[0].passed)
        XCTAssertFalse(details.checks[1].passed)
    }
}

private final class GitFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try git("init", "-q")
        try git("config", "user.name", "Codex Review Test")
        try git("config", "user.email", "review@example.invalid")
        try write("base\n", to: "tracked.txt")
        try git("add", "tracked.txt")
        try git("commit", "-q", "-m", "base")
    }

    func write(_ value: String, to path: String) throws {
        try value.write(
            to: url.appending(path: path),
            atomically: true,
            encoding: .utf8
        )
    }

    func write(_ value: Data, to path: String) throws {
        try value.write(to: url.appending(path: path), options: .atomic)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
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
                domain: "GitFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
        return stdout
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        return
    }
}
