import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexThreadHistorySessionTests {
    @Test func paginationRetainsPartialPagesAndRetriesFromFailureCursor() async throws {
        let parent = json([
            "thread": [
                "id": "thread-1",
                "historyMode": "paginated",
                "turns": [[
                    "id": "turn-1",
                    "status": "completed",
                    "itemsView": "summary",
                    "items": []
                ]]
            ]
        ])
        struct PageFailure: Error {}
        let first = await CodexThreadHistorySession.paginate(parentRaw: parent) { _, _, cursor in
            if cursor == nil {
                return .init(data: [item("page-1")], nextCursor: "cursor-2")
            }
            throw PageFailure()
        }

        #expect(first.state.phase == .failed)
        #expect(first.state.loadedItemCount == 1)
        #expect(first.state.retryTurnID == "turn-1")
        #expect(first.state.retryCursor == "cursor-2")
        #expect(itemIDs(in: first.raw) == ["page-1"])

        var retryCursors: [String?] = []
        let retried = await CodexThreadHistorySession.paginate(
            parentRaw: first.raw,
            retrying: first.state
        ) { _, _, cursor in
            retryCursors.append(cursor)
            return .init(data: [item("page-2")])
        }

        #expect(retryCursors == ["cursor-2"])
        #expect(retried.state.phase == .loaded)
        #expect(retried.state.loadedItemCount == 2)
        #expect(itemIDs(in: retried.raw) == ["page-1", "page-2"])
    }

    @Test func laterTurnFirstPageFailureRetainsCompletedTurns() async {
        let parent = json([
            "thread": [
                "id": "thread-1",
                "historyMode": "paginated",
                "turns": [
                    ["id": "turn-1", "status": "completed", "items": []],
                    ["id": "turn-2", "status": "completed", "items": []]
                ]
            ]
        ])
        struct PageFailure: Error {}
        let partial = await CodexThreadHistorySession.paginate(parentRaw: parent) { _, turnID, _ in
            if turnID == "turn-1" { return .init(data: [item("kept")]) }
            throw PageFailure()
        }

        #expect(partial.state.loadedItemCount == 1)
        #expect(partial.state.retryTurnID == "turn-2")
        #expect(partial.state.retryCursor == nil)
        #expect(itemIDs(in: partial.raw, turnID: "turn-1") == ["kept"])
    }

    @Test func releasingProtectionRestoresCapacityBound() {
        func result(_ id: String) -> CodexThreadHistoryRestoreResult {
            .init(
                snapshot: .init(),
                hydration: .init(parent: .init(snapshot: .init(id: id))),
                transcriptV2: .init()
            )
        }

        var cache = CodexThreadHistoryCache(capacity: 1)
        cache.store(result("protected"), protected: true)
        cache.protect(threadID: "protected")
        cache.store(result("recent"))
        #expect(cache.count == 2)

        cache.unprotect(threadID: "protected")

        #expect(cache.count == 2)
        #expect(cache.isProtected(threadID: "protected"))

        cache.unprotect(threadID: "protected")

        #expect(cache.count == 1)
        #expect(cache.result(for: "protected") == nil)
        #expect(cache.result(for: "recent") != nil)
    }

    @Test func protectedCacheStoresTheExactLiveTranscript() throws {
        let hydration = CodexThreadHistoryHydrationResult(
            parent: CodexHydratedThread(snapshot: CodexThreadSnapshot(id: "thread-1"))
        )
        let populated = CodexTranscriptV2(turns: [
            CodexTurnV2(
                id: "turn-1",
                finalAnswer: .init(id: "answer", text: "preserved", isStreaming: false),
                status: .done(durationMs: 10)
            )
        ])
        var cache = CodexThreadHistoryCache(capacity: 1)

        cache.store(CodexThreadHistoryRestoreResult(
            snapshot: .init(),
            hydration: hydration,
            transcriptV2: populated
        ), protected: true)
        #expect(cache.result(for: "thread-1")?.transcriptV2 == populated)

        cache.store(CodexThreadHistoryRestoreResult(
            snapshot: .init(),
            hydration: hydration,
            transcriptV2: .init()
        ))
        #expect(try #require(cache.result(for: "thread-1")?.transcriptV2).turns.isEmpty)
    }

    private func json(_ value: Any) -> CodexJSONValue {
        try! JSONDecoder().decode(CodexJSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func item(_ id: String) -> CodexSchemaThreadItem {
        CodexAppServerSchemaValue(.dictionary(["id": .string(id), "type": .string("agentMessage"), "text": .string(id)]))
    }

    private func itemIDs(in raw: CodexJSONValue, turnID: String? = nil) -> [String] {
        guard case .dictionary(let response) = raw,
              case .dictionary(let thread)? = response["thread"],
              case .array(let turns)? = thread["turns"],
              let turnValue = turns.first(where: { value in
                  guard let turnID else { return true }
                  guard case .dictionary(let turn) = value,
                        case .string(let id)? = turn["id"] else { return false }
                  return id == turnID
              }),
              case .dictionary(let turn) = turnValue,
              case .array(let items)? = turn["items"] else { return [] }
        return items.compactMap {
            guard case .dictionary(let item) = $0, case .string(let id)? = item["id"] else { return nil }
            return id
        }
    }
}
