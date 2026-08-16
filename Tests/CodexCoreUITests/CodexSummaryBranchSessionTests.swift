import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexSummaryBranchSessionTests: XCTestCase {
    @MainActor
    func testBranchControlListsBranchesAndChecksOutOnACleanTree() async throws {
        let fixture = try SummaryGitFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "feature/one")
        let session = CodexSummaryBranchSession(workspaceURL: fixture.url)

        session.refresh()
        try await settle(session)

        XCTAssertEqual(session.loadState, .ready)
        XCTAssertTrue(session.canSwitchBranches)
        XCTAssertNil(session.switchDisabledReason)
        XCTAssertTrue(session.matchingOptions.contains { $0.branchName == "feature/one" })
        XCTAssertTrue(session.matchingOptions.contains { $0.isCurrent })

        session.filter = "feature"
        XCTAssertEqual(session.matchingOptions.map(\.branchName), ["feature/one"])
        session.filter = ""

        session.checkout("feature/one")
        try await settle(session)

        XCTAssertEqual(session.currentBranchName, "feature/one")
        XCTAssertNil(session.operationError)
        XCTAssertEqual(
            try fixture.git("rev-parse", "--abbrev-ref", "HEAD")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "feature/one"
        )
    }

    @MainActor
    func testDirtyTreeDisablesSwitchingWithAStatedReason() async throws {
        let fixture = try SummaryGitFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "feature/two")
        try fixture.write("dirty\n", to: "tracked.txt")
        let session = CodexSummaryBranchSession(workspaceURL: fixture.url)

        session.refresh()
        try await settle(session)

        XCTAssertFalse(session.canSwitchBranches)
        XCTAssertNotNil(session.switchDisabledReason)
        XCTAssertFalse(session.canCreateBranch)
        session.newBranchName = "feature/three"
        XCTAssertFalse(
            session.canCreateBranch,
            "A dirty tree must not offer create-and-checkout"
        )
    }

    @MainActor
    func testExistingBranchNameIsRejectedBeforeGitRuns() async throws {
        let fixture = try SummaryGitFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "feature/four")
        let session = CodexSummaryBranchSession(workspaceURL: fixture.url)

        session.refresh()
        try await settle(session)

        session.newBranchName = "feature/four"
        XCTAssertEqual(session.newBranchNameProblem, "Branch already exists.")
        XCTAssertFalse(session.canCreateBranch)

        session.newBranchName = " feature/four "
        XCTAssertEqual(session.newBranchNameProblem, "Branch already exists.")
        XCTAssertFalse(session.canCreateBranch)

        session.newBranchName = " feature/five "
        XCTAssertNil(session.newBranchNameProblem)
        XCTAssertTrue(session.canCreateBranch)
    }

    @MainActor
    func testClosingTheControlCancelsOnlyTheBranchListing() async throws {
        let fixture = try SummaryGitFixture()
        defer { fixture.remove() }
        let session = CodexSummaryBranchSession(workspaceURL: fixture.url)

        session.refresh()
        session.cancelLoad()

        XCTAssertNotEqual(session.loadState, .loading)

        session.refresh()
        try await settle(session)
        XCTAssertEqual(session.loadState, .ready)
    }

    @MainActor
    private func settle(
        _ session: CodexSummaryBranchSession,
        timeout: Int = 400
    ) async throws {
        for _ in 0..<timeout where session.loadState == .loading || session.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class SummaryGitFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "codex-summary-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try git("init", "-q")
        try git("config", "user.name", "Codex Summary Test")
        try git("config", "user.email", "summary@example.invalid")
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
                domain: "SummaryGitFixture",
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
