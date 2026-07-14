import CodexCore
@testable import CodexCoreUI
import Testing

struct CodexThreadHistorySessionTests {
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
}
