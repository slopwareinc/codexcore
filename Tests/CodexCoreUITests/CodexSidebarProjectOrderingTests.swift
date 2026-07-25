@testable import CodexCoreUI
import Foundation
import Testing

struct CodexSidebarProjectOrderingTests {
    @Test func projectDiscoveryOrderDoesNotFollowTheSelectedWorkspace() {
        let alpha = "/tmp/Alpha"
        let beta = "/tmp/Beta"
        let chats = [
            CodexThreadSummary(id: "alpha", title: "Alpha chat", workspacePath: alpha, recencyAt: 100),
            CodexThreadSummary(id: "beta", title: "Beta chat", workspacePath: beta, recencyAt: 200),
        ]

        let selectedAlpha = CodexProjectSummary.projects(from: chats, currentWorkspacePath: alpha)
        let selectedBeta = CodexProjectSummary.projects(from: chats, currentWorkspacePath: beta)

        #expect(selectedAlpha.map(\.workspacePath) == selectedBeta.map(\.workspacePath))
    }

    @Test func snapshotUsesExplicitProjectOrderAndSortsThreadsOnlyInsideTheirProject() {
        let alpha = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: Date().timeIntervalSince1970)
        let beta = CodexProjectSummary(workspacePath: "/tmp/Beta", updatedAt: Date().timeIntervalSince1970)
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: alpha.workspacePath,
            expandedProjectIDs: [alpha.workspacePath, beta.workspacePath],
            projectOrder: [beta.workspacePath, alpha.workspacePath]
        )
        session.selectChat("alpha-old", workspacePath: alpha.workspacePath)
        let chats = [
            CodexThreadSummary(id: "alpha-old", title: "Old", workspacePath: alpha.workspacePath, recencyAt: 100),
            CodexThreadSummary(id: "beta-new", title: "Beta", workspacePath: beta.workspacePath, recencyAt: 400),
            CodexThreadSummary(id: "alpha-new", title: "New", workspacePath: alpha.workspacePath, recencyAt: 300),
        ]

        let snapshot = session.snapshot(
            projects: [alpha, beta],
            chats: chats,
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: "alpha-old"
        )

        #expect(snapshot.projects.map(\.project.workspacePath) == [beta.workspacePath, alpha.workspacePath])
        #expect(snapshot.projects[0].rows.map(\.id) == ["beta-new"])
        #expect(snapshot.projects[1].rows.map(\.id) == ["alpha-new", "alpha-old"])
    }

    @Test func movingAProjectUpdatesOnlyTheExplicitProjectOrder() {
        let projects = ["Alpha", "Beta", "Gamma"].map {
            CodexProjectSummary(workspacePath: "/tmp/\($0)")
        }
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp/Alpha"
        )

        #expect(session.projectOrder.isEmpty)
        let movedBefore = session.moveProject(
            "/tmp/Gamma",
            relativeTo: "/tmp/Alpha",
            placement: .before,
            among: projects
        )
        #expect(movedBefore)
        #expect(session.projectOrder == ["/tmp/Gamma", "/tmp/Alpha", "/tmp/Beta"])
        let movedAfter = session.moveProject(
            "/tmp/Gamma",
            relativeTo: "/tmp/Beta",
            placement: .after,
            among: projects
        )
        #expect(movedAfter)
        #expect(session.projectOrder == ["/tmp/Alpha", "/tmp/Beta", "/tmp/Gamma"])
    }

    @Test func pinnedProjectsMoveToThePinnedSectionWithoutChangingThreadGrouping() {
        let now = Date().timeIntervalSince1970
        let alpha = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: now)
        let beta = CodexProjectSummary(workspacePath: "/tmp/Beta", updatedAt: now)
        var session = CodexSidebarNavigationSession(currentWorkspacePath: alpha.workspacePath)

        let isPinned = session.toggleProjectPin(beta.workspacePath)
        let snapshot = session.snapshot(
            projects: [beta, alpha],
            chats: [CodexThreadSummary(id: "beta", title: "Beta", workspacePath: beta.workspacePath)],
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: nil
        )

        #expect(isPinned)
        #expect(snapshot.pinnedProjects.map(\.project.workspacePath) == [beta.workspacePath])
        #expect(snapshot.projects.map(\.project.workspacePath) == [alpha.workspacePath])
        #expect(snapshot.pinnedProjects[0].rows.map(\.id) == ["beta"])
    }

    @Test func pinnedProjectsPreserveTheirPersistedPinOrder() {
        let now = Date().timeIntervalSince1970
        let alpha = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: now)
        let beta = CodexProjectSummary(workspacePath: "/tmp/Beta", updatedAt: now)
        let gamma = CodexProjectSummary(workspacePath: "/tmp/Gamma", updatedAt: now)
        let session = CodexSidebarNavigationSession(
            currentWorkspacePath: alpha.workspacePath,
            projectOrder: [alpha.workspacePath, beta.workspacePath, gamma.workspacePath],
            pinnedProjectIDs: [gamma.workspacePath, alpha.workspacePath]
        )

        let snapshot = session.snapshot(
            projects: [alpha, beta, gamma],
            chats: [],
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: nil
        )

        #expect(snapshot.pinnedProjects.map(\.project.workspacePath) == [gamma.workspacePath, alpha.workspacePath])
        #expect(snapshot.projects.map(\.project.workspacePath) == [beta.workspacePath])
    }

    @Test func projectOrderStorageNormalizesAndPersistsOrder() {
        let store = ProjectOrderPreferenceStore()
        CodexProjectOrderStorage.saveProjectOrder(
            ["/tmp/Beta", "/tmp/Alpha", "/tmp/Beta", " "],
            to: store
        )

        #expect(CodexProjectOrderStorage.loadProjectOrder(from: store) == ["/tmp/Beta", "/tmp/Alpha"])

        CodexPinnedProjectStorage.savePinnedProjectIDs(["/tmp/Alpha", "/tmp/Alpha"], to: store)
        #expect(CodexPinnedProjectStorage.loadPinnedProjectIDs(from: store) == ["/tmp/Alpha"])
    }

    @Test func projectlessChatsStayOutsideProjectGroupsAndPersistIdentity() {
        let store = ProjectOrderPreferenceStore()
        CodexProjectlessThreadStorage.save(["chat-global"], to: store)
        let project = CodexProjectSummary(
            workspacePath: "/tmp/Alpha",
            updatedAt: Date().timeIntervalSince1970
        )
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: project.workspacePath,
            expandedProjectIDs: [project.workspacePath]
        )
        session.selectProjectlessChat("chat-global")
        let chats = [
            CodexThreadSummary(
                id: "chat-global",
                title: "Global",
                workspacePath: "/tmp/generated/work",
                recencyAt: 200
            ),
            CodexThreadSummary(
                id: "chat-project",
                title: "Project",
                workspacePath: project.workspacePath,
                recencyAt: 100
            ),
        ]

        let snapshot = session.snapshot(
            projects: [project],
            chats: chats,
            currentWorkspacePath: project.workspacePath,
            currentThreadID: "chat-global",
            projectlessThreadIDs: CodexProjectlessThreadStorage.load(from: store)
        )

        #expect(snapshot.isProjectlessSelected)
        #expect(snapshot.projectlessRows.map(\.id) == ["chat-global"])
        #expect(snapshot.projects.flatMap(\.rows).map(\.id) == ["chat-project"])
    }

    @Test func projectAliasesAndHiddenProjectsChangePresentationWithoutChangingIdentity() {
        let now = Date().timeIntervalSince1970
        let alpha = CodexProjectSummary(workspacePath: "/tmp/Alpha", updatedAt: now)
        let beta = CodexProjectSummary(workspacePath: "/tmp/Beta", updatedAt: now)
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: alpha.workspacePath,
            hiddenProjectIDs: [beta.workspacePath],
            projectAliases: [alpha.workspacePath: "Primary workspace"]
        )

        var snapshot = session.snapshot(
            projects: [beta, alpha],
            chats: [],
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: nil
        )
        #expect(snapshot.projects.map(\.project.workspacePath) == [alpha.workspacePath])
        #expect(snapshot.projects[0].project.displayName == "Primary workspace")

        let didRestore = session.restoreProject(beta.workspacePath)
        #expect(didRestore)
        snapshot = session.snapshot(
            projects: [beta, alpha],
            chats: [],
            currentWorkspacePath: alpha.workspacePath,
            currentThreadID: nil
        )
        #expect(snapshot.projects.map(\.project.workspacePath) == [beta.workspacePath, alpha.workspacePath])
    }

    @Test func projectAliasAndVisibilityStorageRoundTrip() {
        let store = ProjectOrderPreferenceStore()
        CodexHiddenProjectStorage.saveHiddenProjectIDs(["/tmp/Beta", " /tmp/Beta "], to: store)
        CodexProjectAliasStorage.saveProjectAliases(
            ["/tmp/Alpha": " Primary workspace ", " ": "Ignored"],
            to: store
        )

        #expect(CodexHiddenProjectStorage.loadHiddenProjectIDs(from: store) == ["/tmp/Beta"])
        #expect(CodexProjectAliasStorage.loadProjectAliases(from: store) == ["/tmp/Alpha": "Primary workspace"])
    }

    @Test func sourceFolderStoragePreservesPrimaryOrderAndMigratesPrimary() {
        let store = ProjectOrderPreferenceStore()
        CodexProjectSourceFoldersStorage.save(
            ["/tmp/Alpha": ["/tmp/Alpha", "/tmp/Beta", "/tmp/Alpha"]],
            to: store
        )
        #expect(CodexProjectSourceFoldersStorage.load(from: store) == [
            "/tmp/Alpha": ["/tmp/Alpha", "/tmp/Beta"]
        ])

        let migrated = CodexProjectSourceFoldersStorage.updating(
            CodexProjectSourceFoldersStorage.load(from: store),
            oldPrimary: "/tmp/Alpha",
            sourceFolders: ["/tmp/Beta", "/tmp/Alpha"]
        )
        #expect(migrated == [
            "/tmp/Beta": ["/tmp/Beta", "/tmp/Alpha"]
        ])
    }

    @Test func multiFolderProjectGroupsChatsFromEverySourceFolder() {
        let now = Date().timeIntervalSince1970
        let project = CodexProjectSummary(
            workspacePath: "/tmp/Frontend",
            sourceFolders: ["/tmp/Frontend", "/tmp/Backend"],
            updatedAt: now
        )
        let session = CodexSidebarNavigationSession(
            currentWorkspacePath: project.workspacePath,
            expandedProjectIDs: [project.workspacePath]
        )
        let snapshot = session.snapshot(
            projects: [project],
            chats: [
                .init(id: "front", title: "Frontend", workspacePath: "/tmp/Frontend"),
                .init(id: "back", title: "Backend", workspacePath: "/tmp/Backend"),
            ],
            currentWorkspacePath: project.workspacePath,
            currentThreadID: nil
        )

        #expect(snapshot.projects.count == 1)
        #expect(Set(snapshot.projects[0].rows.map(\.id)) == ["front", "back"])
        #expect(project.contains(workspacePath: "/tmp/Backend"))
    }

    @Test func changingPrimaryMigratesSidebarProjectMetadata() {
        var session = CodexSidebarNavigationSession(
            currentWorkspacePath: "/tmp/Alpha",
            expandedProjectIDs: ["/tmp/Alpha"],
            projectOrder: ["/tmp/Alpha"],
            pinnedProjectIDs: ["/tmp/Alpha"],
            hiddenProjectIDs: ["/tmp/Alpha"],
            projectAliases: ["/tmp/Alpha": "Workspace"]
        )
        session.replaceProjectPath("/tmp/Alpha", with: "/tmp/Beta")

        #expect(session.selectedProjectPath == "/tmp/Beta")
        #expect(session.expandedProjectIDs == ["/tmp/Beta"])
        #expect(session.projectOrder == ["/tmp/Beta"])
        #expect(session.pinnedProjectIDs == ["/tmp/Beta"])
        #expect(session.hiddenProjectIDs == ["/tmp/Beta"])
        #expect(session.projectAliases == ["/tmp/Beta": "Workspace"])
    }

    @Test func bulkArchiveClearsOnlyTheUnchangedArchivedSelection() {
        #expect(CodexSidebarArchiveSelectionGuard.shouldClearSelection(
            selectedThreadIDAtStart: "old",
            currentSelectedThreadID: "old",
            selectionGenerationAtStart: 4,
            currentSelectionGeneration: 4,
            archivedThreadIDs: ["old"]
        ))
        #expect(!CodexSidebarArchiveSelectionGuard.shouldClearSelection(
            selectedThreadIDAtStart: "old",
            currentSelectedThreadID: "new",
            selectionGenerationAtStart: 4,
            currentSelectionGeneration: 5,
            archivedThreadIDs: ["old"]
        ))
        #expect(!CodexSidebarArchiveSelectionGuard.shouldClearSelection(
            selectedThreadIDAtStart: "old",
            currentSelectedThreadID: "old",
            selectionGenerationAtStart: 4,
            currentSelectionGeneration: 4,
            archivedThreadIDs: ["different"]
        ))
    }
}

private final class ProjectOrderPreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? [] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock { values[key] = strings }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
