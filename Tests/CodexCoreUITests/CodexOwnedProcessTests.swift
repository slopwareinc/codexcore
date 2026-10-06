import Darwin
import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexOwnedProcessTests: XCTestCase {
    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let gate = ProcessTestGate()
        let task = Task {
            await gate.wait()
            return try await Self.run("printf launched > marker", in: fixture.url)
        }
        task.cancel()
        await gate.open()
        await assertCancellation(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appending(path: "marker").path))
    }

    func testCancellationEscalatesForLeaderAndChildIgnoringTermination() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let task = Task {
            try await Self.run("""
            trap '' TERM INT
            /bin/sh -c 'trap "" TERM INT; printf "%s" "$$" > child; while :; do /bin/sleep 1; done' &
            printf '%s' "$$" > leader
            wait
            """, in: fixture.url, limits: .init(timeout: 5, terminationGrace: 0.05, pipeDrainTimeout: 0.15))
        }
        try await waitForFile("child", at: fixture.url)
        try await waitForFile("leader", at: fixture.url)
        let leader = try fixture.pid("leader")
        let child = try fixture.pid("child")
        let start = ContinuousClock.now
        task.cancel()
        await assertCancellation(task)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(kill(leader, 0), -1, "The runner reaps its owned leader")
        try await assertExited(child)
    }

    func testDeadlineEscalatesForIgnoredTermination() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let start = ContinuousClock.now
        do {
            _ = try await Self.run("trap '' TERM INT; printf '%s' \"$$\" > leader; while :; do /bin/sleep 1; done",
                in: fixture.url, limits: .init(timeout: 0.15, terminationGrace: 0.05, pipeDrainTimeout: 0.15))
            XCTFail("Expected deadline")
        } catch let error as CodexOwnedProcessError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(kill(try fixture.pid("leader"), 0), -1)
    }

    func testChildHoldingPipeHasFiniteDrainDeadlineAndIsTerminated() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let start = ContinuousClock.now
        do {
            _ = try await Self.run("""
            /bin/sh -c 'trap "" TERM INT; printf "%s" "$$" > child; while :; do /bin/sleep 1; done' &
            while [ ! -f child ]; do :; done
            exit 0
            """, in: fixture.url, limits: .init(timeout: 5, terminationGrace: 0.05, pipeDrainTimeout: 0.15))
            XCTFail("Expected retained-pipe failure")
        } catch let error as CodexOwnedProcessError {
            XCTAssertEqual(error, .pipeDrainTimedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        try await assertExited(try fixture.pid("child"))
    }

    func testConcurrentOutputCapsStopRunningProducer() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let start = ContinuousClock.now
        do {
            _ = try await Self.run("printf '%s' \"$$\" > leader; while :; do printf 0123456789; printf abcdefghij >&2; done",
                in: fixture.url, limits: .init(timeout: 5, maximumOutputBytes: 100, maximumErrorBytes: 100,
                    terminationGrace: 0.05, pipeDrainTimeout: 0.15))
            XCTFail("Expected cap failure")
        } catch let error as CodexOwnedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(kill(try fixture.pid("leader"), 0), -1)
    }

    func testTruncatedOutputRetainsExactlyTheCapAndStopsProducer() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let result = try await Self.run("while :; do printf 0123456789; done", in: fixture.url,
            limits: .init(timeout: 5, maximumOutputBytes: 101, terminationGrace: 0.05, pipeDrainTimeout: 0.15),
            allowTruncation: true)
        XCTAssertEqual(result.stdout.utf8.count, 101)
        XCTAssertTrue(result.wasTruncated)
    }

    func testStderrOverflowIsNeverSilentlyTruncated() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        do {
            _ = try await Self.run("while :; do printf abcdefghij >&2; done", in: fixture.url,
                limits: .init(timeout: 5, maximumErrorBytes: 100, terminationGrace: 0.05, pipeDrainTimeout: 0.15),
                allowTruncation: true)
            XCTFail("Expected stderr cap failure")
        } catch let error as CodexOwnedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testLargeStdinAndBothOutputsAreDrainedConcurrently() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let input = Data(repeating: 0x61, count: 512 * 1_024)
        let result = try await Self.run("/bin/cat; printf diagnostic >&2", in: fixture.url, stdin: input,
            limits: .init(timeout: 5, maximumOutputBytes: input.count))
        XCTAssertEqual(Data(result.stdout.utf8), input)
        XCTAssertEqual(result.stderr, "diagnostic")
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.wasTruncated)
    }

    func testClosedStdinReportsFailureWithoutSignallingTheHost() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        do {
            _ = try await Self.run("exec 0<&-; printf ready; /bin/sleep 1", in: fixture.url,
                stdin: Data(repeating: 0x61, count: 512 * 1_024),
                limits: .init(timeout: 5, terminationGrace: 0.05, pipeDrainTimeout: 0.15))
            XCTFail("Expected closed input failure")
        } catch let error as CodexOwnedProcessError {
            guard case .inputFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testNonzeroExitPreservesDiagnosticsAndDoesNotCreateCaptureFiles() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let result = try await Self.run("printf out; printf diagnostic >&2; exit 7", in: fixture.url)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "diagnostic")
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path), [])
    }

    func testFailedLaunchDoesNotLeaveTemporaryFiles() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        do {
            _ = try await CodexOwnedProcess.run(executable: fixture.url.appending(path: "missing").path,
                arguments: [], directory: fixture.url)
            XCTFail("Expected launch failure")
        } catch let error as CodexOwnedProcessError {
            guard case .launchFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path), [])
    }

    private static func run(_ script: String, in directory: URL, stdin: Data? = nil,
        limits: CodexOwnedProcess.Limits = .init(), allowTruncation: Bool = false
    ) async throws -> CodexOwnedProcessResult {
        try await CodexOwnedProcess.run(executable: "/bin/sh", arguments: ["-c", script], directory: directory,
            stdin: stdin, limits: limits, allowTruncation: allowTruncation)
    }

    private func waitForFile(_ name: String, at directory: URL) async throws {
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: directory.appending(path: name)), !data.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Helper failed to create \(name)")
        throw ProcessFixtureError.notReady
    }

    private func assertCancellation(_ task: Task<CodexOwnedProcessResult, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    private func assertExited(_ pid: pid_t) async throws {
        // Orphan children can briefly remain zombies until launchd reaps them;
        // proc_pidinfo distinguishes that state from a surviving worker.
        for _ in 0..<200 {
            var info = proc_bsdinfo()
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if count == 0 || info.pbi_status == UInt32(SZOMB) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned child \(pid) remained alive")
    }
}

private struct ProcessFixture: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "codex-owned-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func pid(_ name: String) throws -> pid_t {
        guard let pid = pid_t(try String(contentsOf: url.appending(path: name), encoding: .utf8)), pid > 0 else {
            throw ProcessFixtureError.notReady
        }
        return pid
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private enum ProcessFixtureError: Error { case notReady }

private actor ProcessTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
