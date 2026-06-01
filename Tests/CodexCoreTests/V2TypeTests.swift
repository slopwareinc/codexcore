import XCTest
@testable import CodexCore

final class V2TypeTests: XCTestCase {
    func testInputWireMappingMatchesPythonSDK() {
        XCTAssertEqual(CodexInput.text("hi").jsonValue, .dictionary(["type": .string("text"), "text": .string("hi")]))
        XCTAssertEqual(CodexInput.image(url: "https://example.com/a.png").jsonValue, .dictionary(["type": .string("image"), "url": .string("https://example.com/a.png")]))
        XCTAssertEqual(CodexInput.localImage(path: "/tmp/a.png").jsonValue, .dictionary(["type": .string("localImage"), "path": .string("/tmp/a.png")]))
        XCTAssertEqual(CodexInput.skill(name: "docs", path: "/skills/docs").jsonValue, .dictionary(["type": .string("skill"), "name": .string("docs"), "path": .string("/skills/docs")]))
        XCTAssertEqual(CodexInput.mention(name: "README", path: "README.md").jsonValue, .dictionary(["type": .string("mention"), "name": .string("README"), "path": .string("README.md")]))
    }

    func testApprovalModeMappingMatchesPythonSDK() {
        XCTAssertEqual(ApprovalMode.autoReview.settings.approvalPolicy, .onRequest)
        XCTAssertEqual(ApprovalMode.autoReview.settings.approvalsReviewer, .autoReview)
        XCTAssertEqual(ApprovalMode.denyAll.settings.approvalPolicy, .never)
        XCTAssertNil(ApprovalMode.denyAll.settings.approvalsReviewer)
    }

    func testSandboxMappingMatchesPythonSDK() {
        XCTAssertEqual(Sandbox.readOnly.threadMode, .readOnly)
        XCTAssertEqual(Sandbox.workspaceWrite.threadMode, .workspaceWrite)
        XCTAssertEqual(Sandbox.fullAccess.threadMode, .dangerFullAccess)
        XCTAssertEqual(Sandbox.readOnly.turnPolicy, .dictionary(["type": .string("readOnly")]))
        XCTAssertEqual(Sandbox.workspaceWrite.turnPolicy, .dictionary(["type": .string("workspaceWrite")]))
        XCTAssertEqual(Sandbox.fullAccess.turnPolicy, .dictionary(["type": .string("dangerFullAccess")]))
    }

    func testLoginParamsEncodeAsRootUnionObjects() throws {
        let value = try CodexJSONValue(encoding: LoginAccountParams.apiKey("sk-test"))
        XCTAssertEqual(value, .dictionary(["type": .string("apiKey"), "apiKey": .string("sk-test")]))

        let deviceCode = try CodexJSONValue(encoding: LoginAccountParams.chatgptDeviceCode)
        XCTAssertEqual(deviceCode, .dictionary(["type": .string("chatgptDeviceCode")]))
    }

    func testLoginResponsesDecodeRootUnionObjects() throws {
        let browser = try CodexJSONValue.dictionary([
            "type": .string("chatgpt"),
            "loginId": .string("login-1"),
            "authUrl": .string("https://example.com/auth")
        ]).decode(LoginAccountResponse.self)
        XCTAssertEqual(browser, .chatgpt(loginId: "login-1", authUrl: "https://example.com/auth"))

        let device = try CodexJSONValue.dictionary([
            "type": .string("chatgptDeviceCode"),
            "loginId": .string("login-2"),
            "verificationUrl": .string("https://example.com/device"),
            "userCode": .string("ABCD")
        ]).decode(LoginAccountResponse.self)
        XCTAssertEqual(device, .chatgptDeviceCode(loginId: "login-2", verificationUrl: "https://example.com/device", userCode: "ABCD"))
    }

    func testTurnStatusDecodesNestedStatusShapeFromAppServer() throws {
        let turn = try CodexJSONValue.dictionary([
            "id": .string("turn-1"),
            "status": .dictionary(["type": .string("completed")])
        ]).decode(AppServerTurn.self)

        XCTAssertEqual(turn.id, "turn-1")
        XCTAssertEqual(turn.status, .completed)
    }
}
