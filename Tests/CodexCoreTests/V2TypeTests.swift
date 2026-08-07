import XCTest
@testable import CodexCore

final class V2TypeTests: XCTestCase {
    func testMaximumReasoningEffortUsesServerWireValue() throws {
        XCTAssertEqual(
            try CodexJSONValue(encoding: ReasoningEffort.max),
            .string("max")
        )
    }

    func testCodexVoiceWebRTCStartUsesOfficialTransportShape() throws {
        let params = CodexSchemaThreadRealtimeStartParams.codexVoiceWebRTC(
            threadID: "thread-voice",
            offerSDP: "v=0\r\n",
            realtimeSessionID: "realtime-session"
        )
        let value = try CodexJSONValue(encoding: params)

        XCTAssertEqual(value.objectValue?["threadId"], .string("thread-voice"))
        XCTAssertEqual(value.objectValue?["outputModality"], .string("audio"))
        XCTAssertEqual(value.objectValue?["includeStartupContext"], .bool(false))
        XCTAssertEqual(value.objectValue?["realtimeSessionId"], .string("realtime-session"))
        XCTAssertEqual(value.objectValue?["model"], .string("gpt-live-1-codex"))
        XCTAssertEqual(value.objectValue?["version"], .string("v3"))
        XCTAssertEqual(value.objectValue?["voice"], .string("sol"))
        XCTAssertEqual(value.objectValue?["transport"], .dictionary([
            "type": .string("webrtc"),
            "sdp": .string("v=0\r\n"),
        ]))
    }

    func testInitializeResponseDecodesCodexHome() throws {
        let response = try CodexJSONValue.dictionary([
            "codexHome": .string("/tmp/codex-home"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex-cli/0.144.1")
        ]).decode(InitializeResponse.self)

        XCTAssertEqual(response.codexHome, "/tmp/codex-home")
    }

    func testInitializeResponseRejectsEveryMissingOrNullRequiredField() throws {
        let complete: [String: CodexJSONValue] = [
            "codexHome": .string("/tmp/codex-home"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex/alpha.20"),
        ]

        for field in ["codexHome", "platformFamily", "platformOs", "userAgent"] {
            var missing = complete
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(
                try CodexJSONValue.dictionary(missing).decode(InitializeResponse.self),
                "InitializeResponse must require \(field)"
            )

            var null = complete
            null[field] = .null
            XCTAssertThrowsError(
                try CodexJSONValue.dictionary(null).decode(InitializeResponse.self),
                "InitializeResponse must reject null \(field)"
            )
        }
    }

    func testInputWireMappingMatchesPythonSDK() {
        XCTAssertEqual(CodexInput.text("hi").jsonValue, .dictionary(["type": .string("text"), "text": .string("hi")]))
        XCTAssertEqual(CodexInput.image(url: "https://example.com/a.png").jsonValue, .dictionary(["type": .string("image"), "url": .string("https://example.com/a.png")]))
        XCTAssertEqual(CodexInput.localImage(path: "/tmp/a.png").jsonValue, .dictionary(["type": .string("localImage"), "path": .string("/tmp/a.png")]))
        XCTAssertEqual(CodexInput.skill(name: "docs", path: "/skills/docs").jsonValue, .dictionary(["type": .string("skill"), "name": .string("docs"), "path": .string("/skills/docs")]))
        XCTAssertEqual(CodexInput.mention(name: "README", path: "README.md").jsonValue, .dictionary(["type": .string("mention"), "name": .string("README"), "path": .string("README.md")]))
    }

    func testStructuredCommandApprovalDecisionsRoundTrip() throws {
        let decisions: [CodexCommandApprovalDecision] = [
            .accept,
            .acceptWithExecpolicyAmendment(["git", "status"]),
            .applyNetworkPolicyAmendment(.init(action: .deny, host: "example.com")),
            .decline
        ]

        for decision in decisions {
            let encoded = try CodexJSONValue(encoding: decision)
            XCTAssertEqual(try encoded.decode(CodexCommandApprovalDecision.self), decision)
            XCTAssertEqual(encoded, decision.jsonValue)
        }
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

}
