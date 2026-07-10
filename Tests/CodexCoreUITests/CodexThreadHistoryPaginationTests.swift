import XCTest
import CodexCore
@testable import CodexCoreUI

final class CodexThreadHistoryPaginationTests: XCTestCase {
    func testPaginateLoadsEveryPageAndPreservesOldestFirstOrderWithoutDuplicates() async throws {
        let raw = threadRaw(items: [item("item-3", text: "three")])
        var requestedCursors: [String?] = []

        let result = await CodexThreadHistorySession.paginate(parentRaw: raw) { threadID, turnID, cursor in
            XCTAssertEqual(threadID, "thread-1")
            XCTAssertEqual(turnID, "turn-1")
            requestedCursors.append(cursor)
            if cursor == nil {
                return page([item("item-1", text: "one"), item("item-2", text: "two")], next: "page-2")
            }
            return page([item("item-2", text: "two duplicate"), item("item-3", text: "three")])
        }

        XCTAssertEqual(requestedCursors.count, 2)
        XCTAssertNil(requestedCursors[0])
        XCTAssertEqual(requestedCursors[1], "page-2")
        XCTAssertEqual(itemIDs(in: result.raw), ["item-1", "item-2", "item-3"])
        XCTAssertEqual(result.state.phase, .loaded)
        XCTAssertEqual(result.state.loadedItemCount, 4)
        XCTAssertFalse(result.state.hasMore)

        let snapshot = CodexThreadHistorySnapshot(raw: result.raw)
        XCTAssertEqual(snapshot.messages.map(\.text), ["one", "two", "three"])
    }

    func testPaginateFallsBackToThreadReadWhenEndpointIsUnavailable() async {
        let raw = threadRaw(items: [item("existing", text: "existing")])

        let result = await CodexThreadHistorySession.paginate(parentRaw: raw) { _, _, _ in
            throw PaginationTestError.methodNotFound
        }

        XCTAssertEqual(result.raw, raw)
        XCTAssertEqual(result.state.phase, .unavailable)
        XCTAssertEqual(result.state.loadedItemCount, 0)
        XCTAssertNotNil(result.state.errorMessage)
        XCTAssertEqual(CodexThreadHistorySnapshot(raw: result.raw).messages.map(\.text), ["existing"])
    }

    func testPaginateFallsBackTransactionallyWhenLaterPageFails() async {
        let raw = threadRaw(items: [item("existing", text: "existing")])

        let result = await CodexThreadHistorySession.paginate(parentRaw: raw) { _, _, cursor in
            if cursor == nil { return page([item("older", text: "older")], next: "page-2") }
            throw PaginationTestError.network
        }

        XCTAssertEqual(result.raw, raw)
        XCTAssertEqual(result.state.phase, .failed)
        XCTAssertEqual(result.state.loadedItemCount, 0)
        XCTAssertEqual(result.state.nextCursorByTurnID, ["turn-1": "page-2"])
        XCTAssertEqual(CodexThreadHistorySnapshot(raw: result.raw).messages.map(\.text), ["existing"])
    }

    private func threadRaw(items: [CodexJSONValue]) -> CodexJSONValue {
        .dictionary([
            "thread": .dictionary([
                "id": .string("thread-1"),
                "historyMode": .string("paginated"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-1"),
                        "status": .string("completed"),
                        "itemsView": .string("summary"),
                        "items": .array(items)
                    ])
                ])
            ])
        ])
    }

    private func item(_ id: String, text: String) -> CodexJSONValue {
        .dictionary(["id": .string(id), "type": .string("agentMessage"), "text": .string(text)])
    }

    private func page(_ items: [CodexJSONValue], next: String? = nil) -> CodexSchemaThreadItemsListResponse {
        CodexSchemaThreadItemsListResponse(data: items.map(CodexAppServerSchemaValue.init), nextCursor: next)
    }

    private func itemIDs(in raw: CodexJSONValue) -> [String] {
        guard case .dictionary(let response) = raw,
              case .dictionary(let thread)? = response["thread"],
              case .array(let turns)? = thread["turns"],
              case .dictionary(let turn)? = turns.first,
              case .array(let items)? = turn["items"] else { return [] }
        return items.compactMap { item in
            guard case .dictionary(let object) = item,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        }
    }
}

private enum PaginationTestError: Error, CustomStringConvertible {
    case methodNotFound
    case network

    var description: String {
        switch self {
        case .methodNotFound: return "method not found (-32601)"
        case .network: return "network failed"
        }
    }
}
