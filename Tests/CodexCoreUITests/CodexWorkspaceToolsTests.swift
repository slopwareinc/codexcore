import AppKit
import Foundation
import GhosttyTerminal
import CodexCore
import SwiftUI
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
        let panel = CodexWorkspacePanelState()

        let firstTerminal = panel.openTerminal(workspacePath: "/tmp")
        let firstBrowser = panel.openBrowser()

        XCTAssertEqual(panel.terminalSessions.count, 1)
        XCTAssertEqual(panel.browserSessions.count, 1)
        XCTAssertEqual(panel.terminalSessions.first?.title, "Terminal")
        XCTAssertEqual(panel.browserSessions.first?.title, "Browser")
        // The most-recently opened tool becomes selected.
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.activeTab,
            .legacy(firstBrowser)
        )

        let secondTerminal = panel.openTerminal(workspacePath: "/tmp")
        XCTAssertEqual(panel.terminalSessions.last?.title, "Terminal 2")
        XCTAssertEqual(
            panel.workspaceTabs.snapshot.topology.right.activeTab,
            .legacy(secondTerminal)
        )
        XCTAssertNotEqual(firstTerminal, secondTerminal)
        XCTAssertTrue(panel.hasOpenTools)
    }

    @MainActor
    func testMountedProcessSessionsDeduplicateEachCategoryInFirstSeenOrder() {
        let first = CodexWorkspacePanelState()
        first.terminalSessions = [
            CodexTerminalSession(id: "terminal-shared", workingDirectory: "/tmp"),
            CodexTerminalSession(id: "terminal-first", workingDirectory: "/tmp"),
        ]
        first.browserSessions = [CodexBrowserSession(id: "browser-shared")]

        let second = CodexWorkspacePanelState()
        second.terminalSessions = [
            CodexTerminalSession(id: "terminal-shared", workingDirectory: "/tmp/other"),
            CodexTerminalSession(id: "terminal-second", workingDirectory: "/tmp"),
        ]
        second.browserSessions = [
            CodexBrowserSession(id: "browser-shared"),
            CodexBrowserSession(id: "browser-second"),
        ]

        let mounted = CodexMountedWorkspaceToolSessions(panels: [first, second])

        XCTAssertEqual(mounted.terminal.map(\.id), ["terminal-shared", "terminal-first", "terminal-second"])
        XCTAssertEqual(mounted.browser.map(\.id), ["browser-shared", "browser-second"])
    }

    @MainActor
    func testPanelStateOpensSingleFilesSessionAndReselectsExisting() {
        let panel = CodexWorkspacePanelState()
        let first = panel.openFiles(workspacePath: "/tmp/workspace")
        let second = panel.openFiles(workspacePath: "/tmp/other")

        XCTAssertEqual(first, second)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .workspace(first))
        XCTAssertEqual(panel.workspaceTabs.snapshot.instance(id: first)?.title, "Files")
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

        panel.workspaceTabs.activate(files)
        panel.workspaceTabs.close(files)
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
        panel.workspaceTabs.close(planID)
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

    func testFileTreeLoaderBoundsDirectoryEntries() async throws {
        let workspace = try makeTemporaryWorkspace()
        for index in 0..<(CodexFileTreeLoader.maximumEntriesPerDirectory + 25) {
            FileManager.default.createFile(
                atPath: workspace.appendingPathComponent("File-\(index).txt").path,
                contents: Data()
            )
        }

        let entries = await CodexFileTreeLoader.childrenAsync(of: workspace)

        XCTAssertEqual(entries.count, CodexFileTreeLoader.maximumEntriesPerDirectory)
    }

    func testFileTreeLoaderCancellationStopsSupersededEnumeration() async throws {
        let workspace = try makeTemporaryWorkspace()
        for index in 0..<64 {
            FileManager.default.createFile(
                atPath: workspace.appendingPathComponent("File-\(index).txt").path,
                contents: Data()
            )
        }

        let entries = await CodexFileTreeLoader.childrenAsync(of: workspace) {
            throw CancellationError()
        }

        XCTAssertTrue(entries.isEmpty, "a superseded outline load must not publish partial children")
    }

    @MainActor
    func testMountedFilesDismantleCancelsPendingEnumerationAndDropsStaleChildren() async throws {
        let workspace = try makeTemporaryWorkspace()
        let staleURL = workspace.appendingPathComponent("stale.swift")
        let probe = FileTreeLoadProbe()
        let session = CodexFilesSession(rootURL: workspace, childrenLoader: { url in
            await probe.started(url)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                await probe.cancelled(url)
                return [CodexFileTreeEntry(url: staleURL, name: "stale.swift", kind: .file)]
            }
            await probe.finished(url)
            return []
        })
        let model = FilesDismantleHarnessModel()
        let hosting = NSHostingView(rootView: FilesDismantleHarness(model: model, session: session))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        pumpMainRunLoop()
        let outline = try XCTUnwrap(firstFileOutline(in: hosting))
        _ = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: nil)
        pumpMainRunLoop()

        let started = await probe.waitForStart(workspace)
        XCTAssertTrue(started)

        model.isVisible = false
        hosting.layoutSubtreeIfNeeded()
        pumpMainRunLoop()

        let cancelled = await probe.waitForCancellation(workspace)
        XCTAssertTrue(cancelled)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(session.rootNode.areChildrenLoaded, "cancelled enumeration must not publish stale children")
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

    @MainActor
    private func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    @MainActor
    private func firstFileOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let outline = firstFileOutline(in: child) { return outline }
        }
        return nil
    }
}

@MainActor
private final class FilesDismantleHarnessModel: ObservableObject {
    @Published var isVisible = true
}

private struct FilesDismantleHarness: View {
    @ObservedObject var model: FilesDismantleHarnessModel
    let session: CodexFilesSession

    var body: some View {
        Group {
            if model.isVisible {
                CodexFilesToolView(session: session)
            } else {
                Color.clear
            }
        }
    }
}

private actor FileTreeLoadProbe {
    private var startedPaths: Set<String> = []
    private var cancelledPaths: Set<String> = []
    private var finishedPaths: Set<String> = []

    func started(_ url: URL) { startedPaths.insert(url.path) }
    func cancelled(_ url: URL) { cancelledPaths.insert(url.path) }
    func finished(_ url: URL) { finishedPaths.insert(url.path) }

    func waitForStart(_ url: URL) async -> Bool {
        await wait { startedPaths.contains(url.path) }
    }

    func waitForCancellation(_ url: URL) async -> Bool {
        await wait { cancelledPaths.contains(url.path) }
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
