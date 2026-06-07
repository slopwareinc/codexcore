import XCTest
import CodexCore
@testable import CodexCoreUI

final class CodexAgentStateMapperTests: XCTestCase {
    func testStartsAgentsFromRawSpawnArray() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "spawn-1",
          "type": "subAgentThreadSpawn",
          "text": "Created Chandrasekhar and Copernicus",
          "summary": "Created two side agents",
          "agents": [
            {
              "id": "agent-chandrasekhar",
              "name": "Chandrasekhar",
              "title": "Chat and composer inspection",
              "prompt": "Inspect chat/composer UX"
            },
            {
              "id": "agent-copernicus",
              "name": "Copernicus",
              "title": "Side-panel inspection",
              "prompt": "Inspect side panel UX"
            }
          ]
        }
        """#)

        var mapper = CodexAgentStateMapper()
        let update = mapper.itemStarted(item)

        XCTAssertEqual(update?.activityTitle, "Subagents started")
        XCTAssertEqual(mapper.lifecycleEvents.last?.status, .spawning)
        XCTAssertEqual(mapper.lifecycleEvents.last?.agentNames, ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(mapper.sideChat?.title, "Side chat")
        XCTAssertEqual(mapper.subagents.map(\.name), ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(mapper.subagents.map(\.status), [.running, .running])
        XCTAssertEqual(mapper.subagents[0].messages.first?.text, "Inspect chat/composer UX")
    }

    func testCompletesAgentFromRawResultPayload() throws {
        let started = try decodeThreadItem(#"""
        {
          "id": "review-1",
          "type": "subAgentReview",
          "agentName": "Guardian",
          "prompt": "Review the current diff"
        }
        """#)
        let completed = try decodeThreadItem(#"""
        {
          "id": "review-1",
          "type": "subAgentReview",
          "agentName": "Guardian",
          "status": "closed",
          "prompt": "Review the current diff",
          "result": "No blocking issues found."
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemStarted(started)
        let update = mapper.itemCompleted(completed)

        XCTAssertEqual(update?.activityTitle, "Subagents closed")
        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].name, "Guardian")
        XCTAssertEqual(mapper.subagents[0].status, .closed)
        XCTAssertEqual(mapper.subagents[0].messages.last?.role, .assistant)
        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "No blocking issues found.")
        XCTAssertEqual(mapper.lifecycleEvents.last?.status, .closed)
    }

    func testFindsNestedSourceThreadMetadata() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "fork-1",
          "type": "threadFork",
          "text": "Spawned Kepler to inspect architecture",
          "source": {
            "kind": "subAgentThreadSpawn",
            "thread": {
              "id": "thread-kepler",
              "title": "Kepler",
              "prompt": "Inspect architecture boundaries"
            }
          }
        }
        """#)

        var mapper = CodexAgentStateMapper()
        XCTAssertTrue(mapper.isSubagentItem(item))

        mapper.itemStarted(item)

        XCTAssertEqual(mapper.subagents.count, 1)
        XCTAssertEqual(mapper.subagents[0].id, "thread-kepler")
        XCTAssertEqual(mapper.subagents[0].name, "Kepler")
        XCTAssertEqual(mapper.subagents[0].prompt, "Inspect architecture boundaries")
    }

    func testDoesNotTreatPlainAssistantTextAsSubagentItem() throws {
        let item = try decodeThreadItem(#"""
        {
          "id": "assistant-1",
          "type": "assistantMessage",
          "text": "I can create a subagent if you want one."
        }
        """#)

        let mapper = CodexAgentStateMapper()

        XCTAssertFalse(mapper.isSubagentItem(item))
    }

    func testRoutesKnownItemDeltasIntoSubagentTranscript() throws {
        let started = try decodeThreadItem(#"""
        {
          "id": "delta-1",
          "type": "subAgentOther",
          "agentName": "Vega",
          "prompt": "Inspect streaming behavior"
        }
        """#)
        let completed = try decodeThreadItem(#"""
        {
          "id": "delta-1",
          "type": "subAgentOther",
          "agentName": "Vega",
          "status": "completed",
          "result": "Final streaming findings"
        }
        """#)

        var mapper = CodexAgentStateMapper()
        mapper.itemStarted(started)

        XCTAssertTrue(mapper.messageDelta("Partial", itemID: "delta-1"))
        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Partial")
        XCTAssertTrue(mapper.subagents[0].messages.last?.isStreaming ?? false)
        XCTAssertFalse(mapper.messageDelta("Parent", itemID: "parent-message"))

        mapper.itemCompleted(completed)

        XCTAssertEqual(mapper.subagents[0].messages.last?.text, "Final streaming findings")
        XCTAssertFalse(mapper.subagents[0].messages.last?.isStreaming ?? true)
    }
}

private func decodeThreadItem(_ json: String) throws -> ThreadItem {
    try JSONDecoder().decode(ThreadItem.self, from: Data(json.utf8))
}
