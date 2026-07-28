import XCTest
@testable import CodexCore

final class ProtocolStateAdapterFileChangeTests: XCTestCase {
    private let adapter = ProtocolStateAdapter()

    func testFileChangePatchUpdatePreservesRawChangesWhenOneSiblingIsMalformed() throws {
        let params = try objectFixture(
            #"""
            {
              "threadId": "thread-1",
              "turnId": "turn-1",
              "itemId": "item-1",
              "changes": [
                {
                  "path": "Sources/Feature.swift",
                  "kind": "update",
                  "diff": "@@ -1 +1 @@\n-old\n+new"
                },
                {
                  "path": "Sources/Malformed.swift",
                  "kind": "update",
                  "diff": 42,
                  "futureField": {"kept": true}
                }
              ]
            }
            """#
        )
        let rawChanges = try XCTUnwrap(params["changes"])

        let adaptation = try adapter.adaptNotification(
            method: .itemFileChangePatchUpdated,
            params: params
        )

        XCTAssertEqual(
            adaptation.mutations,
            [.itemLiveFieldReplaced(
                item: ItemKey(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: "item-1"
                ),
                key: "fileChanges",
                value: rawChanges
            )]
        )

        let itemKey = ItemKey(
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "item-1"
        )
        var reducer = CanonicalStateReducer()
        var graph = CanonicalStateGraph()
        _ = reducer.apply(
            .itemStarted(CanonicalItem(
                key: itemKey,
                kind: .fileChange,
                authority: .started
            )),
            to: &graph
        )
        _ = reducer.apply(adaptation.mutations, to: &graph)

        XCTAssertEqual(graph.items[itemKey]?.liveFields["fileChanges"], rawChanges)
    }

    func testFileChangePatchUpdateRejectsMalformedEnvelopeFields() throws {
        let fixtures = [
            (
                #"{"threadId":42,"turnId":"turn-1","itemId":"item-1","changes":[]}"#,
                "threadId must be a string"
            ),
            (
                #"{"threadId":"thread-1","turnId":null,"itemId":"item-1","changes":[]}"#,
                "turnId must be a string"
            ),
            (
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":{},"changes":[]}"#,
                "itemId must be a string"
            ),
            (
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","changes":{}}"#,
                "changes must be an array"
            ),
        ]

        for (fixture, message) in fixtures {
            XCTAssertThrowsError(
                try adapter.adaptNotification(
                    method: .itemFileChangePatchUpdated,
                    params: objectFixture(fixture)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProtocolStateAdapterError,
                    .malformedNotification(
                        method: CodexAppServerNotificationMethod
                            .itemFileChangePatchUpdated.rawValue,
                        message: message
                    )
                )
            }
        }
    }

    func testThreadReadPreservesValidFileChangesWhenASiblingIsMalformed() throws {
        let result = try valueFixture(
            #"""
            {
              "thread": {
                "cliVersion": "0.145.0-alpha.20",
                "createdAt": 1,
                "cwd": "/tmp/project",
                "ephemeral": false,
                "id": "thread-1",
                "modelProvider": "openai",
                "preview": "fixture",
                "sessionId": "session-1",
                "source": "cli",
                "status": {"type": "idle"},
                "turns": [{
                  "id": "turn-1",
                  "items": [{
                    "type": "fileChange",
                    "id": "patch",
                    "status": "completed",
                    "changes": [
                      {
                        "path": "Sources/Valid.swift",
                        "kind": {"type": "update", "move_path": null},
                        "diff": "@@ -1 +1 @@\n-old\n+new"
                      },
                      {
                        "path": "Sources/Future.swift",
                        "kind": {"type": "update"},
                        "diff": 42,
                        "futureField": true
                      }
                    ]
                  }],
                  "itemsView": "full",
                  "status": "completed"
                }],
                "updatedAt": 2
              }
            }
            """#
        )
        let adaptation = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadRead,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "includeTurns": .bool(true),
                ],
                connectionEpoch: 1,
                itemCollectionPolicy: .authoritativeReplacement
            ),
            result: result
        )

        let turnMutation = try XCTUnwrap(adaptation.mutations.first { mutation in
            if case .turnSnapshot = mutation { return true }
            return false
        })
        guard case .turnSnapshot(_, let items, _) = turnMutation else {
            return XCTFail("Expected hydrated turn snapshot")
        }
        let item = try XCTUnwrap(items.first)
        guard case .array(let changes)? = item.payload["changes"] else {
            return XCTFail("Expected raw file changes")
        }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(
            changes[0].objectValue?["diff"],
            .string("@@ -1 +1 @@\n-old\n+new")
        )
        XCTAssertEqual(changes[1].objectValue?["diff"], .int(42))
        XCTAssertEqual(changes[1].objectValue?["futureField"], .bool(true))
    }

    func testItemAndTurnLifecycleNotificationsPreserveMalformedFileChangeSiblings() throws {
        func fileItem(status: String) -> CodexJSONValue {
            .dictionary([
                "type": .string("fileChange"),
                "id": .string("patch"),
                "status": .string(status),
                "changes": .array([
                    .dictionary([
                        "path": .string("Sources/Valid.swift"),
                        "kind": .dictionary(["type": .string("update")]),
                        "diff": .string("@@ -1 +1 @@\n-old\n+new"),
                    ]),
                    .dictionary([
                        "path": .string("Sources/Future.swift"),
                        "kind": .dictionary(["type": .string("update")]),
                        "diff": .int(42),
                        "futureField": .bool(true),
                    ]),
                ]),
            ])
        }
        let fixtures: [(CodexAppServerNotificationMethod, [String: CodexJSONValue])] = [
            (.itemStarted, [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "startedAtMs": .int(1),
                "item": fileItem(status: "inProgress"),
            ]),
            (.itemCompleted, [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "completedAtMs": .int(2),
                "item": fileItem(status: "completed"),
            ]),
            (.turnStarted, [
                "threadId": .string("thread-1"),
                "turn": .dictionary([
                    "id": .string("turn-1"),
                    "items": .array([fileItem(status: "inProgress")]),
                    "status": .string("inProgress"),
                ]),
            ]),
            (.turnCompleted, [
                "threadId": .string("thread-1"),
                "turn": .dictionary([
                    "id": .string("turn-1"),
                    "items": .array([fileItem(status: "completed")]),
                    "itemsView": .string("full"),
                    "status": .string("completed"),
                ]),
            ]),
        ]

        for (method, params) in fixtures {
            let adaptation = try adapter.adaptNotification(
                method: method,
                params: params
            )
            let mutation = try XCTUnwrap(
                adaptation.mutations.first,
                method.rawValue
            )
            let item: CanonicalItem?
            switch mutation {
            case .itemStarted(let value), .itemCompleted(let value):
                item = value
            case .turnStarted(_, let items), .turnCompleted(_, let items, _):
                item = items.first
            default:
                item = nil
            }
            let payload = try XCTUnwrap(item, method.rawValue)
            guard case .array(let changes)? = payload.payload["changes"] else {
                return XCTFail("Expected raw changes for \(method.rawValue)")
            }
            XCTAssertEqual(changes.count, 2, method.rawValue)
            XCTAssertEqual(changes[1].objectValue?["diff"], .int(42), method.rawValue)
            XCTAssertEqual(
                changes[1].objectValue?["futureField"],
                .bool(true),
                method.rawValue
            )
        }
    }
}

private extension ProtocolStateAdapterFileChangeTests {
    func objectFixture(_ json: String) throws -> [String: CodexJSONValue] {
        let value = try valueFixture(json)
        guard case .dictionary(let object) = value else {
            throw ProtocolStateAdapterFileChangeFixtureError.expectedObject
        }
        return object
    }

    func valueFixture(_ json: String) throws -> CodexJSONValue {
        try JSONDecoder().decode(CodexJSONValue.self, from: Data(json.utf8))
    }
}

private enum ProtocolStateAdapterFileChangeFixtureError: Error {
    case expectedObject
}
