@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexChatRuntimeTranscriptIngressTests {
    @Test func dualStreamsFeedTheV2ReducerExactlyOnce() throws {
        let runtime = CodexChatRuntimeSession()
        runtime.selectThread("thread")
        _ = runtime.transcriptSessions.restoreHistory(items: [], threadID: "thread")
        let started = notification(method: "item/started", params: [
            "threadId": .string("thread"),
            "turnId": .string("turn"),
            "item": .dictionary([
                "type": .string("agentMessage"),
                "id": .string("answer"),
                "phase": .string("final_answer"),
                "text": .string("")
            ])
        ])
        let delta = notification(method: "item/agentMessage/delta", params: [
            "threadId": .string("thread"),
            "turnId": .string("turn"),
            "itemId": .string("answer"),
            "delta": .string("x")
        ])

        for event in [started, delta] {
            runtime.applyTranscriptNotification(event, fallbackThreadID: nil, source: .mainTurn)
            runtime.applyTranscriptNotification(event, fallbackThreadID: nil, source: .global)
        }
        runtime.transcriptSessions.synchronizePresentation()

        #expect(runtime.transcriptV2.turns.first?.finalAnswer?.text == "x")
        #expect(runtime.transcriptIngressDeduplicationCount == 2)
        #expect(runtime.transcriptSessions.diagnostics.reducerApplyCount == 2)
    }

    @Test func actualNotificationThreadRoutesInactiveStateAndUnread() throws {
        let runtime = CodexChatRuntimeSession()
        runtime.selectThread("A")
        _ = runtime.transcriptSessions.restoreHistory(items: [], threadID: "A")
        let turnStarted = notification(method: "turn/started", params: [
            "threadId": .string("B"),
            "turn": .dictionary(["id": .string("turn-b")])
        ])
        let itemCompleted = notification(method: "item/completed", params: [
            "threadId": .string("B"),
            "turnId": .string("turn-b"),
            "item": .dictionary([
                "type": .string("agentMessage"),
                "id": .string("answer-b"),
                "phase": .string("final_answer"),
                "text": .string("Answer B")
            ])
        ])
        let turnCompleted = notification(method: "turn/completed", params: [
            "threadId": .string("B"),
            "turn": .dictionary(["id": .string("turn-b"), "durationMs": .int(100)])
        ])

        for event in [turnStarted, itemCompleted, turnCompleted] {
            runtime.applyTranscriptNotification(event, fallbackThreadID: "A", source: .global)
        }

        #expect(runtime.transcriptSessions.truthTranscript(for: "B")?.turns.first?.finalAnswer?.text == "Answer B")
        #expect(runtime.transcriptV2.turns.isEmpty)
        #expect(runtime.threadStatusStore.entries["B"]?.status == .idle)
        #expect(runtime.threadStatusStore.entries["B"]?.hasUnreadWhileInactive == true)

        runtime.selectThread("B")
        #expect(runtime.threadStatusStore.entries["B"]?.hasUnreadWhileInactive == false)
    }

    private func notification(method: String, params: [String: CodexJSONValue]) -> CodexNotification {
        CodexNotification(
            method: method,
            payload: .unknown(method: method, params: params),
            rawParams: params
        )
    }
}
