@testable import CodexCoreUI
import Testing

struct CodexT3SidebarInboxTests {
    @MainActor
    @Test func cachedProjectionRefreshesStatusAndScopeWithoutStaleProjectIdentity() {
        let alpha = CodexProjectSummary(workspacePath: "/alpha", sourceFolders: ["/secondary"], serverID: "alpha")
        let beta = CodexProjectSummary(workspacePath: "/beta", serverID: "beta")
        var first = row("alpha-chat", created: 1)
        first.summary.workspacePath = "/secondary"
        var second = row("beta-chat", created: 2)
        second.summary.projectID = "beta"
        let cache = CodexT3SidebarInboxProjectionCache()
        var state = snapshot(rows: [first, second], projects: [alpha, beta])
        #expect(cache.value(snapshot: state, scopeID: "alpha").active.map(\.id) == ["alpha-chat"])
        first.attention = .approval
        state.inboxRows = [first, second]
        #expect(cache.value(snapshot: state, scopeID: "alpha").active.first?.row.attention == .approval)
        #expect(cache.value(snapshot: state, scopeID: "beta").active.map(\.id) == ["beta-chat"])
    }

    @Test func inboxOrderStaysPutAcrossTitleActivityAndStatusChanges() {
        let first = row("a", created: 10, updated: 100)
        let second = row("b", created: 20, updated: 20)
        let third = row("c", created: 20, updated: 30)
        let before = CodexT3SidebarInboxProjection(snapshot: snapshot(rows: [first, third, second]))
        var changed = first
        changed.summary.title = "Renamed and now busy"
        changed.summary.updatedAt = 10_000
        changed.summary.recencyAt = 10_000
        changed.liveStatus = .running
        changed.hasUnreadWhileInactive = true
        let after = CodexT3SidebarInboxProjection(snapshot: snapshot(rows: [changed, second, third]))
        #expect(before.active.map(\.id) == ["b", "c", "a"])
        #expect(after.active.map(\.id) == before.active.map(\.id))
        #expect(after.active.last?.row.liveStatus == .running)
    }

    @Test func pinOrderAndCompletedChatCardsRemainIndependentOfHistory() {
        var olderPin = row("old-pin", created: 1)
        olderPin.isPinned = true
        var newerPin = row("new-pin", created: 30)
        newerPin.isPinned = true
        let completed = row("completed", created: 20)
        var state = snapshot(rows: [newerPin, completed, olderPin])
        state.pinnedRows = [olderPin, newerPin]
        let inbox = CodexT3SidebarInboxProjection(snapshot: state)
        #expect(inbox.pinned.map(\.id) == ["old-pin", "new-pin"])
        #expect(inbox.active.map(\.id) == ["completed"])
        #expect(inbox.archived.isEmpty)
    }

    @Test func projectFilterUsesOpaqueIDsAndNeverGuessesSharedRootsOrProjectlessPins() {
        let alpha = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "Alpha", serverID: "alpha")
        let beta = CodexProjectSummary(workspacePath: "/shared", customDisplayName: "Beta", serverID: "beta")
        var rows = [row("alpha-chat", created: 30), row("beta-chat", created: 20), row("legacy-chat", created: 10), row("projectless", created: 5)]
        for index in rows.indices { rows[index].summary.workspacePath = "/shared" }
        rows[0].summary.projectID = "alpha"
        rows[1].summary.projectID = "beta"
        rows[3].isProjectless = true
        rows[3].isPinned = true
        let state = snapshot(rows: rows, projects: [alpha, beta])
        let all = CodexT3SidebarInboxProjection(snapshot: state)
        #expect(all.allActive.count == 4)
        #expect(all.pinned.first?.project == nil)
        #expect(all.active.last?.project == nil)
        let scoped = CodexT3SidebarInboxProjection(snapshot: state, projectScopeID: "beta")
        #expect(scoped.allActive.map(\.id) == ["beta-chat"])
    }

    @Test func selectedDeepHistoryStaysVisibleWithPagingOrCollapsedShelf() {
        var state = snapshot(rows: [])
        state.archivedRows = (0..<40).map { index in
            var value = row("archive-\(index)", created: Double(index), updated: Double(index))
            value.isArchived = true
            return value
        }
        let items = CodexT3SidebarInboxProjection(snapshot: state).archived
        let page = CodexT3SidebarInboxProjection.archivedPage(items, visibleCount: 10, selectedID: "archive-2", expanded: true)
        #expect(page.count == 11)
        #expect(page.last?.id == "archive-2")
        let collapsed = CodexT3SidebarInboxProjection.archivedPage(items, visibleCount: 35, selectedID: "archive-2", expanded: false)
        #expect(collapsed.map(\.id) == ["archive-2"])
    }

    @Test func serverSearchResultsOnlyReplaceTheExactQueryAndScope() {
        let project = CodexProjectSummary(workspacePath: "/alpha", serverID: "alpha")
        var local = row("local", created: 1)
        local.summary.title = "Fix the local parser"
        local.summary.projectID = "alpha"
        let inbox = CodexT3SidebarInboxProjection(snapshot: snapshot(rows: [local], projects: [project]), projectScopeID: "alpha")
        let server = CodexThreadSearchResult(thread: .init(id: "remote", title: "Historical parser", projectID: "alpha"), snippet: "Matching older message")
        let stale = CodexSidebarInboxSearchState(query: "previous", results: [server])
        #expect(inbox.searchResults(stale, query: "parser", projectScopeID: "alpha").map(\.id) == ["local"])
        let matching = CodexSidebarInboxSearchState(query: "parser", results: [server, server,
            .init(thread: .init(id: "child", title: "Parser agent", projectID: "alpha", parentThreadID: "remote"), snippet: "child")])
        #expect(inbox.searchResults(matching, query: "parser", projectScopeID: "alpha").map(\.id) == ["remote"])
    }

    @Test func shiftSelectionUsesVisibleOrderAndNeverTogglesAlreadySelectedRowsOff() {
        let visible = ["pin", "new", "old", "archive"]
        #expect(CodexT3SidebarSelectionIntent.resolve(clickedID: "old", visibleIDs: visible, selectedIDs: ["new"], anchorID: "pin",
                                                     commandPressed: false, shiftPressed: true, selectionMode: false) == .addRange(["pin", "old"]))
        #expect(CodexT3SidebarSelectionIntent.resolve(clickedID: "new", visibleIDs: visible, selectedIDs: [], anchorID: nil,
                                                     commandPressed: true, shiftPressed: false, selectionMode: false) == .toggle("new"))
        #expect(CodexT3SidebarSelectionIntent.resolve(clickedID: "new", visibleIDs: visible, selectedIDs: [], anchorID: nil,
                                                     commandPressed: false, shiftPressed: false, selectionMode: false) == .navigate)
    }

    private func row(_ id: String, created: Double, updated: Double? = nil) -> CodexSidebarThreadRow {
        .init(summary: .init(id: id, title: id, createdAt: created, updatedAt: updated))
    }

    private func snapshot(rows: [CodexSidebarThreadRow], projects: [CodexProjectSummary] = []) -> CodexSidebarSnapshot {
        .init(selectedRoute: .chat, lastContentRoute: .chat, isCollapsed: false, isSearchOverlayPresented: false,
              selectedProjectPath: "/", selectedThreadID: nil, projects: [], inboxRows: rows, inboxProjects: projects, showsNoChats: rows.isEmpty)
    }
}
