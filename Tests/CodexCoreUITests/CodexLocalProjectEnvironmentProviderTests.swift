import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexLocalProjectEnvironmentProviderTests: XCTestCase {
    func testRepositorySnapshotListsBranchesAndDirtyFiles() async throws {
        let fixture = try EnvironmentGitFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "feature/one")
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.url)

        let clean = try await provider.repositorySnapshot()
        XCTAssertEqual(clean.branchName, fixture.initialBranch)
        XCTAssertTrue(clean.branches.contains("feature/one"))
        XCTAssertEqual(clean.dirtyFileCount, 0)

        try fixture.write("changed\n", to: "tracked.txt")
        let dirty = try await provider.repositorySnapshot()
        XCTAssertEqual(dirty.dirtyFileCount, 1)
    }

    func testCheckoutBranchRefusesDirtyTreeAndChecksOutCleanTree() async throws {
        let fixture = try EnvironmentGitFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "feature/two")
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.url)

        try fixture.write("dirty\n", to: "tracked.txt")
        do {
            _ = try await provider.checkoutBranch("feature/two")
            XCTFail("A dirty tree must not be switched")
        } catch let error as CodexLocalProjectEnvironmentError {
            XCTAssertEqual(error, .dirtyBranchSwitch(1))
        }
        XCTAssertEqual(try fixture.currentBranch(), fixture.initialBranch)

        try fixture.git("restore", "tracked.txt")
        let switched = try await provider.checkoutBranch("feature/two")
        XCTAssertEqual(switched.branchName, "feature/two")
        XCTAssertEqual(try fixture.currentBranch(), "feature/two")
    }

    func testDirtyHandoffTransfersTrackedStagedAndUntrackedChangesSafely() async throws {
        let fixture = try EnvironmentGitFixture()
        defer { fixture.remove() }
        let target = fixture.url.deletingLastPathComponent()
            .appending(path: "codex-environment-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.url)

        try fixture.write("staged\n", to: "tracked.txt")
        try fixture.git("add", "tracked.txt")
        try fixture.write("unstaged\n", to: "tracked.txt")
        try fixture.write("new\n", to: "untracked.txt")

        let result = try await provider.handOffToWorktree(CodexWorktreeHandoffRequest(
            title: "Implement environment",
            sourcePath: fixture.url.path,
            targetPath: target.path,
            branchName: "codex/environment-transfer"
        ))

        XCTAssertEqual(result.branchName, "codex/environment-transfer")
        XCTAssertEqual(try String(contentsOf: target.appending(path: "tracked.txt")), "unstaged\n")
        XCTAssertEqual(try String(contentsOf: target.appending(path: "untracked.txt")), "new\n")
        XCTAssertTrue(try fixture.git("status", "--porcelain").isEmpty)
        XCTAssertTrue(try fixture.git("stash", "list").isEmpty)
        XCTAssertEqual(try fixture.git(at: target, "rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "codex/environment-transfer")
        XCTAssertTrue(try fixture.git(at: target, "status", "--porcelain").contains("MM tracked.txt"))
    }

    func testHandoffRejectsExistingDestinationAndUnsupportedProviderIsBounded() async throws {
        let fixture = try EnvironmentGitFixture()
        defer { fixture.remove() }
        let target = fixture.url.deletingLastPathComponent()
            .appending(path: "codex-environment-existing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let provider = CodexLocalProjectEnvironmentProvider(workspaceURL: fixture.url)
        let request = CodexWorktreeHandoffRequest(
            title: "Existing destination",
            sourcePath: fixture.url.path,
            targetPath: target.path,
            branchName: "codex/existing-destination"
        )

        do {
            _ = try await provider.handOffToWorktree(request)
            XCTFail("An existing destination must be refused")
        } catch let error as CodexLocalProjectEnvironmentError {
            XCTAssertEqual(error, .targetExists(target.path))
        }

        let unsupported = CodexUnsupportedProjectEnvironmentProvider()
        do {
            _ = try await unsupported.repositorySnapshot()
            XCTFail("Cloud provider must remain unsupported")
        } catch let error as CodexUnsupportedWorktreeHandoffError {
            XCTAssertEqual(error.errorDescription, "Worktree handoff is not available in this build")
        }
    }
}

private final class EnvironmentGitFixture {
    let url: URL
    private(set) var initialBranch: String = ""

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "codex-environment-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.name", "Codex Environment Test")
        try git("config", "user.email", "environment@example.invalid")
        try write("base\n", to: "tracked.txt")
        try git("add", "tracked.txt")
        try git("commit", "-q", "-m", "base")
        initialBranch = try currentBranch()
    }

    func write(_ value: String, to path: String) throws {
        try value.write(to: url.appending(path: path), atomically: true, encoding: .utf8)
    }

    func currentBranch() throws -> String {
        try git("rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try git(at: url, arguments)
    }

    @discardableResult
    func git(at directory: URL, _ arguments: String...) throws -> String {
        try git(at: directory, arguments)
    }

    @discardableResult
    private func git(at directory: URL, _ arguments: [String]) throws -> String {
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
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EnvironmentGitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return stdout
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
