import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexSidebarInboxDataTests {
    @Test func inboxRetainsFullRosterIndependentOfTreePreviewAndProjectAge() {
        let project = CodexProjectSummary(workspacePath: "/repo", updatedAt: 1)
        let chats = (0..<12).map {
            CodexThreadSummary(id: "chat-\($0)", title: "Task \($0)", workspacePath: "/repo", createdAt: Double($0))
        }
        let snapshot = CodexSidebarProjection.snapshot(.init(
            projects: [project], chats: chats, currentWorkspacePath: "/repo",
            currentThreadID: "chat-0", expandedProjectIDs: [],
            now: 1_000_000, projectChatPreviewLimit: 5
        ))

        #expect(snapshot.projects.isEmpty)
        #expect(snapshot.olderProjects.first?.rows.count == 5)
        #expect(snapshot.olderProjects.first?.hiddenRowCount == 7)
        #expect(snapshot.inboxRows.map(\.id) == chats.map(\.id))
        #expect(snapshot.inboxRows.first?.isSelected == true)
        #expect(snapshot.inboxProjects.map(\.id) == [project.id])
    }

    @Test func inboxIncludesPinsProjectlessAndCollapsedSectionsWithoutDuplicates() {
        let chats: [CodexThreadSummary] = [
            .init(id: "pinned", title: "Pinned", workspacePath: "/pinned-only"),
            .init(id: "projectless", title: "Projectless", workspacePath: "/outside"),
            .init(id: "sectioned", title: "Sectioned", workspacePath: "/repo", sectionID: "s"),
            .init(id: "child", title: "Agent", workspacePath: "/repo", parentThreadID: "sectioned"),
            .init(id: "ephemeral", title: "Transient", workspacePath: "/repo", isEphemeral: true),
            .init(id: "pinned", title: "Duplicate", workspacePath: "/pinned-only"),
        ]
        let snapshot = CodexSidebarProjection.snapshot(.init(
            chats: chats, sections: [.init(id: "s", name: "Custom")],
            currentWorkspacePath: "/repo", pinnedThreadIDs: ["pinned"],
            projectlessThreadIDs: ["projectless"], collapsedSectionIDs: ["s"]
        ))

        #expect(snapshot.inboxRows.map(\.id) == ["pinned", "projectless", "sectioned"])
        #expect(snapshot.inboxRows.first?.isPinned == true)
        #expect(snapshot.inboxRows.first?.summary.title == "Pinned")
        #expect(snapshot.inboxProjects.contains { $0.workspacePath == "/pinned-only" })
        #expect(!snapshot.inboxProjects.contains { $0.workspacePath == "/outside" })
    }

    @Test func inboxVisibilityUsesServerIdentityBeforeSharedFolderAndRetainsIndependentPlacements() {
        let hidden = CodexProjectSummary(workspacePath: "/shared", serverID: "hidden")
        let visible = CodexProjectSummary(workspacePath: "/shared", serverID: "visible")
        let chats: [CodexThreadSummary] = [
            .init(id: "hidden", title: "Hidden", workspacePath: "/shared", projectID: "hidden"),
            .init(id: "visible", title: "Visible", workspacePath: "/shared", projectID: "visible"),
            .init(id: "pin", title: "Pin", workspacePath: "/shared", projectID: "hidden"),
            .init(id: "loose", title: "Loose", workspacePath: "/shared", projectID: "hidden"),
            .init(id: "custom", title: "Custom", workspacePath: "/shared", projectID: "hidden", sectionID: "s"),
            .init(id: "legacy", title: "Legacy", workspacePath: "/shared"),
        ]
        let snapshot = CodexSidebarProjection.snapshot(.init(
            projects: [hidden, visible], chats: chats,
            sections: [.init(id: "s", name: "Section")], currentWorkspacePath: "/shared",
            pinnedThreadIDs: ["pin"], projectlessThreadIDs: ["loose"],
            hiddenProjectIDs: ["hidden"], projectAliases: ["visible": "My workspace"]
        ))

        #expect(snapshot.inboxRows.map(\.id) == ["visible", "pin", "loose", "custom"])
        #expect(snapshot.inboxProjects.map(\.id) == ["visible"])
        #expect(snapshot.inboxProjects.first?.displayName == "My workspace")
    }

    @Test func pinnedProjectlessIdentitySurvivesMatchingWorkspacePath() throws {
        let snapshot = CodexSidebarProjection.snapshot(.init(
            projects: [.init(workspacePath: "/repo")],
            chats: [.init(id: "loose-pin", title: "Outside project", workspacePath: "/repo")],
            currentWorkspacePath: "/repo", pinnedThreadIDs: ["loose-pin"],
            projectlessThreadIDs: ["loose-pin"]
        ))
        let row = try #require(snapshot.inboxRows.first)
        #expect(row.isProjectless)
        #expect(snapshot.pinnedRows.first?.isProjectless == true)
        #expect(snapshot.inboxRows.first?.summary.projectID == nil)
    }

    @Test func inboxCarriesAttentionWithoutReclassifyingLiveLifecycleOrUnreadState() throws {
        let snapshot = CodexSidebarProjection.snapshot(.init(
            chats: [.init(id: "active", title: "Approval", workspacePath: "/repo")],
            archivedChats: [.init(id: "archived", title: "History")],
            currentWorkspacePath: "/repo",
            threadStatusEntries: [
                "active": .init(status: .running, attention: .approval, hasUnreadWhileInactive: true),
                "archived": .init(status: .running, attention: .input, hasUnreadWhileInactive: true),
            ]
        ))
        let row = try #require(snapshot.inboxRows.first)
        #expect(row.liveStatus == .running)
        #expect(row.attention == .approval)
        #expect(row.hasUnreadWhileInactive)
        #expect(snapshot.archivedRows.first?.attention == nil)
        #expect(snapshot.archivedRows.first?.liveStatus == .idle)
    }

    @Test func canonicalAttentionUsesExactFlagsAndApprovalPrecedence() {
        #expect(CodexSidebarThreadAttention.resolve(.active(flags: [.waitingOnApproval, .waitingOnUserInput])) == .approval)
        #expect(CodexSidebarThreadAttention.resolve(.active(flags: [.waitingOnUserInput])) == .input)
        #expect(CodexSidebarThreadAttention.resolve(.active(flags: [.unknown("futureFlag")])) == nil)
        #expect(CodexSidebarThreadAttention.resolve(.active(flags: [])) == nil)
        #expect(CodexSidebarThreadAttention.resolve(.idle) == nil)
        #expect(CodexSidebarThreadAttention.resolve(.notLoaded) == nil)
    }

    @Test func gitBranchSurvivesTypedRawSearchAndPagedListAdapters() throws {
        let schema = schemaThread(branch: "feature/sidebar")
        let raw = try CodexJSONValue(encoding: schema)
        #expect(CodexThreadSummary(schema: schema).gitBranch == "feature/sidebar")
        #expect(CodexThreadSummary(raw: raw)?.gitBranch == "feature/sidebar")
        #expect(CodexThreadSearchResult(raw: .dictionary(["thread": raw]))?.thread.gitBranch == "feature/sidebar")
        var session = CodexThreadListSession(currentWorkspacePath: "/repo")
        let page = try CodexJSONValue(encoding: CodexSchemaThreadListResponse(data: [schema], nextCursor: "next"))
        session.applyThreadList(currentRaw: page, allRaw: page, currentWorkspacePath: "/repo")
        session.renameThread(id: schema.id, title: "Renamed", currentWorkspacePath: "/repo")
        #expect(session.allChats.first?.gitBranch == "feature/sidebar")
        _ = session.applyActivePage(.init(data: [schemaThread(branch: "main")]), currentWorkspacePath: "/repo")
        #expect(session.allChats.first?.gitBranch == "main")
        #expect(session.allChats.first?.modelProvider == "openai")
    }

    @Test func missingOrBlankBranchDoesNotInventRepositoryMetadata() {
        #expect(CodexThreadSummary(id: "chat", title: "Chat").gitBranch == nil)
        #expect(CodexThreadSummary(schema: schemaThread(branch: " \n ")).gitBranch == nil)
        #expect(CodexThreadSummary(raw: .dictionary(["id": .string("chat"), "gitInfo": .null]))?.gitBranch == nil)
    }

    private func schemaThread(branch: String?) -> CodexSchemaThread {
        .init(
            cliVersion: "test", createdAt: 1, cwd: .init(.string("/repo")), ephemeral: false,
            gitInfo: .init(branch: branch), id: "chat", modelProvider: "openai", name: "Chat",
            preview: "", sessionID: "session", source: .init(.string("cli")),
            status: .unrecognized(type: "idle", rawValue: .dictionary(["type": .string("idle")])),
            turns: [], updatedAt: 2
        )
    }
}
