import Foundation
import Testing
@testable import CodexCore

struct CodexProcessProbeTests {
    @Test func capturesOutputAndNonzeroExitStatus() throws {
        let result = try CodexProcessProbe.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"]
        )
        #expect(result.status == 7)
        #expect(result.output == "stdoutstderr")
    }

    @Test func noisyAndHungProbesStayBounded() throws {
        do {
            _ = try CodexProcessProbe.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], maximumOutputBytes: 32
            )
            Issue.record("Expected output limit failure")
        } catch let error as CodexProcessProbe.Failure {
            guard case .outputLimitExceeded(32) = error else { throw error }
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try CodexProcessProbe.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(50)
            )
            Issue.record("Expected probe timeout")
        } catch let error as CodexProcessProbe.Failure {
            guard case .timedOut = error else { throw error }
        }
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test func asyncCancellationTerminatesTheProbe() async throws {
        let task = Task {
            try await CodexProcessProbe.runAsync(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(start.duration(to: .now) < .seconds(2))
    }
}
