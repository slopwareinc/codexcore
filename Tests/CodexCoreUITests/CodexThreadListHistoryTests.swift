import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexThreadListHistoryTests: XCTestCase {
    func testThreadSummariesParseRawAppServerThreadList() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-main"),
                    "name": .string("Plan the release"),
                    "preview": .string("Ship the Swift example"),
                    "cwd": .string("/tmp/CodexCore"),
                    "status": .dictionary(["type": .string("idle")]),
                    "modelProvider": .string("openai"),
                    "parentThreadId": .null,
                    "ephemeral": .bool(false),
                    "createdAt": .int(1_000),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-side"),
                    "name": .null,
                    "preview": .string("Side investigation"),
                    "cwd": .string("/tmp/CodexCore"),
                    "status": .string("active"),
                    "parentThreadId": .string("thread-main"),
                    "ephemeral": .bool(true),
                    "createdAt": .int(1_100),
                    "updatedAt": .int(1_200)
                ])
            ])
        ])

        let summaries = CodexThreadSummary.summaries(from: response)

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].title, "Plan the release")
        XCTAssertEqual(summaries[0].detail, "Ship the Swift example")
        XCTAssertEqual(summaries[0].status, "idle")
        XCTAssertEqual(summaries[0].workspacePath, "/tmp/CodexCore")
        XCTAssertEqual(summaries[0].updatedAt, 2_000)
        XCTAssertEqual(summaries[1].title, "Side investigation")
        XCTAssertEqual(summaries[1].status, "active")
        XCTAssertEqual(summaries[1].parentThreadID, "thread-main")
        XCTAssertTrue(summaries[1].isEphemeral)
    }

    func testThreadSearchResultsParseRawAppServerResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "thread": .dictionary([
                        "id": .string("thread-search-hit"),
                        "name": .string("Searchable planning chat"),
                        "preview": .string("Release checklist"),
                        "cwd": .string("/tmp/CodexCore"),
                        "status": .dictionary(["type": .string("idle")]),
                        "parentThreadId": .null,
                        "ephemeral": .bool(false),
                        "createdAt": .int(1_000),
                        "updatedAt": .int(2_000)
                    ]),
                    "snippet": .string("Found NEEDLE in the transcript")
                ])
            ]),
            "nextCursor": .null,
            "backwardsCursor": .null
        ])

        let results = CodexThreadSearchResult.results(from: response)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "thread-search-hit")
        XCTAssertEqual(results[0].thread.title, "Searchable planning chat")
        XCTAssertEqual(results[0].thread.workspacePath, "/tmp/CodexCore")
        XCTAssertEqual(results[0].thread.status, "idle")
        XCTAssertEqual(results[0].snippet, "Found NEEDLE in the transcript")
    }

    func testThreadListSessionOwnsRecentProjectAndSearchState() {
        let currentResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Current chat"),
                    "preview": .string("Current preview"),
                    "cwd": .string("/tmp/CodexCore"),
                    "ephemeral": .bool(false),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-side"),
                    "name": .string("Side chat"),
                    "cwd": .string("/tmp/CodexCore"),
                    "parentThreadId": .string("thread-current"),
                    "ephemeral": .bool(true),
                    "updatedAt": .int(2_100)
                ])
            ])
        ])
        let allResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Current chat duplicate"),
                    "cwd": .string("/tmp/CodexCore"),
                    "ephemeral": .bool(false),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-other"),
                    "name": .string("Other chat"),
                    "cwd": .string("/tmp/Other"),
                    "ephemeral": .bool(false),
                    "updatedAt": .int(3_000)
                ])
            ])
        ])

        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/CodexCore")
        session.applyThreadList(currentRaw: currentResponse, allRaw: allResponse, currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertEqual(session.recentChats.map(\.id), ["thread-current"])
        XCTAssertEqual(session.recentProjects.map(\.workspacePath), ["/tmp/CodexCore", "/tmp/Other"])
        XCTAssertEqual(session.recentProjects.map(\.chatCount), [1, 1])

        session.beginSearch()
        XCTAssertTrue(session.isSearching)
        let count = session.applySearchResults(from: .dictionary([
            "data": .array([
                .dictionary([
                    "thread": .dictionary([
                        "id": .string("thread-current"),
                        "name": .string("Current chat"),
                        "cwd": .string("/tmp/CodexCore")
                    ]),
                    "snippet": .string("needle")
                ])
            ])
        ]))

        XCTAssertEqual(count, 1)
        XCTAssertFalse(session.isSearching)
        XCTAssertEqual(session.searchResults.first?.snippet, "needle")

        session.failSearch(message: "offline")
        XCTAssertEqual(session.searchErrorMessage, "offline")
        XCTAssertTrue(session.searchResults.isEmpty)
        XCTAssertFalse(session.isSearching)
    }

    func testProjectSummariesGroupVisibleThreadsByWorkspace() {
        let summaries = [
            CodexThreadSummary(
                id: "thread-a",
                title: "Current project chat",
                workspacePath: "/tmp/CodexCore",
                updatedAt: 2_000
            ),
            CodexThreadSummary(
                id: "thread-b",
                title: "Other project newest",
                workspacePath: "/tmp/Other",
                updatedAt: 3_000
            ),
            CodexThreadSummary(
                id: "thread-c",
                title: "Other project older",
                workspacePath: "/tmp/Other",
                updatedAt: 1_000
            )
        ]

        let projects = CodexProjectSummary.projects(from: summaries, currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertEqual(projects.map(\.workspacePath), ["/tmp/CodexCore", "/tmp/Other"])
        XCTAssertEqual(projects[0].displayName, "CodexCore")
        XCTAssertEqual(projects[0].chatCount, 1)
        XCTAssertEqual(projects[1].chatCount, 2)
        XCTAssertEqual(projects[1].updatedAt, 3_000)

        let noHistory = CodexProjectSummary.projects(from: [], currentWorkspacePath: "/tmp/NewProject")
        XCTAssertEqual(noHistory.map(\.workspacePath), ["/tmp/NewProject"])
        XCTAssertEqual(noHistory.first?.chatCount, 0)
    }

    func testThreadHistorySnapshotRestoresMessagesFromRawThreadRead() {
        let response: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-main"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-1"),
                        "startedAt": .int(1_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("user-1"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .dictionary([
                                        "type": .string("text"),
                                        "text": .string("Inspect the Swift app")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("assistant-1"),
                                "type": .string("agentMessage"),
                                "text": .string("I checked the app-server surface."),
                                "phase": .string("commentary")
                            ]),
                            .dictionary([
                                "id": .string("command-1"),
                                "type": .string("commandExecution"),
                                "command": .array([.string("swift"), .string("test")]),
                                "aggregatedOutput": .string("All tests passed"),
                                "status": .string("completed"),
                                "exitCode": .int(0),
                                "cwd": .string("/tmp/CodexCore")
                            ]),
                            .dictionary([
                                "id": .string("patch-1"),
                                "type": .string("fileChange"),
                                "status": .string("completed"),
                                "changes": .array([
                                    .dictionary([
                                        "path": .string("Sources/App.swift"),
                                        "kind": .dictionary(["type": .string("update")]),
                                        "diff": .string("""
                                        --- a/Sources/App.swift
                                        +++ b/Sources/App.swift
                                        @@ -1 +1 @@
                                        -old
                                        +new
                                        """)
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("plan-1"),
                                "type": .string("plan"),
                                "explanation": .string("Verify parity in small slices."),
                                "plan": .array([
                                    .dictionary([
                                        "step": .string("Inspect schema"),
                                        "status": .string("completed")
                                    ]),
                                    .dictionary([
                                        "step": .string("Render plan card"),
                                        "status": .string("inProgress")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("mcp-1"),
                                "type": .string("mcpToolCall"),
                                "server": .string("filesystem"),
                                "tool": .string("read_file"),
                                "arguments": .dictionary(["path": .string("Package.swift")]),
                                "status": .string("completed"),
                                "result": .dictionary([
                                    "content": .array([
                                        .dictionary([
                                            "type": .string("text"),
                                            "text": .string("package contents")
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ]),
                    .dictionary([
                        "id": .string("turn-2"),
                        "startedAt": .int(2_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("assistant-2"),
                                "type": .string("assistantMessage"),
                                "text": .string("Done."),
                                "phase": .string("final_answer")
                            ])
                        ])
                    ])
                ])
            ])
        ])

        let snapshot = CodexThreadHistorySnapshot(raw: response)

        XCTAssertEqual(snapshot.messages.map(\.role), [.user, .assistant, .terminal, .fileChange, .tool, .plan, .assistant])
        XCTAssertEqual(snapshot.messages[0].text, "Inspect the Swift app")
        XCTAssertEqual(snapshot.messages[1].text, "I checked the app-server surface.")
        XCTAssertEqual(snapshot.messages[1].detail, "commentary")
        XCTAssertEqual(snapshot.messages[2].commandRun?.command, "swift test")
        XCTAssertEqual(snapshot.messages[2].commandRun?.output, "All tests passed")
        XCTAssertEqual(snapshot.messages[2].commandRun?.exitCode, 0)
        XCTAssertEqual(snapshot.messages[2].commandRun?.cwd, "/tmp/CodexCore")
        XCTAssertEqual(snapshot.messages[3].fileChange?.path, "Sources/App.swift")
        XCTAssertEqual(snapshot.messages[3].fileChange?.addedLineCount, 1)
        XCTAssertEqual(snapshot.messages[3].fileChange?.removedLineCount, 1)
        let planMessage = snapshot.messages.first(where: { $0.planUpdate != nil })
        XCTAssertEqual(planMessage?.planUpdate?.explanation, "Verify parity in small slices.")
        XCTAssertEqual(planMessage?.planUpdate?.steps.map(\.status), ["completed", "inProgress"])
        let toolMessage = snapshot.messages.first(where: { $0.toolCall != nil })
        XCTAssertEqual(toolMessage?.toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(toolMessage?.toolCall?.result, "package contents")
        XCTAssertEqual(snapshot.messages[6].detail, "final_answer")
    }

}
