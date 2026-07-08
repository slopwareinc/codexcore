import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexTimelineProjectionTests: XCTestCase {
    func testExplorationMerging() throws {
        let items: [CodexTimelineItem] = [
            .userMessage(id: "u-1", text: "Check workspace status", timestamp: Date()),
            .commandExecution(id: "expl-1", command: "git status", output: "Clean", status: "completed", timestamp: Date()),
            .commandExecution(id: "expl-2", command: "pwd", output: "/Users/dev", status: "completed", timestamp: Date()),
            .assistantMessage(id: "a-1", text: "Everything is clean.", timestamp: Date(), isStreaming: false)
        ]

        let projected = CodexTimelineProjection.project(items)
        XCTAssertEqual(projected.count, 3)

        // First is user message
        if case .item(let item) = projected[0] {
            XCTAssertEqual(item.id, "u-1")
        } else {
            XCTFail()
        }

        // Second is merged exploration group
        if case .exploration(let id, let expItems) = projected[1] {
            XCTAssertTrue(id.hasPrefix("exploration-"))
            XCTAssertEqual(expItems.count, 2)
            XCTAssertEqual(expItems[0].id, "expl-1")
            XCTAssertEqual(expItems[1].id, "expl-2")
        } else {
            XCTFail()
        }

        // Third is assistant message
        if case .item(let item) = projected[2] {
            XCTAssertEqual(item.id, "a-1")
        } else {
            XCTFail()
        }
    }

    func testLiveDetailRetentionPolicy() throws {
        let items: [CodexTimelineItem] = [
            .assistantMessage(id: "a-1", text: "Finished step 1", timestamp: Date(), isStreaming: false),
            .commandExecution(id: "c-1", command: "build", output: "Success", status: "completed", timestamp: Date()),
            .assistantMessage(id: "a-2", text: "Starting step 2...", timestamp: Date(), isStreaming: true)
        ]

        let retained = CodexLiveDetailRetentionPolicy.retainedRichDetailItemIDs(for: items)
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.contains("a-2")) // Active streaming retained
        XCTAssertTrue(retained.contains("c-1")) // Latest completed item retained
        XCTAssertFalse(retained.contains("a-1")) // Older prunable item removed
    }
}
