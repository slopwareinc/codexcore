import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexThreadUISessionStoreTests {
    @Test func turnEnvelopeHistoryKeepsAuthoritativeDuration() throws {
        let store = CodexThreadUISessionStore()
        store.activate(threadID: "thread")
        #expect(store.restoreHistory(turns: [json([
            "id": "historical-turn",
            "startedAt": 100,
            "completedAt": 108,
            "durationMs": 8_000,
            "items": [[
                "type": "agentMessage",
                "id": "answer",
                "phase": "final_answer",
                "text": "Done"
            ]]
        ])], threadID: "thread"))

        let turn = try #require(store.activeTruthTranscript.turns.first)
        guard case .done(let durationMs) = turn.status else {
            Issue.record("Expected restored turn to be complete")
            return
        }
        #expect(durationMs == 8_000)
    }

    @Test func warmSwitchRestoresExactTranscriptAndUIState() throws {
        let store = CodexThreadUISessionStore(capacity: 12)
        store.activate(threadID: "A")
        #expect(store.restoreHistory(items: [
            json(["type": "userMessage", "id": "user-a", "content": [["type": "text", "text": "Hello A"]]]),
            json(["type": "agentMessage", "id": "answer-a", "phase": "final_answer", "text": "Answer A"])
        ], threadID: "A"))
        store.updateScrollState(threadID: "A", rawOffset: 417.25, isPinnedToBottom: false)
        store.setWorkExpanded(true, turnID: "history-1", threadID: "A")
        store.setRowExpanded(true, rowID: "command-a", threadID: "A")
        let original = try #require(store.presentation(for: "A"))
        let originalTimestamp = try #require(original.presentedAtByTurnID["history-1"])

        store.activate(threadID: "B")
        #expect(store.restoreHistory(items: [
            json(["type": "userMessage", "id": "user-b", "content": [["type": "text", "text": "Hello B"]]])
        ], threadID: "B"))
        store.updateScrollState(threadID: "B", rawOffset: 12, isPinnedToBottom: true)

        store.activate(threadID: "A")
        let restored = try #require(store.activePresentation)
        #expect(restored.transcript == original.transcript)
        #expect(restored.rawScrollOffset == 417.25)
        #expect(!restored.isPinnedToBottom)
        #expect(restored.expandedWorkTurnIDs == ["history-1"])
        #expect(restored.expandedRowIDs == ["command-a"])
        #expect(restored.presentedAtByTurnID["history-1"] == originalTimestamp)
        #expect(store.diagnostics.warmActivationCount >= 1)

        #expect(!store.restoreHistory(items: [], threadID: "A"))
        #expect(store.activeTruthTranscript == original.transcript)
    }

    @Test func lruEvictsBeyondBoundedWarmSet() {
        let store = CodexThreadUISessionStore(capacity: 8)
        for index in 0..<9 {
            let id = "thread-\(index)"
            store.activate(threadID: id)
            _ = store.restoreHistory(items: [], threadID: id)
        }

        #expect(store.presentation(for: "thread-0") == nil)
        #expect(store.presentation(for: "thread-8") != nil)
        #expect(store.diagnostics.evictionCount == 1)
    }

    @Test func reducerTruthIsImmediateWhilePresentationDropsObsoleteDeltas() throws {
        let store = CodexThreadUISessionStore()
        store.activate(threadID: "thread")
        _ = store.restoreHistory(items: [], threadID: "thread")
        store.apply(method: "item/started", params: json([
            "threadId": "thread", "turnId": "turn",
            "item": ["type": "agentMessage", "id": "answer", "phase": "final_answer", "text": ""]
        ]), threadID: "thread")
        for _ in 0..<250 {
            store.apply(method: "item/agentMessage/delta", params: json([
                "threadId": "thread", "turnId": "turn", "itemId": "answer", "delta": "x"
            ]), threadID: "thread")
        }

        #expect(store.activeTruthTranscript.turns.first?.finalAnswer?.text.count == 250)
        #expect(store.activePresentation?.transcript.turns.isEmpty == true)
        #expect(store.diagnostics.presentationScheduleCount == 1)
        #expect(store.diagnostics.coalescedPureDeltaCount == 250)

        store.synchronizePresentation()
        #expect(store.activePresentation?.transcript.turns.first?.finalAnswer?.text.count == 250)
        #expect(store.diagnostics.presentationPublishCount == 3)
    }

    @Test func coldHistoryReplaysLiveEventsThatArrivedDuringLoad() throws {
        let store = CodexThreadUISessionStore()
        store.apply(method: "turn/started", params: json([
            "threadId": "thread", "turn": ["id": "live"]
        ]), threadID: "thread")
        store.apply(method: "item/completed", params: json([
            "threadId": "thread", "turnId": "live",
            "item": ["type": "agentMessage", "id": "live-answer", "phase": "final_answer", "text": "Live"]
        ]), threadID: "thread")

        #expect(store.restoreHistory(items: [
            json(["type": "userMessage", "id": "history-user", "content": [["type": "text", "text": "History"]]])
        ], threadID: "thread"))
        let transcript = try #require(store.truthTranscript(for: "thread"))
        #expect(transcript.turns.contains { $0.userMessage?.text == "History" })
        #expect(transcript.turns.contains { $0.finalAnswer?.text == "Live" })
    }

    @Test func independentThreadStatusTracksInactiveUnreadAndClearsOnSelect() throws {
        let status = CodexThreadStatusStore()
        status.select(threadID: "A")
        status.apply(method: "turn/started", threadID: "B", at: Date(timeIntervalSince1970: 1))
        #expect(status.entries["B"]?.status == .running)
        #expect(status.entries["B"]?.hasUnreadWhileInactive == false)

        status.apply(method: "turn/completed", threadID: "B", at: Date(timeIntervalSince1970: 2))
        #expect(status.entries["B"]?.status == .idle)
        #expect(status.entries["B"]?.hasUnreadWhileInactive == true)

        status.select(threadID: "B")
        #expect(status.entries["B"]?.hasUnreadWhileInactive == false)
        status.apply(method: "turn/failed", threadID: "A", at: Date(timeIntervalSince1970: 3))
        #expect(status.entries["A"]?.status == .failed)
        #expect(status.entries["A"]?.hasUnreadWhileInactive == true)

        status.apply(method: "turn/completed", params: json([
            "threadId": "C", "turn": ["id": "turn-c", "error": "boom"]
        ]), threadID: "C", at: Date(timeIntervalSince1970: 4))
        #expect(status.entries["C"]?.status == .failed)
    }

    private func json(_ value: Any) -> CodexJSONValue {
        try! JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }
}
