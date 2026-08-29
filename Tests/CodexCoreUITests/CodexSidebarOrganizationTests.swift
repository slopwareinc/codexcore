@testable import CodexCoreUI
import CodexCore
import Foundation
import Testing

struct CodexSidebarOrganizationTests {
    @Test func projectionKeepsServerFactsAndPresentationPreferencesSeparate() {
        let alpha = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: 100)
        let beta = CodexProjectSummary(workspacePath: "/tmp/Beta", updatedAt: 200)
        let section = CodexSidebarSectionSummary(
            id: "in-progress",
            name: "In progress",
            icon: "bolt",
            color: "purple",
            position: 0
        )
        let selected = CodexThreadSummary(
            id: "selected",
            title: "Selected",
            workspacePath: alpha.workspacePath,
            recencyAt: 10,
            sectionID: section.id,
            sectionName: section.name
        )
        let ordinary = CodexThreadSummary(
            id: "ordinary",
            title: "Ordinary",
            workspacePath: beta.workspacePath,
            recencyAt: 20
        )
        let input = CodexSidebarProjectionInput(
            projects: [alpha, beta],
            chats: [selected, ordinary],
            sections: [section],
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: selected.id,
            pinnedThreadIDs: [ordinary.id],
            projectlessThreadIDs: [],
            expandedProjectIDs: [alpha.workspacePath],
            projectOrder: [beta.workspacePath, alpha.workspacePath],
            now: 300
        )

        let snapshot = CodexSidebarProjection.snapshot(input)

        #expect(snapshot.pinnedRows.map(\.id) == [ordinary.id])
        #expect(snapshot.sections.map(\.id) == [section.id])
        #expect(snapshot.sections[0].rows.map(\.id) == [selected.id])
        #expect(snapshot.projects.map(\.id) == [beta.id, alpha.id])
        #expect(snapshot.projects[0].rows.isEmpty)
        #expect(snapshot.projects[1].rows.isEmpty)
        #expect(snapshot.sections[0].rows[0].isSelected)
        #expect(snapshot.sections[0].rows[0].summary.sectionID == section.id)
    }

    @Test func projectionSortsTiesByStableIdentityAndDoesNotRebuildUnrelatedSections() {
        let project = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: 100)
        let first = CodexThreadSummary(id: "a", title: "Same", workspacePath: project.workspacePath, recencyAt: 10)
        let second = CodexThreadSummary(id: "b", title: "Same", workspacePath: project.workspacePath, recencyAt: 10)
        let base = CodexSidebarProjection.snapshot(.init(
            projects: [project],
            chats: [second, first],
            currentWorkspacePath: project.workspacePath,
            now: 100
        ))
        let changed = CodexSidebarProjection.snapshot(.init(
            projects: [project],
            chats: [second, first],
            currentWorkspacePath: project.workspacePath,
            threadStatusEntries: ["a": .init(status: .running)],
            now: 100
        ))

        #expect(base.projects[0].rows.map(\.id) == ["a", "b"])
        let diff = CodexSidebarProjection.diff(base, changed)
        #expect(diff.changedRowIDs == ["a"])
        #expect(diff.changedSectionIDs == [project.id])
        #expect(diff.rebuiltSectionIDs == [project.id])

        let sectionBefore = CodexSidebarProjection.snapshot(.init(
            chats: [CodexThreadSummary(id: "section-task", title: "Task", sectionID: "s")],
            sections: [.init(id: "s", name: "One")],
            currentWorkspacePath: "/tmp",
            now: 100
        ))
        let sectionAfter = CodexSidebarProjection.snapshot(.init(
            chats: [CodexThreadSummary(id: "section-task", title: "Task", sectionID: "s")],
            sections: [.init(id: "s", name: "Renamed")],
            currentWorkspacePath: "/tmp",
            now: 100
        ))
        #expect(CodexSidebarProjection.diff(sectionBefore, sectionAfter).changedSectionIDs == ["s"])
    }

    @Test func archivedPagesAppendByCursorWithoutDuplicateRows() {
        let archived = CodexThreadSummary(id: "archived", title: "Old task", recencyAt: 1)
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp")
        let didBegin = session.beginArchivedLoad(reset: true)
        #expect(didBegin)
        let didApply = session.applyArchivedPage(
            CodexSchemaThreadListResponse(data: [Self.schemaThread(archived)], nextCursor: "page-2"),
            reset: true
        )
        #expect(didApply)
        #expect(session.archivedChats.map(\.id) == [archived.id])
        #expect(session.archivedNextCursor == "page-2")

        let didBeginNext = session.beginArchivedLoad(reset: false)
        #expect(didBeginNext)
        let didApplyNext = session.applyArchivedPage(
            CodexSchemaThreadListResponse(
                data: [Self.schemaThread(archived), Self.schemaThread(.init(id: "new", title: "New old task", recencyAt: 2))],
                nextCursor: nil
            )
        )
        #expect(didApplyNext)
        #expect(session.archivedChats.map(\.id) == ["new", "archived"])
        #expect(session.archivedNextCursor == nil)

        _ = session.beginArchivedLoad(reset: true)
        let didApplyRepeat = session.applyArchivedPage(
            CodexSchemaThreadListResponse(data: [Self.schemaThread(archived)], nextCursor: "repeat"),
            reset: true
        )
        #expect(didApplyRepeat)
        _ = session.beginArchivedLoad(reset: false)
        let didRejectRepeat = session.applyArchivedPage(
            CodexSchemaThreadListResponse(data: [], nextCursor: "repeat")
        )
        #expect(!didRejectRepeat)
        #expect(session.archivedErrorMessage?.contains("repeated cursor") == true)
    }

    @Test func navigationSelectionModeIsPresentationOnlyAndSectionCollapseIsStable() {
        var navigation = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp",
            expandedSectionIDs: ["one", "two"]
        )
        navigation.toggleThreadSelection("task-1")
        navigation.toggleThreadSelection("task-2")
        #expect(navigation.selectedThreadIDs == ["task-1", "task-2"])
        #expect(navigation.isBulkSelectionMode)
        navigation.clearThreadSelection()
        #expect(navigation.selectedThreadIDs.isEmpty)
        #expect(!navigation.isBulkSelectionMode)

        navigation.toggleSection("one")
        #expect(navigation.collapsedSectionIDs == ["one"])
        let snapshot = navigation.snapshot(
            projects: [],
            chats: [
                .init(id: "task-1", title: "One", sectionID: "one"),
                .init(id: "task-2", title: "Two", sectionID: "two"),
            ],
            currentWorkspacePath: "/tmp",
            currentThreadID: nil,
            sections: [
                .init(id: "one", name: "One"),
                .init(id: "two", name: "Two"),
            ],
            now: 0
        )
        #expect(snapshot.sections.first(where: { $0.id == "one" })?.isExpanded == false)
        #expect(snapshot.sections.first(where: { $0.id == "two" })?.isExpanded == true)
    }

    @Test func localProjectMutationCanRollBackWithoutTouchingServerFacts() {
        let original = ["alpha", "beta", "gamma"]
        let moved = CodexSidebarMutation.reordered(
            sourceID: "gamma",
            targetID: "alpha",
            placement: .before,
            in: original
        )
        #expect(moved == ["gamma", "alpha", "beta"])
        #expect(CodexSidebarMutation.reordered(
            sourceID: "missing",
            targetID: "alpha",
            placement: .before,
            in: original
        ) == nil)
        #expect(CodexSidebarMutation.toggledPin(id: "delta", in: original).ids == ["delta", "alpha", "beta", "gamma"])
        #expect(CodexSidebarMutation.toggledPin(id: "delta", in: original).isPinned)
    }

    @Test func localSearchUsesOneDeterministicSortPath() {
        let summaries = [
            CodexThreadSummary(id: "z", title: "Build beta", preview: "Compile", recencyAt: 10),
            CodexThreadSummary(id: "a", title: "Build alpha", preview: "Compile", recencyAt: 10),
            CodexThreadSummary(id: "other", title: "Unrelated", recencyAt: 100),
        ]
        #expect(CodexSidebarProjection.search(summaries, query: "compile", sortKey: .title).map(\.id) == ["a", "z"])
        #expect(CodexSidebarProjection.search(summaries, query: "", limit: 10).isEmpty)
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp")
        session.applyThreadList(
            currentRaw: .dictionary(["data": .array([])]),
            allRaw: .dictionary(["data": .array([
                .dictionary(["id": .string("a"), "name": .string("Build alpha")])
            ])]),
            currentWorkspacePath: "/tmp"
        )
        #expect(session.applyLocalSearch(query: "build") == 1)
        #expect(session.searchResults.map(\.id) == ["a"])

        let titleSorted = CodexSidebarProjection.snapshot(.init(
            projects: [CodexProjectSummary(workspacePath: "/tmp", updatedAt: 100)],
            chats: [
                .init(id: "z", title: "Zulu", workspacePath: "/tmp", recencyAt: 100),
                .init(id: "a", title: "Alpha", workspacePath: "/tmp", recencyAt: 1),
            ],
            currentWorkspacePath: "/tmp",
            now: 100,
            sortKey: .title
        ))
        #expect(titleSorted.projects.first?.rows.map(\.id) == ["a", "z"])
    }

    @Test func loadStatesProduceResilientEmptyAndErrorSnapshots() {
        let loading = CodexSidebarProjection.snapshot(.init(
            currentWorkspacePath: "/tmp",
            activeLoadState: .loading
        ))
        #expect(loading.activeLoadState.isLoading)
        #expect(!loading.showsNoChats)

        let failed = CodexSidebarProjection.snapshot(.init(
            currentWorkspacePath: "/tmp",
            activeLoadState: .failed("offline")
        ))
        #expect(failed.showsNoChats)
        #expect(failed.noChatsTitle == "offline")

        let pending = CodexSidebarProjection.snapshot(.init(
            chats: [.init(id: "task", title: "Task")],
            currentWorkspacePath: "/tmp",
            pendingThreadIDs: ["task"]
        ))
        #expect(pending.projectlessRows.isEmpty)
        #expect(pending.olderProjects.flatMap(\.rows).first?.isPendingMutation == true)
    }

    @Test func projectListFactsArePreferredOverCwdInference() {
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp")
        session.applyProjectList(CodexSchemaProjectListResponse(data: [
            CodexSchemaProject(
                createdAt: 1,
                id: "project-1",
                metadata: [:],
                name: "Authoritative",
                position: 0,
                roots: [CodexSchemaProjectRoot(path: .init(.string("/tmp/real")))],
                updatedAt: 2
            )
        ]))
        session.applyThreadList(
            currentRaw: .dictionary(["data": .array([])]),
            allRaw: .dictionary(["data": .array([
                .dictionary(["id": .string("thread"), "cwd": .string("/tmp/inferred"), "name": .string("Thread")])
            ])]),
            currentWorkspacePath: "/tmp"
        )
        session.refreshProjects(currentWorkspacePath: "/tmp")
        #expect(session.recentProjects.map(\.displayName) == ["Authoritative"])
        #expect(session.serverProjects.first?.workspacePath == "/tmp/real")
        #expect(session.serverProjects.first?.serverID == "project-1")
        #expect(session.serverProjects.first?.serverPosition == 0)
    }

    private static func schemaThread(_ summary: CodexThreadSummary) -> CodexSchemaThread {
        CodexSchemaThread(
            cliVersion: "test",
            createdAt: Int(summary.createdAt ?? summary.recencyAt ?? 0),
            cwd: .init(.string(summary.workspacePath ?? "/tmp")),
            ephemeral: false,
            id: summary.id,
            modelProvider: "openai",
            name: summary.title,
            preview: summary.preview,
            recencyAt: summary.recencyAt.map(Int.init),
            sessionID: "session-\(summary.id)",
            source: .init(.string("cli")),
            status: .unrecognized(type: "idle", rawValue: .dictionary(["type": .string("idle")])),
            turns: [],
            updatedAt: Int(summary.updatedAt ?? summary.recencyAt ?? 0)
        )
    }
}
