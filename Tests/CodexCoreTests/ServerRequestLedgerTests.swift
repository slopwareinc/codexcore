import XCTest
@testable import CodexCore

final class ServerRequestLedgerTests: XCTestCase {
    private func key(
        _ id: CodexServerRequestID,
        epoch: UInt64 = 1
    ) -> CodexServerRequestKey {
        .init(connectionEpoch: epoch, requestID: id)
    }

    private func registration(
        _ id: CodexServerRequestID,
        epoch: UInt64 = 1,
        method: String = "item/commandExecution/requestApproval",
        threadID: String = "thread-1",
        turnID: String = "turn-1",
        itemID: String = "item-1",
        approvalID: String? = nil
    ) -> CodexServerRequestRegistration {
        .init(
            key: key(id, epoch: epoch),
            method: method,
            scope: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            approvalCorrelation: approvalID.map {
                .init(threadID: threadID, approvalID: $0)
            }
        )
    }

    func testIntegerAndStringRequestIDsRemainDistinct() throws {
        let integer = try CodexServerRequestID(jsonValue: .int(7))
        let string = try CodexServerRequestID(jsonValue: .string("7"))

        XCTAssertEqual(integer, .integer(7))
        XCTAssertEqual(string, .string("7"))
        XCTAssertNotEqual(integer, string)
        XCTAssertEqual(integer.jsonValue, .int(7))
        XCTAssertEqual(string.jsonValue, .string("7"))

        var ledger = CodexServerRequestLedger()
        XCTAssertRegistered(ledger.register(registration(integer)))
        XCTAssertRegistered(ledger.register(registration(string)))
        XCTAssertEqual(ledger.pendingSnapshots().map(\.key.requestID), [integer, string])
    }

    func testRequestIDCodableUsesNativeJSONScalar() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let integerData = try encoder.encode(CodexServerRequestID.integer(42))
        let stringData = try encoder.encode(CodexServerRequestID.string("42"))

        XCTAssertEqual(String(decoding: integerData, as: UTF8.self), "42")
        XCTAssertEqual(String(decoding: stringData, as: UTF8.self), "\"42\"")
        XCTAssertEqual(try decoder.decode(CodexServerRequestID.self, from: integerData), .integer(42))
        XCTAssertEqual(try decoder.decode(CodexServerRequestID.self, from: stringData), .string("42"))
        XCTAssertThrowsError(try decoder.decode(CodexServerRequestID.self, from: Data("1.5".utf8)))
        XCTAssertThrowsError(try CodexServerRequestID(jsonValue: .double(7)))
    }

    func testDuplicateRegistrationKeepsOriginalRequest() {
        var ledger = CodexServerRequestLedger()
        let request = registration(.integer(1), method: "item/tool/requestUserInput")
        XCTAssertRegistered(ledger.register(request))
        let revision = ledger.revision

        let duplicate = registration(.integer(1), method: "currentTime/read")
        guard case .duplicate(let existing) = ledger.register(duplicate) else {
            return XCTFail("Expected duplicate registration")
        }

        XCTAssertEqual(existing.method, "item/tool/requestUserInput")
        XCTAssertEqual(existing.kind, .userInput)
        XCTAssertEqual(ledger.revision, revision, "duplicate input must not mutate ledger state")
    }

    func testFirstTerminalTransitionWinsResultVersusServerResolution() {
        var ledger = CodexServerRequestLedger()
        let requestKey = key(.integer(9))
        XCTAssertRegistered(ledger.register(registration(.integer(9))))

        let result: CodexJSONValue = .dictionary(["decision": .string("accept")])
        guard case .applied(let transition) = ledger.resolve(requestKey, result: result) else {
            return XCTFail("Expected host result to win")
        }
        XCTAssertEqual(transition.terminal.cause, .clientResult)
        XCTAssertEqual(transition.outcome, .result(result))

        guard case .alreadyTerminal(let terminalSnapshot) = ledger.markServerResolved(requestKey) else {
            return XCTFail("Late server resolution must not apply")
        }
        guard case .terminal(let terminal) = terminalSnapshot.state else {
            return XCTFail("Expected terminal snapshot")
        }
        XCTAssertEqual(terminal.cause, .clientResult)
        XCTAssertEqual(terminal.responseDisposition, .result)
    }

    func testServerResolutionWinsAndAbandonsResponse() {
        var ledger = CodexServerRequestLedger()
        let requestKey = key(.string("approval-17"))
        XCTAssertRegistered(ledger.register(registration(.string("approval-17"))))

        guard case .applied(let transition) = ledger.markServerResolved(requestKey) else {
            return XCTFail("Expected server resolution")
        }
        XCTAssertEqual(transition.terminal.cause, .serverResolved)
        XCTAssertEqual(transition.outcome, .abandon(.serverResolved))

        let lateResult = ledger.resolve(requestKey, result: .dictionary([:]))
        guard case .alreadyTerminal = lateResult else {
            return XCTFail("Late client response must be rejected")
        }
        XCTAssertTrue(ledger.pendingSnapshots().isEmpty)
    }

    func testTimeoutProducesTypedErrorAndCannotBeRepeated() {
        var ledger = CodexServerRequestLedger()
        let requestKey = key(.integer(10))
        XCTAssertRegistered(ledger.register(registration(.integer(10), method: "item/tool/requestUserInput")))

        guard case .applied(let transition) = ledger.timeout(requestKey) else {
            return XCTFail("Expected timeout")
        }
        XCTAssertEqual(transition.terminal.cause, .timedOut)
        guard case .error(let error) = transition.outcome else {
            return XCTFail("Timeout must produce a JSON-RPC error response")
        }
        XCTAssertEqual(error.code, -32_001)
        XCTAssertEqual(error.data, .dictionary(["method": .string("item/tool/requestUserInput")]))

        guard case .alreadyTerminal = ledger.timeout(requestKey) else {
            return XCTFail("A timeout is terminal")
        }
    }

    func testTurnCancellationOnlyTerminatesRequestsInThatTurn() {
        var ledger = CodexServerRequestLedger()
        XCTAssertRegistered(ledger.register(registration(.integer(1), threadID: "a", turnID: "turn")))
        XCTAssertRegistered(ledger.register(registration(.integer(2), threadID: "a", turnID: "turn")))
        XCTAssertRegistered(ledger.register(registration(.integer(3), threadID: "b", turnID: "turn")))

        let transitions = ledger.cancelTurn(threadID: "a", turnID: "turn")

        XCTAssertEqual(transitions.map(\.snapshot.key.requestID), [.integer(1), .integer(2)])
        XCTAssertEqual(transitions.map(\.terminal.revision), [4, 5])
        XCTAssertTrue(transitions.allSatisfy { $0.terminal.cause == .turnCancelled })
        XCTAssertEqual(ledger.pendingSnapshots().map(\.key.requestID), [.integer(3)])
    }

    func testDisconnectOnlyAbandonsPendingRequestsFromMatchingEpoch() {
        var ledger = CodexServerRequestLedger()
        XCTAssertRegistered(ledger.register(registration(.integer(1), epoch: 4)))
        XCTAssertRegistered(ledger.register(registration(.integer(1), epoch: 5)))
        XCTAssertRegistered(ledger.register(registration(.integer(2), epoch: 4)))
        _ = ledger.resolve(key(.integer(2), epoch: 4), result: .null)

        let transitions = ledger.disconnect(connectionEpoch: 4)

        XCTAssertEqual(transitions.map(\.snapshot.key), [key(.integer(1), epoch: 4)])
        XCTAssertEqual(transitions.first?.terminal.cause, .disconnected)
        XCTAssertEqual(transitions.first?.outcome, .abandon(.disconnected))
        XCTAssertEqual(
            ledger.pendingSnapshots().map(\.key),
            [key(.integer(1), epoch: 5)]
        )
    }

    func testDirectCancellationProducesOneTypedErrorResponse() {
        var ledger = CodexServerRequestLedger()
        let requestKey = key(.string("cancel-me"))
        XCTAssertRegistered(ledger.register(registration(.string("cancel-me"), method: "item/tool/call")))

        guard case .applied(let transition) = ledger.cancel(requestKey) else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(transition.terminal.cause, .cancelled)
        guard case .error(let error) = transition.outcome else {
            return XCTFail("Cancellation must produce a typed JSON-RPC error")
        }
        XCTAssertEqual(error.code, -32_000)
        XCTAssertEqual(transition.terminal.responseDisposition, .error)

        guard case .alreadyTerminal = ledger.cancel(requestKey) else {
            return XCTFail("Cancellation must be exactly once")
        }
    }

    func testApprovalCorrelationIsSeparateFromWireRequestIdentity() {
        var ledger = CodexServerRequestLedger()
        let correlation = CodexApprovalCorrelation(threadID: "thread-1", approvalID: "approval-shared")
        XCTAssertRegistered(ledger.register(registration(.integer(80), approvalID: "approval-shared")))
        XCTAssertRegistered(ledger.register(registration(.string("80"), approvalID: "approval-shared")))
        XCTAssertRegistered(ledger.register(registration(.integer(81), approvalID: "other")))

        XCTAssertEqual(
            ledger.pendingSnapshots(for: correlation).map(\.key.requestID),
            [.integer(80), .string("80")]
        )

        _ = ledger.resolve(key(.integer(80)), result: .null)
        XCTAssertEqual(
            ledger.pendingSnapshots(for: correlation).map(\.key.requestID),
            [.string("80")]
        )
    }

    func testRequestKindsCoverKnownMethodsAndPreserveUnknown() throws {
        XCTAssertEqual(
            CodexServerRequestKind(method: "item/permissions/requestApproval"),
            .permissionsApproval
        )
        XCTAssertEqual(
            CodexServerRequestKind(method: "future/request").method,
            "future/request"
        )

        let unknown = CodexServerRequestKind.unknown("future/request")
        let encoded = try JSONEncoder().encode(unknown)
        XCTAssertEqual(
            try JSONDecoder().decode(CodexServerRequestKind.self, from: encoded),
            unknown
        )
    }

    func testRemovingTerminalTombstonesDoesNotRemovePendingRequests() {
        var ledger = CodexServerRequestLedger()
        XCTAssertRegistered(ledger.register(registration(.integer(1), epoch: 3)))
        XCTAssertRegistered(ledger.register(registration(.integer(2), epoch: 3)))
        _ = ledger.resolve(key(.integer(1), epoch: 3), result: .null)
        let revisionBeforeRemoval = ledger.revision

        ledger.removeTerminalEntries(connectionEpoch: 3)

        XCTAssertEqual(ledger.revision, revisionBeforeRemoval + 1)
        XCTAssertNil(ledger.snapshot(for: key(.integer(1), epoch: 3)))
        XCTAssertTrue(ledger.snapshot(for: key(.integer(2), epoch: 3))?.isPending == true)
    }

    private func XCTAssertRegistered(
        _ result: CodexServerRequestRegistrationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .registered = result else {
            return XCTFail("Expected request registration", file: file, line: line)
        }
    }
}
