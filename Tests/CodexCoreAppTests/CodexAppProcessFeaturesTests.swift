import Foundation
import XCTest
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppProcessFeaturesTests: XCTestCase {
    func testProcessRegistersBeforeSpawnAndKeepsEarlyExit() async throws {
        let provider = ProcessFixtureProvider()
        let features = CodexAppProcessFeatures()
        await features.bind(provider)
        await features.start(mode: .process, arguments: ["/bin/echo", "hello"], cwd: "/tmp", tty: false, threadID: nil)
        for _ in 0..<100 { if features.exitCode != nil { break }; await Task.yield() }
        let calls = await provider.calls
        XCTAssertEqual(Array(calls.prefix(2)), ["observe", "process/spawn"])
        XCTAssertEqual(features.stdout, "hello")
        XCTAssertEqual(features.exitCode, 0)
        XCTAssertFalse(features.isRunning)
        let spawn = await provider.spawnParameters
        let params = try XCTUnwrap(spawn)
        XCTAssertEqual(params["outputBytesCap"], .int(131072))
        XCTAssertEqual(params["timeoutMs"], .int(300000))
        await features.bind(nil)
    }

    func testStreamOutputIsBoundedAndStdinUsesExactHandle() async throws {
        let provider = ProcessFixtureProvider(exitImmediately: false)
        let features = CodexAppProcessFeatures()
        await features.bind(provider)
        await features.start(mode: .process, arguments: ["/bin/cat"], cwd: "/tmp", tty: true, threadID: nil)
        await provider.emit(Data(repeating: 65, count: CodexAppProcessFeatures.outputLimit + 12))
        for _ in 0..<100 { if features.capReached { break }; await Task.yield() }
        XCTAssertEqual(features.stdout.utf8.count, CodexAppProcessFeatures.outputLimit)
        XCTAssertTrue(features.capReached)
        await features.write("hello", closeStdin: true)
        await features.resize(rows: 24, cols: 80)
        let params = await provider.parameters
        XCTAssertEqual(params["process/writeStdin"]?["deltaBase64"], .string(Data("hello".utf8).base64EncodedString()))
        XCTAssertEqual(params["process/writeStdin"]?["processHandle"], params["process/spawn"]?["processHandle"])
        await features.bind(nil)
        let calls = await provider.calls
        XCTAssertTrue(calls.contains("process/kill"))
    }

    func testInvalidCommandAndChatShellScopeNeverSend() async {
        let provider = ProcessFixtureProvider()
        let features = CodexAppProcessFeatures()
        await features.bind(provider)
        await features.start(mode: .process, arguments: [""], cwd: "/tmp", tty: false, threadID: nil)
        XCTAssertNotNil(features.error)
        await features.start(mode: .shell, arguments: ["echo hello"], cwd: "/tmp", tty: false, threadID: nil)
        XCTAssertNotNil(features.error)
        let calls = await provider.calls
        XCTAssertEqual(calls, [])
        await features.bind(nil)
    }

    func testStoppingBeforeSpawnAcknowledgesKillsTheLateProcessAgain() async throws {
        let provider = ProcessFixtureProvider(exitImmediately: false, holdSpawn: true)
        let features = CodexAppProcessFeatures()
        await features.bind(provider)
        let start = Task { await features.start(mode: .process, arguments: ["/bin/cat"], cwd: "/tmp", tty: false, threadID: nil) }
        for _ in 0..<5_000 {
            if await provider.spawnIsHeld { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let held = await provider.spawnIsHeld
        XCTAssertTrue(held)
        await features.stop()
        XCTAssertFalse(features.isStarting)
        await provider.releaseSpawn()
        await start.value
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "process/kill" }.count, 2)
        XCTAssertFalse(features.isRunning)
        await features.bind(nil)
    }
}

private actor ProcessFixtureProvider: CodexAppProcessRuntimeProviding {
    let exitImmediately: Bool
    let holdSpawn: Bool
    var spawnIsHeld = false
    var spawnReleased = false
    var spawnGate: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    var parameters: [String: [String: CodexJSONValue]] = [:]
    var spawnParameters: [String: CodexJSONValue]? { parameters["process/spawn"] }
    var handle = ""
    var continuation: AsyncThrowingStream<CodexProcessEvent, Error>.Continuation?
    init(exitImmediately: Bool = true, holdSpawn: Bool = false) {
        self.exitImmediately = exitImmediately; self.holdSpawn = holdSpawn
    }
    func processEvents(handle: String) async throws -> AsyncThrowingStream<CodexProcessEvent, Error> {
        calls.append("observe"); self.handle = handle
        return AsyncThrowingStream { continuation = $0 }
    }
    func command(_ params: CodexSchemaCommandExecParams) async throws -> CodexAppCommandOperation {
        throw CodexAppFeatureError.invalidInput("No command fixture")
    }
    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        calls.append(request.method.rawValue)
        parameters[request.method.rawValue] = try request.encodeParameters()?.objectValue ?? [:]
        if request.method == .processSpawn, holdSpawn, !spawnReleased {
            await withCheckedContinuation { spawnGate = $0; spawnIsHeld = true }
        }
        if request.method == .processSpawn, exitImmediately {
            await emit(Data("hello".utf8))
            continuation?.yield(.exited(.init(exitCode: 0, processHandle: handle, stderr: "", stderrCapReached: false, stdout: "hello", stdoutCapReached: false)))
            continuation?.finish()
            await Task.yield()
        }
        return try CodexJSONValue.dictionary([:]).decode(Response.self)
    }
    func emit(_ data: Data) async {
        continuation?.yield(.output(.init(capReached: false, deltaBase64: data.base64EncodedString(), processHandle: handle, stream: .stdout)))
    }
    func releaseSpawn() { spawnReleased = true; spawnGate?.resume(); spawnGate = nil }
}
