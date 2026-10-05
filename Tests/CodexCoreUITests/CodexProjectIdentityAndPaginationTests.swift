import Foundation
import Testing
import CodexCore
@testable import CodexCoreUI

struct CodexProjectIdentityAndPaginationTests {
    @Test func sharedRootProjectsRetainDistinctIdentityAndMembership() {
        let first = project("first"), second = project("second")
        let chatA = CodexThreadSummary(id: "a", title: "A", workspacePath: "/elsewhere", projectID: "first")
        let chatB = CodexThreadSummary(id: "b", title: "B", workspacePath: "/repo", projectID: "second")
        let presented = CodexSidebarProjection.presentedProjects(serverProjects: [first, second], chats: [chatA, chatB], currentWorkspacePath: "/repo", projectlessThreadIDs: [], sourceFoldersByPrimaryPath: ["/repo": ["/wrong"]])
        #expect(presented.map(\.id) == ["first", "second"])
        #expect(presented.map(\.sourceFolders) == [["/repo", "/other"], ["/repo", "/other"]])
        #expect(presented.map(\.chatCount) == [1, 1])
        let sidebar = CodexSidebarProjection.snapshot(.init(projects: presented, chats: [chatA, chatB], currentWorkspacePath: "/repo", selectedProjectID: "second", now: 3))
        #expect(sidebar.projects.first?.rows.map(\.id) == ["a"])
        #expect(sidebar.projects.last?.rows.map(\.id) == ["b"])
        #expect(sidebar.projects.first?.isSelected == false)
        #expect(sidebar.projects.last?.isSelected == true)
    }

    @Test func legacyFolderPreferencesMigrateAndSharedRootProjectsAreIndependent() {
        let projects = [project("first"), project("second")]
        var session = CodexSidebarNavigationSession(currentWorkspacePath: "/repo", expandedProjectIDs: ["/repo"], projectOrder: ["/repo"], pinnedProjectIDs: ["/repo"], projectAliases: ["/repo": "Old alias", "second": "Explicit alias"])
        let mutationResult1 = session.reconcileProjectIdentities(projects)
        #expect(mutationResult1)
        #expect(session.expandedProjectIDs == ["first", "second"])
        #expect(session.projectOrder == ["first", "second"])
        #expect(session.pinnedProjectIDs == ["first", "second"])
        #expect(session.projectAliases == ["first": "Old alias", "second": "Explicit alias"])
        let mutationResult2 = !session.reconcileProjectIdentities(projects)
        #expect(mutationResult2)
        session.toggleProject("first")
        session.removeProject("first")
        session.selectProject("second", workspacePath: "/repo")
        let snapshot = session.snapshot(projects: projects, chats: [], currentWorkspacePath: "/repo", currentThreadID: nil)
        #expect(snapshot.pinnedProjects.map(\.id) == ["second"])
        #expect(snapshot.pinnedProjects.first?.isSelected == true)
        #expect(snapshot.pinnedProjects.first?.isExpanded == true)
        #expect(session.selectedProjectPath == "/repo")
        #expect(session.selectedProjectID == "second")
    }

    @Test func opaqueProjectIdentitiesRoundTripPreferencesWithoutBecomingPaths() {
        let store = IdentityPreferenceStore()
        CodexExpandedProjectStorage.saveExpandedProjectIDs(["server-id", "/repo/../repo"], to: store)
        #expect(CodexExpandedProjectStorage.loadExpandedProjectState(from: store).ids == ["server-id", "/repo"])
        #expect(CodexProjectOrderStorage.saveProjectOrder(["server-id", "/repo"], to: store))
        #expect(CodexProjectOrderStorage.loadProjectOrder(from: store) == ["server-id", "/repo"])
        #expect(CodexPinnedProjectStorage.savePinnedProjectIDs(["server-id"], to: store))
        #expect(CodexPinnedProjectStorage.loadPinnedProjectIDs(from: store) == ["server-id"])
        CodexHiddenProjectStorage.saveHiddenProjectIDs(["server-id"], to: store)
        #expect(CodexHiddenProjectStorage.loadHiddenProjectIDs(from: store) == ["server-id"])
        CodexProjectAliasStorage.saveProjectAliases(["server-id": "My project"], to: store)
        #expect(CodexProjectAliasStorage.loadProjectAliases(from: store) == ["server-id": "My project"])
    }

    @Test func serverProjectPagesMergeByServerIdentity() {
        var session = CodexThreadListSession(currentWorkspacePath: "/repo")
        session.applyProjectList(.init(data: [schemaProject("first")], nextCursor: "next"))
        session.applyProjectList(.init(data: [schemaProject("second")]), reset: false)
        #expect(Set(session.serverProjects.map(\.id)) == ["first", "second"])
    }

    @Test func activePagesDeduplicateUpdateAndRejectCursorLoops() throws {
        var session = CodexThreadListSession(currentWorkspacePath: "/repo")
        let initial = try CodexJSONValue(encoding: CodexSchemaThreadListResponse(data: [thread("a", name: "old")], nextCursor: "next"))
        session.applyThreadList(currentRaw: initial, allRaw: initial, currentWorkspacePath: "/repo")
        let mutationResult3 = session.beginActivePageLoad() == "next"
        #expect(mutationResult3)
        let mutationResult4 = session.beginActivePageLoad() == nil
        #expect(mutationResult4)
        let mutationResult5 = session.applyActivePage(.init(data: [thread("a", name: "new"), thread("b")], nextCursor: "last"), currentWorkspacePath: "/repo")
        #expect(mutationResult5)
        #expect(session.allChats.count == 2)
        #expect(session.allChats.first { $0.id == "a" }?.title == "new")
        #expect(session.allChats.first { $0.id == "a" }?.projectID == "first")
        let mutationResult6 = session.beginActivePageLoad() == "last"
        #expect(mutationResult6)
        let mutationResult7 = !session.applyActivePage(.init(data: [], nextCursor: "next"), currentWorkspacePath: "/repo")
        #expect(mutationResult7)
        #expect(session.activeNextCursor == nil)
        #expect(session.activeErrorMessage?.contains("repeated") == true)
    }

    @Test func searchPagesKeepQueryScopeAndRetryFailedPages() {
        var session = CodexThreadListSession(currentWorkspacePath: "/repo")
        let mutationResult8 = session.beginSearch(query: "one") == "one"
        #expect(mutationResult8)
        let mutationResult9 = session.applySearchPage(.init(data: [.init(snippet: "first", thread: thread("a"))], nextCursor: "next"), query: "one", reset: true)
        #expect(mutationResult9)
        let page = session.beginSearchPageLoad()
        #expect(page?.query == "one")
        session.cancelSearchPageLoad(cursor: "next", message: "offline")
        #expect(session.searchResults.count == 1)
        let mutationResult10 = session.beginSearchPageLoad()?.cursor == "next"
        #expect(mutationResult10)
        let mutationResult11 = session.applySearchPage(.init(data: [.init(snippet: "updated", thread: thread("a")), .init(snippet: "second", thread: thread("b"))]), query: "one")
        #expect(mutationResult11)
        #expect(session.searchResults.map(\.snippet) == ["updated", "second"])
        _ = session.beginSearch(query: "two")
        let mutationResult12 = !session.applySearchPage(.init(data: []), query: "one", reset: true)
        #expect(mutationResult12)
        #expect(session.isSearching)
        #expect(session.searchQuery == "two")
    }

    private func project(_ id: String) -> CodexProjectSummary { .init(schema: schemaProject(id)) }
    private func schemaProject(_ id: String) -> CodexSchemaProject {
        .init(createdAt: 1, id: id, metadata: [:], name: id, position: id == "first" ? 0 : 1, roots: [.init(path: .init(.string("/repo"))), .init(path: .init(.string("/other")))], updatedAt: 2)
    }
    private func thread(_ id: String, name: String = "Chat") -> CodexSchemaThread {
        .init(cliVersion: "0.160.0", createdAt: 1, cwd: .init(.string("/repo")), ephemeral: false, id: id, modelProvider: "openai", name: name, preview: "", projectID: "first", sessionID: "session", source: .init(.string("appServer")), status: .unrecognized(type: "idle", rawValue: .dictionary(["type": .string("idle")])), turns: [], updatedAt: 2)
    }
}

private final class IdentityPreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]
    func loadStrings(forKey key: String) -> [String] { lock.withLock { values[key] ?? [] } }
    func saveStrings(_ strings: [String], forKey key: String) { lock.withLock { values[key] = strings } }
    func hasStrings(forKey key: String) -> Bool { lock.withLock { values[key] != nil } }
}
