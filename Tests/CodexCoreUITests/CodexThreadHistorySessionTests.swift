import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexThreadHistorySessionTests {
    @Test func threadReadAdapterRetainsTurnTimingEnvelope() throws {
        let raw = json([
            "thread": [
                "id": "thread",
                "turns": [[
                    "id": "turn",
                    "startedAt": 100,
                    "completedAt": 108,
                    "durationMs": 8_000,
                    "items": [["type": "agentMessage", "id": "answer", "text": "Done"]]
                ]]
            ]
        ])

        let turns = CodexThreadHistorySession.transcriptTurns(from: raw)
        let turn = try #require(turns.first?.object)
        #expect(turn["id"] == .string("turn"))
        #expect(turn["startedAt"] == .int(100))
        #expect(turn["completedAt"] == .int(108))
        #expect(turn["durationMs"] == .int(8_000))
    }

    private func json(_ value: Any) -> CodexJSONValue {
        try! JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }
}

private extension CodexJSONValue {
    var object: [String: CodexJSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }
}
