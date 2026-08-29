import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexTranscriptRendererRecoveryTests {
    @Test func planItemsAreAdaptedThroughTheTypedEventRegistry() throws {
        let item = CanonicalItem(
            key: .init(threadID: "thread", turnID: "turn", itemID: "plan"),
            kind: .plan,
            payload: [
                "text": .string("Inspect the transcript"),
                "steps": .array([
                    .dictionary([
                        "step": .string("Read the protocol"),
                        "status": .string("inProgress")
                    ])
                ])
            ],
            authority: .completed
        )

        let event = try #require(
            CodexTranscriptEventRegistry().event(for: item, completed: true)
        )

        guard case .structuredCard(let card) = event else {
            Issue.record("Expected the plan adapter to emit a structured card")
            return
        }
        #expect(card.kind == .proposedPlan)
        #expect(card.title == "Inspect the transcript")
        #expect(card.steps.map(\.title) == ["Read the protocol"])
        #expect(card.steps.first?.status == .inProgress)
    }
}
