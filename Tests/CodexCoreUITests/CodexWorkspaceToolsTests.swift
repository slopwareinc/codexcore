import Foundation
import GhosttyTerminal
import CodexCore
import XCTest
@testable import CodexCoreUI

final class CodexWorkspaceToolsTests: XCTestCase {
    func testLauncherOffersOnlyAvailableWorkspaceTools() {
        let options = CodexWorkspaceToolCatalog.launcherOptions

        XCTAssertEqual(options.first?.id, CodexWorkspaceToolCatalog.terminalID)
        XCTAssertEqual(options.first?.title, "Terminal")
        XCTAssertEqual(options.first?.isEnabled, true)

        let browser = options.first { $0.id == CodexWorkspaceToolCatalog.browserID }
        XCTAssertEqual(browser?.title, "Browser")
        XCTAssertEqual(browser?.isEnabled, true)
        XCTAssertEqual(browser?.detail, "Browse docs and local previews")

        let files = options.first { $0.id == CodexWorkspaceToolCatalog.filesID }
        XCTAssertEqual(files?.title, "Files")
        XCTAssertEqual(files?.isEnabled, true)
        XCTAssertEqual(files?.detail, "Browse this workspace")

        XCTAssertEqual(
            options.map(\.id),
            [
                CodexWorkspaceToolCatalog.terminalID,
                CodexWorkspaceToolCatalog.browserID,
                CodexWorkspaceToolCatalog.filesID,
            ]
        )
        XCTAssertTrue(options.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testPanelStateOpensNumberedToolsAndSelectsLatest() {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")

        let firstTerminal = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let firstBrowser = panel.openBrowser()

        XCTAssertEqual(panel.terminalSessions.count, 1)
        XCTAssertEqual(panel.browserSessions.count, 1)
        XCTAssertEqual(panel.terminalSessions.first?.title, "swift test")
        XCTAssertEqual(panel.browserSessions.first?.title, "Browser")
        // The most-recently opened tool becomes selected.
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .legacy(firstBrowser))

        let secondTerminal = panel.openTerminal(workspacePath: "/tmp", command: "swift build")
        XCTAssertEqual(panel.terminalSessions.last?.title, "swift build")
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.bottom.activeTabID,
            panel.terminalTabID(for: secondTerminal)
        )
        XCTAssertNotEqual(firstTerminal, secondTerminal)
        XCTAssertTrue(panel.hasOpenTools)
    }

    @MainActor
    func testTerminalsUseWorkspaceTabsAndClosingTheTabReleasesTheSession() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let terminalID = panel.openTerminal(
            workspacePath: "/tmp/worktree",
            command: "/bin/zsh -lc 'swift test'"
        )
        let session = try XCTUnwrap(panel.terminalSessions.first)
        let tabID = try XCTUnwrap(panel.terminalTabID(for: terminalID))

        XCTAssertEqual(session.title, "swift test")
        XCTAssertEqual(session.identity.threadID, "thread-235")
        XCTAssertEqual(session.identity.worktreePath, "/tmp/worktree")
        XCTAssertEqual(panel.workspaceTabs.placement(of: tabID), .bottom)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.bottom.activeTabID, tabID)
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.instance(id: tabID)?.durableRoute?.resourceID,
            session.id
        )

        panel.workspaceTabs.close(tabID)

        XCTAssertTrue(panel.terminalSessions.isEmpty)
        XCTAssertNil(panel.workspaceTabs.snapshot.instance(id: tabID))
    }

    @MainActor
    func testBackgroundTerminalDoesNotStealFocusButIsRetainedInBottomPanel() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let foregroundID = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let foregroundTab = try XCTUnwrap(panel.terminalTabID(for: foregroundID))
        let backgroundID = panel.openBackgroundTerminal(
            workspacePath: "/tmp",
            command: "swift build"
        )
        let backgroundTab = try XCTUnwrap(panel.terminalTabID(for: backgroundID))

        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.bottom.activeTabID, foregroundTab)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.bottom.orderedTabIDs, [foregroundTab, backgroundTab])
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.focusedPlacement, .bottom)
        XCTAssertTrue(panel.terminalSessions.contains { $0.id == backgroundID })
    }

    @MainActor
    func testMovingAndHidingTerminalKeepsTheSamePTYHostAndSuspendsDisplay() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let terminalID = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let tabID = try XCTUnwrap(panel.terminalTabID(for: terminalID))
        let session = try XCTUnwrap(panel.terminalSessions.first)
        let hostIdentity = session.terminalHostIdentity

        panel.workspaceTabs.move(tabID, to: .right)
        panel.workspaceTabs.move(tabID, to: .bottom)
        session.setSurfaceVisible(false)
        session.setSurfaceVisible(false)

        XCTAssertEqual(session.terminalHostIdentity, hostIdentity)
        XCTAssertFalse(session.isSurfaceVisible)
        XCTAssertEqual(session.surfaceVisibilityChangeCount, 1)

        session.setSurfaceVisible(true)
        XCTAssertEqual(session.terminalHostIdentity, hostIdentity)
        XCTAssertEqual(session.surfaceVisibilityChangeCount, 2)
        session.restoreFocus()
        XCTAssertEqual(session.focusRestoreRequestCount, 1)
    }

    @MainActor
    func testWorkspaceTabVisibilityCallbackSuspendsHiddenTerminalDisplayWork() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let terminalID = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let tabID = try XCTUnwrap(panel.terminalTabID(for: terminalID))
        let session = try XCTUnwrap(panel.terminalSessions.first)

        panel.workspaceTabs.setVisibility(false, for: tabID)
        XCTAssertFalse(session.isSurfaceVisible)
        let changes = session.surfaceVisibilityChangeCount
        panel.workspaceTabs.setVisibility(false, for: tabID)
        XCTAssertEqual(session.surfaceVisibilityChangeCount, changes)

        panel.workspaceTabs.setVisibility(true, for: tabID)
        XCTAssertTrue(session.isSurfaceVisible)
        XCTAssertEqual(session.surfaceVisibilityChangeCount, changes + 1)
    }

    @MainActor
    func testUndoingTerminalCloseRestoresTheRetainedSessionAndTabIdentity() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let terminalID = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let tabID = try XCTUnwrap(panel.terminalTabID(for: terminalID))
        let session = try XCTUnwrap(panel.terminalSessions.first)
        let hostIdentity = session.terminalHostIdentity

        panel.workspaceTabs.close(tabID)
        XCTAssertTrue(panel.terminalSessions.isEmpty)

        let restoredTabID = try XCTUnwrap(panel.workspaceTabs.undoClose())
        XCTAssertEqual(restoredTabID, tabID)
        XCTAssertEqual(panel.terminalSessions.count, 1)
        XCTAssertEqual(panel.terminalSessions.first?.terminalHostIdentity, hostIdentity)
        XCTAssertEqual(panel.terminalTabID(for: terminalID), tabID)
    }

    @MainActor
    func testRestoredTerminalRouteReusesTheSameWorkspaceTabWhenTheHostIsRecreated() throws {
        let source = CodexWorkspacePanelState(threadID: "thread-235")
        let terminalID = source.openTerminal(workspacePath: "/tmp", command: "swift test")
        let originalTabID = try XCTUnwrap(source.terminalTabID(for: terminalID))
        let originalContentID = try XCTUnwrap(source.workspaceTabs.snapshot.instance(id: originalTabID)?.contentID)

        let restored = CodexWorkspacePanelState(
            threadID: "thread-235",
            restorationState: source.workspaceTabRestorationState
        )
        let reopenedTerminalID = restored.openTerminal(workspacePath: "/tmp", command: "swift test")
        let reopenedTabID = try XCTUnwrap(restored.terminalTabID(for: reopenedTerminalID))

        XCTAssertEqual(reopenedTabID, originalTabID)
        XCTAssertEqual(
            restored.workspaceTabs.snapshot.instance(id: reopenedTabID)?.contentID,
            originalContentID
        )
        XCTAssertEqual(restored.workspaceTabs.snapshot.topology.bottom.activeTabID, reopenedTabID)
    }

    @MainActor
    func testBackgroundOutputRemainsStrictlyBoundedAndKeepsNewestBytes() {
        var output = CodexBoundedTerminalOutput(maxBytes: 8)
        output.append("1234")
        output.append("567890")

        XCTAssertEqual(output.byteCount, 8)
        XCTAssertEqual(output.text, "34567890")
        XCTAssertEqual(output.droppedByteCount, 2)
    }

    @MainActor
    func testMountedToolSessionsDeduplicateEachCategoryInFirstSeenOrder() {
        let first = CodexWorkspacePanelState()
        first.terminalSessions = [
            CodexTerminalSession(id: "terminal-shared", workingDirectory: "/tmp"),
            CodexTerminalSession(id: "terminal-first", workingDirectory: "/tmp"),
        ]
        first.browserSessions = [CodexBrowserSession(id: "browser-shared")]
        first.filesSession = CodexFilesSession(id: "files-shared", rootURL: URL(fileURLWithPath: "/tmp"))
        first.filePreviewSessions = [
            CodexFilePreviewSession(fileURL: URL(fileURLWithPath: "/tmp/shared.swift")),
        ]

        let second = CodexWorkspacePanelState()
        second.terminalSessions = [
            CodexTerminalSession(id: "terminal-shared", workingDirectory: "/tmp/other"),
            CodexTerminalSession(id: "terminal-second", workingDirectory: "/tmp"),
        ]
        second.browserSessions = [
            CodexBrowserSession(id: "browser-shared"),
            CodexBrowserSession(id: "browser-second"),
        ]
        second.filesSession = CodexFilesSession(id: "files-shared", rootURL: URL(fileURLWithPath: "/tmp/other"))
        second.filePreviewSessions = [
            CodexFilePreviewSession(fileURL: URL(fileURLWithPath: "/tmp/shared.swift")),
            CodexFilePreviewSession(fileURL: URL(fileURLWithPath: "/tmp/second.swift")),
        ]

        let mounted = CodexMountedWorkspaceToolSessions(panels: [first, second])

        XCTAssertEqual(mounted.terminal.map(\.id), ["terminal-shared", "terminal-first", "terminal-second"])
        XCTAssertEqual(mounted.browser.map(\.id), ["browser-shared", "browser-second"])
        XCTAssertEqual(mounted.files.map(\.id), ["files-shared"])
        XCTAssertEqual(
            mounted.filePreview.map(\.id),
            [
                CodexFilePreviewSession.identity(fileURL: URL(fileURLWithPath: "/tmp/shared.swift"), ref: nil),
                CodexFilePreviewSession.identity(fileURL: URL(fileURLWithPath: "/tmp/second.swift"), ref: nil),
            ]
        )
    }

    @MainActor
    func testPanelStateOpensSingleFilesSessionAndReselectsExisting() {
        let panel = CodexWorkspacePanelState()
        let first = panel.openFiles(workspacePath: "/tmp/workspace")
        let second = panel.openFiles(workspacePath: "/tmp/other")

        XCTAssertEqual(first, second)
        XCTAssertEqual(panel.filesSession?.id, first)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .legacy(first))
        XCTAssertEqual(panel.filesSession?.rootURL.path, "/tmp/workspace")
        XCTAssertTrue(panel.hasOpenTools)
    }

    @MainActor
    func testPanelStateCloseFallsBackAcrossLegacyAndManagedTabs() {
        let panel = CodexWorkspacePanelState()
        let terminal = panel.openTerminal(workspacePath: "/tmp")
        let browser = panel.openBrowser()
        let files = panel.openFiles(workspacePath: "/tmp")
        let planID = panel.workspaceTabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )

        panel.workspaceTabs.activateLegacy(files)
        panel.closeFiles(id: files)
        XCTAssertNil(panel.filesSession)
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.activeTab,
            .workspace(planID)
        )

        panel.workspaceTabs.activateLegacy(browser)
        panel.closeBrowser(id: browser)
        XCTAssertTrue(panel.browserSessions.isEmpty)
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.activeTab,
            .workspace(planID)
        )

        panel.workspaceTabs.activateLegacy(terminal)
        panel.closeTerminal(id: terminal)
        XCTAssertTrue(panel.terminalSessions.isEmpty)
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.activeTab,
            .workspace(planID)
        )
        XCTAssertFalse(panel.hasOpenTools)
    }

    @MainActor
    func testDiscoveredSubagentsUseOneMasterListInsteadOfPerAgentTabs() {
        let agents = [
            CodexSubagentState(
                id: "agent-a",
                name: "Architecture",
                title: "Architecture",
                prompt: "",
                status: .running
            ),
            CodexSubagentState(
                id: "agent-b",
                name: "Tests",
                title: "Tests",
                prompt: "",
                status: .running
            ),
        ]

        let snapshot = CodexSubagentsWorkspaceProjection.snapshot(subagents: agents)
        XCTAssertEqual(snapshot.active.map(\.id), ["agent-a", "agent-b"])
        XCTAssertTrue(snapshot.done.isEmpty)
        XCTAssertEqual(snapshot.statusSummary, "2 active")
    }

    @MainActor
    func testPlanAndReviewUseDistinctWorkspaceTabs() {
        let panel = CodexWorkspacePanelState()
        let plan = CodexPlanSummary(
            steps: [TurnPlanStep(step: "Inspect", status: .completed)]
        )
        let review = CodexGitReviewSession(
            snapshot: CodexGitReviewSnapshot(branchName: "main")
        )

        let planID = panel.workspaceTabs.open(
            CodexPlanWorkspaceTabAdapter(plan: plan),
            from: .summary
        )
        let reviewID = panel.workspaceTabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp"),
                session: review
            ),
            from: .summary
        )

        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.orderedTabIDs,
            [planID, reviewID]
        )
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.instances.map(\.title),
            ["Plan", "Review"]
        )
        XCTAssertTrue(panel.agentTabs().isEmpty)
    }

    @MainActor
    func testPanelStateInjectsAppliesAndExportsDurableWorkspaceTabRestoration() throws {
        let source = CodexWorkspacePanelState()
        let planID = source.workspaceTabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )
        let reviewID = source.workspaceTabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp"),
                session: CodexGitReviewSession(
                    snapshot: CodexGitReviewSnapshot(branchName: "main")
                )
            ),
            from: .summary
        )
        source.workspaceTabs.updateState(
            CodexWorkspaceTabState(data: Data("selected.swift".utf8)),
            for: reviewID
        )
        source.workspaceTabs.move(reviewID, to: .bottom)

        let data = try JSONEncoder().encode(source.workspaceTabRestorationState)
        let persisted = try JSONDecoder().decode(
            CodexWorkspaceTabRestorationState.self,
            from: data
        )
        let injected = CodexWorkspacePanelState(
            panelWidth: 540,
            restorationState: persisted
        )
        let applied = CodexWorkspacePanelState()
        applied.applyWorkspaceTabRestoration(persisted)

        for panel in [injected, applied] {
            XCTAssertEqual(panel.workspaceTabRestorationState, persisted)
            XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.orderedTabIDs, [planID])
            XCTAssertEqual(panel.workspaceTabs.snapshot.topology.bottom.orderedTabIDs, [reviewID])
            XCTAssertTrue(panel.workspaceTabs.snapshot.instances.allSatisfy { !$0.isMaterialized })
            XCTAssertEqual(
                panel.workspaceTabs.snapshot.instance(id: reviewID)?.state.data,
                Data("selected.swift".utf8)
            )
        }
        XCTAssertEqual(injected.panelWidth, 540)
    }

    @MainActor
    func testPanelStatePurgeClearsSessionsAndClosesPanel() {
        let panel = CodexWorkspacePanelState()
        panel.openTerminal(workspacePath: "/tmp")
        panel.openBrowser()
        panel.openFiles(workspacePath: "/tmp")
        panel.isAgentPanelOpen = true

        panel.purge()

        XCTAssertTrue(panel.terminalSessions.isEmpty)
        XCTAssertTrue(panel.browserSessions.isEmpty)
        XCTAssertNil(panel.filesSession)
        XCTAssertNil(panel.workspaceTabs.snapshot.topology.right.activeTab)
        XCTAssertFalse(panel.isAgentPanelOpen)
    }

    @MainActor
    func testTerminalSessionUsesGhosttyExecBackendAndWorkspaceDirectory() {
        let workspace = FileManager.default.temporaryDirectory.path
        let session = CodexTerminalSession(workingDirectory: workspace, fontSize: 12)

        XCTAssertEqual(session.title, "Terminal")
        XCTAssertEqual(session.initialWorkingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.workingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.fontSize, 12)
        if case .exec = session.state.configuration.backend {
            XCTAssertTrue(true)
        } else {
            XCTFail("Terminal sessions should use Ghostty exec backend")
        }
    }

    func testTerminalPathFormatterCompactsHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(CodexTerminalPathFormatter.display(home), "~")
        XCTAssertEqual(CodexTerminalPathFormatter.display(home + "/Projects/CodexCore"), "~/Projects/CodexCore")
        XCTAssertEqual(CodexTerminalPathFormatter.display("/tmp/CodexCore"), "/tmp/CodexCore")
    }

    func testFileTreeLoaderSortsDirectoriesBeforeFilesByLocalizedName() throws {
        let workspace = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: workspace.appendingPathComponent("beta.txt").path, contents: Data())
        FileManager.default.createFile(atPath: workspace.appendingPathComponent("aardvark.txt").path, contents: Data())

        let children = CodexFileTreeLoader().children(of: workspace)

        XCTAssertEqual(children.map(\.name), ["Alpha", "zeta", "aardvark.txt", "beta.txt"])
        XCTAssertEqual(children.map(\.kind), [.directory, .directory, .file, .file])
    }

    func testFileTreeLoaderFiltersNoisyFoldersButKeepsOtherDotfiles() throws {
        let workspace = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".config"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: workspace.appendingPathComponent(".env").path, contents: Data())

        let children = CodexFileTreeLoader().children(of: workspace)

        XCTAssertEqual(children.map(\.name), [".config", ".env"])
    }

    func testFileTreeNodeLoadsChildrenLazilyOneLevelAtATime() throws {
        let workspace = try makeTemporaryWorkspace()
        let childDirectory = workspace.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: childDirectory.appendingPathComponent("grandchild"), withIntermediateDirectories: true)

        let root = CodexFileTreeLoader().rootNode(for: workspace)
        XCTAssertFalse(root.areChildrenLoaded)

        let children = root.loadChildren()

        XCTAssertTrue(root.areChildrenLoaded)
        XCTAssertEqual(children.map(\.name), ["child"])
        XCTAssertFalse(children[0].areChildrenLoaded)
    }

    func testFileTreeLoaderAsyncChildrenPreserveOrderingAndFiltering() async throws {
        let workspace = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: workspace.appendingPathComponent("aardvark.txt").path, contents: Data())

        let entries = await CodexFileTreeLoader.childrenAsync(of: workspace)

        XCTAssertEqual(entries.map(\.name), ["zeta", "aardvark.txt"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
    }

    func testFileTreeLoaderTreatsSymlinkDirectoryAsLeaf() throws {
        let workspace = try makeTemporaryWorkspace()
        let target = workspace.appendingPathComponent("target")
        let link = workspace.appendingPathComponent("linked-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let linkedNode = CodexFileTreeLoader().children(of: workspace).first { $0.name == "linked-target" }

        XCTAssertEqual(linkedNode?.kind, .symbolicLink)
        XCTAssertEqual(linkedNode?.isExpandable, false)
    }

    func testFilesPathFormatterCompactsHomeDirectoryAndUsesRootName() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(CodexFilesPathFormatter.display(home), "~")
        XCTAssertEqual(CodexFilesPathFormatter.display(home.appendingPathComponent("Projects/CodexCore")), "~/Projects/CodexCore")
        XCTAssertEqual(CodexFilesPathFormatter.display(URL(fileURLWithPath: "/tmp/CodexCore")), "/tmp/CodexCore")
        XCTAssertEqual(CodexFilesPathFormatter.rootName(for: URL(fileURLWithPath: "/tmp/CodexCore")), "CodexCore")
    }

    @MainActor
    func testFilesSessionRefreshReplacesRootNodeAndKeepsSelection() throws {
        let workspace = try makeTemporaryWorkspace()
        let selected = workspace.appendingPathComponent("Package.swift")
        let session = CodexFilesSession(rootURL: workspace)
        session.selectedURL = selected
        let originalRoot = session.rootNode

        session.refresh()

        XCTAssertFalse(session.rootNode === originalRoot)
        XCTAssertEqual(session.selectedURL, selected)
    }

    func testBrowserNavigationResolverKeepsFullURLs() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "https://example.com/docs?q=swift").absoluteString,
            "https://example.com/docs?q=swift"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "http://localhost:3000").absoluteString,
            "http://localhost:3000"
        )
    }

    func testBrowserNavigationResolverInfersBareDomains() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "example.com").absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "example.com/docs").absoluteString,
            "https://example.com/docs"
        )
    }

    func testBrowserNavigationResolverUsesHTTPForBareLocalhost() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "localhost:5173").absoluteString,
            "http://localhost:5173"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "127.0.0.1:8080").absoluteString,
            "http://127.0.0.1:8080"
        )
    }

    func testBrowserNavigationResolverSearchesOtherText() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "swift webkit docs").absoluteString,
            "https://duckduckgo.com/?q=swift%20webkit%20docs"
        )
    }

    @MainActor
    func testBrowserSessionInitialState() {
        let session = CodexBrowserSession()

        XCTAssertEqual(session.title, "Browser")
        XCTAssertEqual(session.addressText, "")
        XCTAssertNil(session.currentURL)
        XCTAssertFalse(session.isLoading)
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canGoForward)
    }

    @MainActor
    func testBrowserSessionNavigateNormalizesAddressText() {
        let session = CodexBrowserSession()
        session.addressText = "example.com"

        session.navigateToAddressText()

        XCTAssertEqual(session.addressText, "https://example.com")
        XCTAssertEqual(session.currentURL?.absoluteString, "https://example.com")
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWorkspaceToolsTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
