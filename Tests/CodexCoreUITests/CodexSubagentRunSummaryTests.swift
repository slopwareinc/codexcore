import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexSubagentRunSummaryTests: XCTestCase {
    func testMilestonesPreserveOrderAndWaitCompletionPrecedence() {
        let events = [
            event(status: .spawning, title: "Spawning Reviewer", agentNames: ["Reviewer"], at: 1),
            event(status: .running, title: "Waiting for Reviewer", at: 2),
            event(status: .completed, title: "Finished waiting", at: 3),
            event(status: .failed, title: "Reviewer failed", at: 4)
        ]

        let summary = CodexSubagentRunSummary(events: events)

        XCTAssertEqual(summary.milestones.map(\.id), ["spawn", "wait-complete", "failed"])
        XCTAssertEqual(summary.milestones.map(\.title), [
            "Starting Reviewer",
            "Received agent output",
            "Reviewer failed"
        ])
        XCTAssertEqual(summary.milestones.map(\.status), [.spawning, .completed, .failed])
    }

    func testMilestonesUseTheLatestWaitingAndFailureDetails() {
        let events = [
            event(status: .running, title: "Waiting for Planner", at: 1),
            event(status: .running, title: "Waiting for Reviewer", at: 2),
            event(status: .failed, title: "Planner failed", at: 3),
            event(status: .failed, title: "Reviewer failed", at: 4)
        ]

        let summary = CodexSubagentRunSummary(events: events)

        XCTAssertEqual(summary.milestones.map(\.id), ["wait", "failed"])
        XCTAssertEqual(summary.milestones.map(\.title), [
            "Waiting for Reviewer",
            "Reviewer failed"
        ])
    }

    private func event(
        status: CodexAgentLifecycleEvent.Status,
        title: String,
        agentNames: [String] = [],
        at seconds: TimeInterval
    ) -> CodexAgentLifecycleEvent {
        CodexAgentLifecycleEvent(
            status: status,
            title: title,
            agentNames: agentNames,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }
}
