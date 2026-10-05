import Foundation
import XCTest
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppLoginCancellationTests: XCTestCase {
    func testCancelUsesOriginalLoginAndOldCompletionCannotFinishReplacement() async throws {
        let (model, transport, home) = try await fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        await model.startDeviceCodeLogin()
        XCTAssertEqual(model.deviceCode, "CODE-1")
        await model.cancelLogin()
        let canceled = await transport.canceledIDs
        XCTAssertEqual(canceled, ["login-1"])
        XCTAssertNil(model.deviceCode)
        XCTAssertFalse(model.canCancelLogin)
        XCTAssertFalse(model.isCancellingLogin)

        await model.startDeviceCodeLogin()
        await transport.complete("login-1", success: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.deviceCode, "CODE-2")
        XCTAssertFalse(model.isAuthenticated)
        XCTAssertTrue(model.canCancelLogin)
        await transport.complete("login-2", success: true)
        for _ in 0..<5_000 {
            if model.isAuthenticated { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertNil(model.deviceCode)
        await model.disconnect()
    }

    func testTerminalFailureClearsCodeAndLeavesAnActionableError() async throws {
        let (model, transport, home) = try await fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        await model.startDeviceCodeLogin()
        await transport.complete("login-1", success: false, error: "Device code expired")
        for _ in 0..<5_000 {
            if model.deviceCode == nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(model.deviceCode)
        XCTAssertNil(model.deviceCodeURL)
        XCTAssertEqual(model.loginErrorMessage, "Device code expired")
        XCTAssertFalse(model.canCancelLogin)
        await model.disconnect()
    }

    private func fixture() async throws -> (CodexCoreAppModel, AppLoginCancellationTransport, URL) {
        let home = URL(fileURLWithPath: "/private/tmp/codexcore-login-\(UUID().uuidString)")
        let transport = AppLoginCancellationTransport(homePath: home.path)
        let codex = try await Codex(transport: transport, config: .init(codexHome: .init(path: home.path)))
        let model = CodexCoreAppModel()
        model.codex = codex
        model.authSession.connectedAfterHandshake(server: "Test")
        _ = model.authSession.applyAccount(.init(account: nil, requiresOpenAIAuth: true))
        return (model, transport, home)
    }
}

private actor AppLoginCancellationTransport: CodexFrameTransport {
    let homePath: String
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    var nextLogin = 0
    var canceledIDs: [String] = []

    init(homePath: String) { self.homePath = homePath }
    func open() async throws -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard let object = value.objectValue, case .string(let method)? = object["method"],
              let rawID = object["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary(["codexHome": .string(homePath), "platformFamily": .string("unix"),
                                  "platformOs": .string("macos"), "userAgent": .string("test")])
        case "account/login/start":
            nextLogin += 1
            result = .dictionary(["type": .string("chatgptDeviceCode"), "loginId": .string("login-\(nextLogin)"),
                                  "verificationUrl": .string("https://example.test/device"), "userCode": .string("CODE-\(nextLogin)")])
        case "account/login/cancel":
            guard case .string(let loginID)? = object["params"]?.objectValue?["loginId"] else { return }
            canceledIDs.append(loginID)
            continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: .dictionary(["status": .string("canceled")])))
            await complete(loginID, success: false)
            return
        default: result = .dictionary([:])
        }
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }
    func complete(_ loginID: String, success: Bool, error: String? = nil) async {
        continuation?.yield(try! CodexJSONRPCCodec.encodeNotification(method: "account/login/completed", params: .dictionary([
            "loginId": .string(loginID), "success": .bool(success), "error": error.map(CodexJSONValue.string) ?? .null
        ])))
    }
    func close() async { continuation?.finish(); continuation = nil }
}
