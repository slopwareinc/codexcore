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
                    "updatedAt": .int(2_000),
                    "recencyAt": .int(3_000)
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
        XCTAssertEqual(summaries[0].recencyAt, 3_000)
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
        XCTAssertEqual(session.allChats.map(\.id), ["thread-current", "thread-other"])
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

    func testThreadListSessionRenamesThreadAcrossSidebarAndSearchState() {
        let currentResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Old title"),
                    "cwd": .string("/tmp/CodexCore"),
                    "updatedAt": .int(2_000)
                ])
            ])
        ])
        let allResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Old title"),
                    "cwd": .string("/tmp/CodexCore"),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-other"),
                    "name": .string("Other chat"),
                    "cwd": .string("/tmp/Other"),
                    "updatedAt": .int(3_000)
                ])
            ])
        ])
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/CodexCore")
        session.applyThreadList(currentRaw: currentResponse, allRaw: allResponse, currentWorkspacePath: "/tmp/CodexCore")
        _ = session.applySearchResults(from: .dictionary([
            "data": .array([
                .dictionary([
                    "thread": .dictionary([
                        "id": .string("thread-current"),
                        "name": .string("Old title"),
                        "cwd": .string("/tmp/CodexCore")
                    ]),
                    "snippet": .string("needle")
                ])
            ])
        ]))

        session.renameThread(id: "thread-current", title: "  New title  ", currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertEqual(session.recentChats.first?.title, "New title")
        XCTAssertEqual(session.allChats.first(where: { $0.id == "thread-current" })?.title, "New title")
        XCTAssertEqual(session.searchResults.first?.thread.title, "New title")
        XCTAssertEqual(session.recentProjects.first?.displayName, "CodexCore")
    }

    func testThreadListSessionRemovesArchivedThreadAcrossSidebarAndSearchState() {
        let currentResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Current chat"),
                    "cwd": .string("/tmp/CodexCore"),
                    "updatedAt": .int(2_000)
                ])
            ])
        ])
        let allResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-current"),
                    "name": .string("Current chat"),
                    "cwd": .string("/tmp/CodexCore"),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-other"),
                    "name": .string("Other chat"),
                    "cwd": .string("/tmp/Other"),
                    "updatedAt": .int(3_000)
                ])
            ])
        ])
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/CodexCore")
        session.applyThreadList(currentRaw: currentResponse, allRaw: allResponse, currentWorkspacePath: "/tmp/CodexCore")
        _ = session.applySearchResults(from: .dictionary([
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

        session.removeThread(id: "thread-current", currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertTrue(session.recentChats.isEmpty)
        XCTAssertEqual(session.allChats.map(\.id), ["thread-other"])
        XCTAssertTrue(session.searchResults.isEmpty)
        XCTAssertEqual(session.recentProjects.map(\.workspacePath), ["/tmp/CodexCore", "/tmp/Other"])
        XCTAssertEqual(session.recentProjects.map(\.chatCount), [0, 1])
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

    func testSidebarRouteTransitionsPreserveSelectedChatAndSearchOverlayState() {
        var session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/CodexCore")

        session.selectChat("thread-current", workspacePath: "/tmp/CodexCore")
        session.selectRoute(.plugins)
        session.selectRoute(.automations)
        session.selectRoute(.codexMobile)
        session.selectRoute(.settingsAbout)

        XCTAssertEqual(session.selectedThreadID, "thread-current")
        XCTAssertEqual(session.selectedProjectPath, "/tmp/CodexCore")
        XCTAssertEqual(session.selectedRoute, .settingsAbout)

        session.selectRoute(.search)
        XCTAssertTrue(session.isSearchOverlayPresented)
        XCTAssertEqual(session.lastContentRoute, .settingsAbout)

        session.dismissSearchOverlay()
        XCTAssertFalse(session.isSearchOverlayPresented)
        XCTAssertEqual(session.selectedRoute, .settingsAbout)
        XCTAssertEqual(session.selectedThreadID, "thread-current")
    }

    func testSidebarCollapsedProjectSelectionAndExpansionState() {
        var session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertFalse(session.isCollapsed)
        session.toggleCollapsed()
        XCTAssertTrue(session.isCollapsed)
        session.setCollapsed(false)
        XCTAssertFalse(session.isCollapsed)
        XCTAssertFalse(session.expandedProjectIDs.contains("/tmp/CodexCore"))

        session.toggleProject("/tmp/CodexCore")
        XCTAssertTrue(session.expandedProjectIDs.contains("/tmp/CodexCore"))
        session.toggleProject("/tmp/CodexCore")
        XCTAssertFalse(session.expandedProjectIDs.contains("/tmp/CodexCore"))
        session.toggleProject("/tmp/Other")
        XCTAssertTrue(session.expandedProjectIDs.contains("/tmp/Other"))

        session.selectProject("/tmp/Other")
        XCTAssertEqual(session.selectedRoute, .chat)
        XCTAssertEqual(session.selectedProjectPath, "/tmp/Other")
        XCTAssertNil(session.selectedThreadID)
        XCTAssertTrue(session.expandedProjectIDs.contains("/tmp/Other"))
    }

    func testSidebarStartNewChatReturnsToChatRouteAndClearsThreadSelection() {
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp/CodexCore",
            selectedThreadID: "thread-current"
        )

        session.selectRoute(.settingsAbout)
        session.startNewChat(workspacePath: "/tmp/CodexCore")

        XCTAssertEqual(session.selectedRoute, .chat)
        XCTAssertEqual(session.lastContentRoute, .chat)
        XCTAssertEqual(session.selectedProjectPath, "/tmp/CodexCore")
        XCTAssertNil(session.selectedThreadID)
        XCTAssertTrue(session.expandedProjectIDs.contains("/tmp/CodexCore"))
    }

    func testSidebarSnapshotGroupsProjectsAndChildChatAffordances() {
        let chats = [
            CodexThreadSummary(
                id: "thread-current",
                title: "Current project chat",
                preview: "Preview",
                workspacePath: "/tmp/CodexCore",
                updatedAt: 2_000
            ),
            CodexThreadSummary(
                id: "thread-other",
                title: "Other project chat",
                workspacePath: "/tmp/Other",
                updatedAt: 3_000
            )
        ]
        let projects = CodexProjectSummary.projects(from: chats, currentWorkspacePath: "/tmp/CodexCore")
        var session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/CodexCore")

        session.selectChat("thread-other", workspacePath: "/tmp/Other")
        let snapshot = session.snapshot(
            projects: projects,
            chats: chats,
            currentWorkspacePath: "/tmp/CodexCore",
            currentThreadID: "thread-current"
        )

        XCTAssertEqual(snapshot.selectedRoute, .chat)
        XCTAssertEqual(snapshot.selectedThreadID, "thread-other")
        XCTAssertFalse(snapshot.showsNoChats)
        XCTAssertEqual(snapshot.projects.map(\.project.workspacePath), ["/tmp/CodexCore", "/tmp/Other"])

        let other = snapshot.projects[1]
        XCTAssertTrue(other.isSelected)
        XCTAssertTrue(other.isExpanded)
        XCTAssertTrue(other.canStartNewChat)
        XCTAssertTrue(other.hasProjectActionsEntry)
        XCTAssertEqual(other.rows.map(\.summary.id), ["thread-other"])
        XCTAssertTrue(other.rows[0].isSelected)
        XCTAssertTrue(other.rows[0].canPin)
        XCTAssertTrue(other.rows[0].canArchive)
    }

    func testSidebarSnapshotBuildsPinnedRowsAndAffordanceState() {
        let chats = [
            CodexThreadSummary(
                id: "thread-a",
                title: "Newest pinned",
                workspacePath: "/tmp/CodexCore",
                updatedAt: 4_000,
                recencyAt: 4_500
            ),
            CodexThreadSummary(
                id: "thread-b",
                title: "Older unpinned",
                workspacePath: "/tmp/CodexCore",
                updatedAt: 3_000,
                recencyAt: 3_500
            ),
            CodexThreadSummary(
                id: "thread-c",
                title: "Pinned by explicit order",
                workspacePath: "/tmp/Other",
                updatedAt: 2_000,
                recencyAt: 2_500
            )
        ]
        let projects = CodexProjectSummary.projects(from: chats, currentWorkspacePath: "/tmp/CodexCore")
        let session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/CodexCore")

        let snapshot = session.snapshot(
            projects: projects,
            chats: chats,
            currentWorkspacePath: "/tmp/CodexCore",
            currentThreadID: "thread-c",
            pinnedThreadIDs: ["thread-c", "thread-a"]
        )

        XCTAssertEqual(snapshot.pinnedRows.map(\.summary.id), ["thread-c", "thread-a"])
        XCTAssertEqual(snapshot.pinnedRows.map(\.isPinned), [true, true])
        XCTAssertEqual(snapshot.pinnedRows.map(\.canPin), [true, true])
        XCTAssertEqual(snapshot.pinnedRows.map(\.canArchive), [true, true])
        XCTAssertTrue(snapshot.pinnedRows[0].isSelected)

        let currentProjectRows = snapshot.projects.first?.rows ?? []
        XCTAssertEqual(currentProjectRows.map(\.summary.id), ["thread-a", "thread-b"])
        XCTAssertEqual(currentProjectRows.map(\.isPinned), [true, false])
    }

    func testSidebarSnapshotLimitsProjectRowsToFiveRecentChats() throws {
        let chats = (0..<7).map { index in
            CodexThreadSummary(
                id: "thread-\(index)",
                title: "Chat \(index)",
                workspacePath: "/tmp/CodexCore",
                updatedAt: TimeInterval(index)
            )
        }
        let projects = CodexProjectSummary.projects(from: chats, currentWorkspacePath: "/tmp/CodexCore")
        let session = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp/CodexCore",
            expandedProjectIDs: ["/tmp/CodexCore"]
        )

        let snapshot = session.snapshot(
            projects: projects,
            chats: chats,
            currentWorkspacePath: "/tmp/CodexCore",
            currentThreadID: nil
        )

        let project = try XCTUnwrap(snapshot.projects.first)
        XCTAssertTrue(project.isExpanded)
        XCTAssertEqual(project.rows.map(\.summary.id), ["thread-6", "thread-5", "thread-4", "thread-3", "thread-2"])
        XCTAssertEqual(project.hiddenRowCount, 2)
    }

    func testSidebarSessionRestoresExpandedProjectsWithoutOpeningCurrentByDefault() {
        let session = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp/CodexCore",
            expandedProjectIDs: ["/tmp/Other", "  ", "/tmp/Other/"]
        )

        XCTAssertFalse(session.expandedProjectIDs.contains("/tmp/CodexCore"))
        XCTAssertEqual(session.expandedProjectIDs, ["/tmp/Other"])
    }

    func testSidebarSnapshotShowsNoChatsEmptyState() {
        let session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/Empty")

        let snapshot = session.snapshot(
            projects: [],
            chats: [],
            currentWorkspacePath: "/tmp/Empty",
            currentThreadID: nil
        )

        XCTAssertTrue(snapshot.showsNoChats)
        XCTAssertEqual(snapshot.noChatsTitle, "No chats")
        XCTAssertEqual(snapshot.projects.map(\.project.workspacePath), ["/tmp/Empty"])
        XCTAssertEqual(snapshot.projects.first?.rows, [])
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
