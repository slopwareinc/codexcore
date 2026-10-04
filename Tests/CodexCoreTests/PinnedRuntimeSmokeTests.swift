import Foundation
import XCTest
@testable import CodexCore

/// Opt-in integration coverage against the real pinned subprocess. Uses a
/// temporary home, never starts inference, and requires no credentials.
final class PinnedRuntimeSmokeTests: XCTestCase {
    func testRealRuntimeHandshakeCatalogAndThreadLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["CODEXCORE_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip("Run scripts/smoke-runtime.sh to exercise the pinned app-server")
        }
        let binary = try XCTUnwrap(ProcessInfo.processInfo.environment["CODEX_BINARY"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexcore-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(path: root.appendingPathComponent("home").path)
        let codex = try await Codex(config: .init(
            codexHome: home,
            codexBinaryPath: binary,
            cwd: root.path,
            environment: ["OPENAI_API_KEY": "", "CODEX_API_KEY": ""],
            reconnectPolicy: .disabled
        ))
        do {
            XCTAssertEqual(codex.metadata.codexHome, home.path)
            XCTAssertNil(codex.runtimeVersionWarning)
            let account = try await codex.perform(CodexRequest.accountRead(.init(refreshToken: false)))
            XCTAssertNil(account.account)
            let catalog = try await codex.perform(CodexRequest.modelList(.init(limit: 10)))
            XCTAssertFalse(catalog.data.isEmpty)

            let thread = try await codex.startThread(.init(
                approvalPolicy: .init(.string("never")), cwd: root.path,
                historyMode: .paginated, sandbox: .readOnly
            ))
            let attachments = try await codex.perform(CodexRequest.threadAttachmentList(.init(
                threadID: thread.id.rawValue
            )))
            XCTAssertTrue(attachments.data.isEmpty)
            let read = try await codex.perform(CodexRequest.threadRead(.init(threadID: thread.id.rawValue)))
            XCTAssertEqual(read.thread.id, thread.id.rawValue)
            await thread.close()
            await codex.close()
        } catch {
            await codex.close()
            throw error
        }
    }
}
