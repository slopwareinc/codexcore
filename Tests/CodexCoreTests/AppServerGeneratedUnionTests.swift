import XCTest
@testable import CodexCore

final class AppServerGeneratedUnionTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testThreadItemDecodesEveryCurrentDiscriminator() throws {
        let samples: [(String, String)] = [
            ("userMessage", #"{"type":"userMessage","id":"i1","content":[]}"#),
            ("hookPrompt", #"{"type":"hookPrompt","id":"i2","fragments":[]}"#),
            ("agentMessage", #"{"type":"agentMessage","id":"i3","text":"hello"}"#),
            ("plan", #"{"type":"plan","id":"i4","text":"plan"}"#),
            ("reasoning", #"{"type":"reasoning","id":"i5"}"#),
            ("commandExecution", #"{"type":"commandExecution","id":"i6","command":"pwd","commandActions":[],"cwd":"/tmp","status":"inProgress"}"#),
            ("fileChange", #"{"type":"fileChange","id":"i7","changes":[],"status":"completed"}"#),
            ("mcpToolCall", #"{"type":"mcpToolCall","id":"i8","arguments":{},"server":"s","status":"inProgress","tool":"t"}"#),
            ("dynamicToolCall", #"{"type":"dynamicToolCall","id":"i9","arguments":{},"status":"inProgress","tool":"t"}"#),
            ("collabAgentToolCall", #"{"type":"collabAgentToolCall","id":"i10","agentsStates":{},"receiverThreadIds":[],"senderThreadId":"thr","status":"inProgress","tool":"spawnAgent"}"#),
            ("subAgentActivity", #"{"type":"subAgentActivity","id":"i11","agentPath":"a","agentThreadId":"thr","kind":"started"}"#),
            ("webSearch", #"{"type":"webSearch","id":"i12","query":"q"}"#),
            ("imageView", #"{"type":"imageView","id":"i13","path":"/tmp/a.png"}"#),
            ("sleep", #"{"type":"sleep","id":"i14","durationMs":1}"#),
            ("imageGeneration", #"{"type":"imageGeneration","id":"i15","result":"ok","status":"completed"}"#),
            ("enteredReviewMode", #"{"type":"enteredReviewMode","id":"i16","review":"r"}"#),
            ("exitedReviewMode", #"{"type":"exitedReviewMode","id":"i17","review":"r"}"#),
            ("contextCompaction", #"{"type":"contextCompaction","id":"i18"}"#),
        ]

        for (expectedType, json) in samples {
            let item = try decoder.decode(CodexSchemaThreadItem.self, from: Data(json.utf8))
            XCTAssertEqual(item.type, expectedType)
            XCTAssertNotNil(item.id)
            XCTAssertEqual(
                try decoder.decode(CodexSchemaThreadItem.self, from: encoder.encode(item)),
                item
            )
        }
    }

    func testThreadStatusDecodesEveryCurrentDiscriminator() throws {
        let values = [
            #"{"type":"notLoaded"}"#,
            #"{"type":"idle"}"#,
            #"{"type":"systemError"}"#,
            #"{"type":"active","activeFlags":["waitingOnApproval","waitingOnUserInput"]}"#,
        ]

        XCTAssertEqual(
            try values.map { try decoder.decode(CodexSchemaThreadStatus.self, from: Data($0.utf8)).type },
            ["notLoaded", "idle", "systemError", "active"]
        )

        let active = try decoder.decode(CodexSchemaThreadStatus.self, from: Data(values[3].utf8))
        guard case .active(let payload) = active else { return XCTFail("Expected active status") }
        XCTAssertEqual(payload.activeFlags, [.waitingOnApproval, .waitingOnUserInput])
    }

    func testUnrecognizedVariantAndKnownAdditiveFieldsRoundTripLosslessly() throws {
        let futureJSON = #"{"type":"futureItem","id":"future-1","nested":{"v":1}}"#
        let future = try decoder.decode(CodexSchemaThreadItem.self, from: Data(futureJSON.utf8))
        guard case .unrecognized(let type, let rawValue) = future else {
            return XCTFail("Expected unrecognized item")
        }
        XCTAssertEqual(type, "futureItem")
        XCTAssertEqual(try decoder.decode(CodexJSONValue.self, from: encoder.encode(future)), rawValue)

        let additiveJSON = #"{"type":"agentMessage","id":"known-1","text":"hello","futureField":{"v":2}}"#
        let known = try decoder.decode(CodexSchemaThreadItem.self, from: Data(additiveJSON.utf8))
        guard case .agentMessage(let payload) = known else { return XCTFail("Expected agent message") }
        XCTAssertEqual(payload.unknownFields["futureField"], .dictionary(["v": .int(2)]))
        XCTAssertEqual(
            try decoder.decode(CodexJSONValue.self, from: encoder.encode(known)),
            try decoder.decode(CodexJSONValue.self, from: Data(additiveJSON.utf8))
        )
    }

    func testUnknownNestedAlphaEnumValuesRemainInsideKnownVariants() throws {
        let item = try decoder.decode(
            CodexSchemaThreadItem.self,
            from: Data(#"{"type":"agentMessage","id":"known-2","text":"hello","phase":"futurePhase"}"#.utf8)
        )
        guard case .agentMessage(let message) = item else { return XCTFail("Expected agent message") }
        XCTAssertEqual(message.phase, .unrecognized("futurePhase"))

        let status = try decoder.decode(
            CodexSchemaThreadStatus.self,
            from: Data(#"{"type":"active","activeFlags":["futureFlag"]}"#.utf8)
        )
        guard case .active(let active) = status else { return XCTFail("Expected active status") }
        XCTAssertEqual(active.activeFlags, [.unrecognized("futureFlag")])
        XCTAssertEqual(
            try decoder.decode(CodexSchemaThreadStatus.self, from: encoder.encode(status)),
            status
        )
    }

    func testUnknownStateResponseEnumValueRoundTrips() throws {
        let response = try decoder.decode(
            CodexSchemaEnvironmentStatusResponse.self,
            from: Data(#"{"status":"warmingUp"}"#.utf8)
        )
        XCTAssertEqual(response.status, .unrecognized("warmingUp"))
        XCTAssertEqual(
            try decoder.decode(
                CodexSchemaEnvironmentStatusResponse.self,
                from: encoder.encode(response)
            ),
            response
        )
    }

    func testUnknownOperationNotificationEnumValueRoundTrips() throws {
        let notification = try decoder.decode(
            CodexSchemaMCPServerStatusUpdatedNotification.self,
            from: Data(
                #"{"name":"server","status":"reconnecting","threadId":"thread"}"#.utf8
            )
        )
        XCTAssertEqual(notification.status, .unrecognized("reconnecting"))
        XCTAssertEqual(
            try decoder.decode(
                CodexSchemaMCPServerStatusUpdatedNotification.self,
                from: encoder.encode(notification)
            ),
            notification
        )
    }

    func testNamedProtocolEnumsPreserveFutureValues() throws {
        XCTAssertEqual(
            try decoder.decode(
                CodexSchemaApprovalsReviewer.self,
                from: Data(#""futureReviewer""#.utf8)
            ),
            .unrecognized("futureReviewer")
        )
        XCTAssertEqual(
            try decoder.decode(
                CodexSchemaHookEventName.self,
                from: Data(#""futureHookEvent""#.utf8)
            ),
            .unrecognized("futureHookEvent")
        )
        XCTAssertEqual(
            try decoder.decode(
                CodexSchemaModelRerouteReason.self,
                from: Data(#""futureRerouteReason""#.utf8)
            ),
            .unrecognized("futureRerouteReason")
        )
    }

    func testCallerSelectedOperationEnumsRemainClosed() {
        XCTAssertNil(CodexSchemaMCPServerStatusDetail(rawValue: "futureDetail"))
        XCTAssertNil(CodexSchemaMergeStrategy(rawValue: "futureStrategy"))
    }

    func testKnownMalformedVariantAndMissingDiscriminatorFail() {
        XCTAssertThrowsError(
            try decoder.decode(
                CodexSchemaThreadItem.self,
                from: Data(#"{"type":"agentMessage","id":"missing-text"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(CodexSchemaThreadItem.self, from: Data(#"{"id":"missing-type"}"#.utf8))
        )
    }

    func testAlpha20ResumeCursorsAreTyped() throws {
        let json = #"""
        {
            "approvalPolicy":"never",
            "approvalsReviewer":"user",
            "cwd":"/tmp",
            "itemsBackwardsCursor":"item-head",
            "model":"gpt-test",
            "modelProvider":"openai",
            "sandbox":{"type":"readOnly"},
            "thread":{
                "cliVersion":"0.145.0-alpha.20",
                "createdAt":1,
                "cwd":"/tmp",
                "ephemeral":false,
                "id":"thr",
                "modelProvider":"openai",
                "preview":"p",
                "sessionId":"thr",
                "source":"cli",
                "status":{"type":"idle"},
                "turns":[],
                "updatedAt":1
            },
            "turnsBackwardsCursor":"turn-head"
        }
        """#
        let response = try decoder.decode(CodexSchemaThreadResumeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.itemsBackwardsCursor, "item-head")
        XCTAssertEqual(response.turnsBackwardsCursor, "turn-head")
    }
}
