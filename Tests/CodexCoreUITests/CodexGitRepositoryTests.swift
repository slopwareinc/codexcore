import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexGitRepositoryTests: XCTestCase {
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
