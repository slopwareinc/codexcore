import XCTest
@testable import CodexCore

final class InteractionInboxTests: XCTestCase {
    private func key(
        _ id: CodexServerRequestID,
        epoch: UInt64 = 1
    ) -> CodexServerRequestKey {
        .init(connectionEpoch: epoch, requestID: id)
    }

    private func request(
        _ id: CodexServerRequestID,
        epoch: UInt64 = 1,
        method: String = "test/interaction",
        marker: String = "original"
    ) -> CodexParsedServerRequest {
        .init(
            key: key(id, epoch: epoch),
            body: .unknown(
                method: method,
                params: ["marker": .string(marker)]
            )
        )
    }

    func testIntegerAndStringIDsAreExactAndArrivalOrderIsStable() {
        var inbox = CodexInteractionInbox()
        XCTAssertRegistered(inbox.register(request(.integer(7))))
        XCTAssertRegistered(inbox.register(request(.string("7"))))
        XCTAssertRegistered(inbox.register(request(.integer(8))))

        XCTAssertEqual(
            inbox.pendingSnapshots().map(\.key.requestID),
            [.integer(7), .string("7"), .integer(8)]
        )
        XCTAssertEqual(
            inbox.pendingSnapshots().map(\.arrivalOrdinal),
            [0, 1, 2]
        )

        XCTAssertEqual(
            inbox.takeForLocalReply(key(.string("7"))),
            request(.string("7"))
        )
        XCTAssertRegistered(inbox.register(request(.integer(9))))
        XCTAssertEqual(
            inbox.pendingSnapshots().map(\.key.requestID),
            [.integer(7), .integer(8), .integer(9)]
        )
        XCTAssertEqual(
            inbox.pendingSnapshots().map(\.arrivalOrdinal),
            [0, 2, 3]
        )
    }

    func testIdenticalDuplicateIsIdempotentAndConflictKeepsOriginal() {
        var inbox = CodexInteractionInbox()
        let original = request(.integer(1))
        XCTAssertRegistered(inbox.register(original))

        guard case .identicalDuplicate(let snapshot) = inbox.register(original) else {
            return XCTFail("Expected identical duplicate")
        }
        XCTAssertEqual(snapshot.arrivalOrdinal, 0)
        XCTAssertEqual(inbox.count, 1)

        let conflicting = request(
            .integer(1),
            method: "test/conflicting",
            marker: "replacement"
        )
        guard case .conflictingDuplicate(let existing) = inbox.register(conflicting) else {
            return XCTFail("Expected conflicting duplicate")
        }
        XCTAssertEqual(existing.method, "test/interaction")
        XCTAssertEqual(inbox.parsedRequest(for: original.key), original)
        XCTAssertEqual(inbox.count, 1)
    }

    func testLocalReplyAndServerResolutionTakePendingRequestOnce() {
        var inbox = CodexInteractionInbox()
        let local = request(.integer(10))
        let remote = request(.string("remote"))
        XCTAssertRegistered(inbox.register(local))
        XCTAssertRegistered(inbox.register(remote))

        XCTAssertEqual(inbox.takeForLocalReply(local.key), local)
        XCTAssertNil(inbox.takeForLocalReply(local.key))
        XCTAssertEqual(inbox.takeOnServerResolved(remote.key), remote)
        XCTAssertNil(inbox.takeOnServerResolved(remote.key))
        XCTAssertNil(inbox.takeOnServerResolved(key(.integer(999))))
        XCTAssertTrue(inbox.isEmpty)
    }

    func testDisconnectRemovesOnlyMatchingEpochInArrivalOrder() {
        var inbox = CodexInteractionInbox()
        let first = request(.integer(1), epoch: 4)
        let surviving = request(.integer(1), epoch: 5)
        let second = request(.string("two"), epoch: 4)
        XCTAssertRegistered(inbox.register(first))
        XCTAssertRegistered(inbox.register(surviving))
        XCTAssertRegistered(inbox.register(second))

        XCTAssertEqual(inbox.disconnect(connectionEpoch: 4), [first, second])
        XCTAssertEqual(inbox.pendingSnapshots().map(\.key), [surviving.key])
        XCTAssertEqual(inbox.disconnect(connectionEpoch: 4), [])
    }

    func testSnapshotsSanitizeRawArgumentsAndNeverStoreResponseValues() throws {
        let secret = "raw-dynamic-tool-secret"
        let dynamic = CodexParsedServerRequest(
            key: key(.integer(22)),
            body: .dynamicToolCall(.init(
                scope: .init(
                    threadID: "thread",
                    turnID: "turn",
                    itemID: "item"
                ),
                callID: "call",
                namespace: "private",
                tool: "lookup",
                arguments: .dictionary(["token": .string(secret)])
            ))
        )
        var inbox = CodexInteractionInbox()
        XCTAssertRegistered(inbox.register(dynamic))

        let snapshot = try XCTUnwrap(inbox.pendingSnapshots().first)
        XCTAssertEqual(snapshot.kind, .dynamicToolCall)
        XCTAssertEqual(snapshot.scope.threadID, "thread")
        XCTAssertEqual(
            inbox.inboxEntries().first?.body,
            .unsupported(.dynamicToolCall)
        )
        XCTAssertFalse(String(describing: snapshot).contains(secret))

        // The parsed request is removed before the caller constructs or
        // validates a response; the inbox has no response-value storage.
        XCTAssertEqual(inbox.takeForLocalReply(dynamic.key), dynamic)
        XCTAssertTrue(inbox.pendingSnapshots().isEmpty)
        XCTAssertTrue(inbox.inboxEntries().isEmpty)
    }

    private func XCTAssertRegistered(
        _ result: CodexInteractionRegistrationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .registered = result else {
            return XCTFail("Expected interaction registration", file: file, line: line)
        }
    }
}
