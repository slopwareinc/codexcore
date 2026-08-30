import Combine
import Foundation
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexFilesWorkspaceTabTests {
    @Test func reconcilingTheInstalledFilesSessionDoesNotPublish() {
        let panel = CodexWorkspacePanelState()
        let session = CodexFilesSession(rootURL: URL(fileURLWithPath: "/tmp/project"))
        #expect(panel.reconcileFilesSession(session))

        var updateCount = 0
        let observation = panel.objectWillChange.sink { updateCount += 1 }

        #expect(!panel.reconcileFilesSession(session))
        #expect(updateCount == 0)
        withExtendedLifetime(observation) {}
    }

    @Test func fileReferenceIdentityNormalizesPathsAndSeparatesRefs() {
        let working = CodexWorkspaceFileReference(
            fileURL: URL(fileURLWithPath: "/tmp/project/Sources/../Sources/App.swift")
        )
        let main = CodexWorkspaceFileReference(
            fileURL: URL(fileURLWithPath: "/tmp/project/Sources/App.swift"),
            ref: "main"
        )

        #expect(working.fileURL.path == "/tmp/project/Sources/App.swift")
        #expect(working.ref == nil)
        #expect(working.id != main.id)
        #expect(main.id.contains("main"))
    }

    @Test func previewAdapterUsesTypedIdentityAndWorkspacePreviewRules() throws {
        let reference = CodexWorkspaceFileReference(
            fileURL: URL(fileURLWithPath: "/tmp/project/App.swift"),
            ref: "main"
        )
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            CodexFilePreviewWorkspaceTabAdapter(file: reference),
            from: .transcript
        )
        let contentID = try #require(tabs.snapshot.instance(id: id)?.contentID)

        #expect(tabs.snapshot.instance(id: id)?.resourceKey == "codex.file.preview:\(reference.id)")
        #expect(tabs.snapshot.instance(id: id)?.isPinned == false)
        #expect(tabs.snapshot.instance(id: id)?.durableRoute == nil)

        tabs.interact(id)

        #expect(tabs.snapshot.instance(id: id)?.isPinned == true)
        #expect(tabs.snapshot.instance(id: id)?.durableRoute?.resourceID == reference.id)
        #expect(tabs.snapshot.instance(id: id)?.contentID == contentID)
    }

    @Test func previewStateRoundTripsSearchAndGoToLine() throws {
        let state = CodexFilePreviewTabState(
            searchQuery: "needle",
            goToLine: 42,
            selectedMatch: 3
        )
        let restored = CodexFilePreviewTabState(tabState: state.tabState)

        #expect(restored == state)
        let route = CodexFilePreviewWorkspaceTabAdapter.route(
            for: CodexWorkspaceFileReference(
                fileURL: URL(fileURLWithPath: "/tmp/project/App.swift"),
                ref: "main"
            )
        )
        let adapter = try #require(CodexFilePreviewWorkspaceTabAdapter(route: route))
        #expect(adapter.file.ref == "main")
        #expect(adapter.file.fileURL.path == "/tmp/project/App.swift")
    }

    @Test func filesAdapterRegistersAStableDurableWorkspaceRoute() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let adapter = CodexFilesWorkspaceTabAdapter(workspaceURL: root)
        let registration = adapter.workspaceTabRegistration

        #expect(registration.resourceKey == "codex.files:/tmp/project")
        #expect(registration.durableRoute == CodexFilesWorkspaceTabAdapter.route(for: root))
        #expect(registration.lifetime == .pinned)
    }

    @Test func fileTabsRestoreRoutesLazilyAndKeepPreviewState() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let file = CodexWorkspaceFileReference(
            fileURL: root.appendingPathComponent("App.swift"),
            ref: "main"
        )
        let source = CodexWorkspaceTabs()
        let filesID = source.open(
            CodexFilesWorkspaceTabAdapter(workspaceURL: root),
            from: .commandMenu
        )
        let previewID = source.open(CodexFilePreviewWorkspaceTabAdapter(file: file), from: .transcript)
        source.interact(previewID)
        source.updateState(
            CodexFilePreviewTabState(searchQuery: "needle", goToLine: 8).tabState,
            for: previewID
        )

        let restored = CodexWorkspaceTabs(restoring: source.restorationState)
        restored.register([
            CodexFilesWorkspaceTabAdapter(workspaceURL: root),
            CodexFilePreviewWorkspaceTabAdapter(file: file),
        ])

        #expect(restored.snapshot.instance(id: filesID)?.isMaterialized == false)
        #expect(restored.snapshot.instance(id: previewID)?.isMaterialized == false)
        restored.activate(previewID)

        #expect(restored.snapshot.instance(id: previewID)?.isMaterialized == true)
        #expect(
            CodexFilePreviewTabState(
                tabState: try #require(restored.snapshot.instance(id: previewID)?.state)
            ).searchQuery == "needle"
        )
        #expect(restored.snapshot.topology.right.activeTabID == previewID)
    }

    @Test func unpinnedPreviewCanReconcileFromItsStableResourceKey() throws {
        let file = CodexWorkspaceFileReference(
            fileURL: URL(fileURLWithPath: "/tmp/project/App.swift"),
            ref: "working"
        )
        let source = CodexWorkspaceTabs()
        let id = source.open(CodexFilePreviewWorkspaceTabAdapter(file: file), from: .transcript)
        let key = try #require(source.snapshot.instance(id: id)?.resourceKey)
        let reconstructed = try #require(CodexFilePreviewWorkspaceTabAdapter(resourceKey: key))

        source.register([])
        #expect(!source.isAvailable(id))
        source.register([reconstructed])
        source.activate(id)

        #expect(source.isAvailable(id))
        #expect(source.snapshot.instance(id: id)?.isMaterialized == true)
        #expect(reconstructed.file == file)
    }

    @Test func previewRouteRejectsMismatchedTypedIdentity() {
        let route = CodexWorkspaceTabRoute(
            adapterID: CodexFilePreviewWorkspaceTabAdapter.adapterID,
            version: CodexFilePreviewWorkspaceTabAdapter.routeVersion,
            resourceID: "codex-file:|/tmp/project/Actual.swift",
            payload: Data("{}".utf8)
        )
        #expect(CodexFilePreviewWorkspaceTabAdapter(route: route) == nil)
    }

    @Test func closingFilesRunsTheAdapterCleanupAndReopeningConsumesUndo() throws {
        let panel = CodexWorkspacePanelState()
        let id = panel.openFiles(workspacePath: "/tmp/project")
        let contentID = try #require(panel.workspaceTabs.snapshot.instance(id: id)?.contentID)

        panel.workspaceTabs.close(id)

        #expect(panel.filesSession == nil)
        let reopened = panel.openFiles(workspacePath: "/tmp/project")
        #expect(reopened == id)
        #expect(panel.workspaceTabs.snapshot.instances.count == 1)
        #expect(panel.workspaceTabs.snapshot.instance(id: id)?.contentID == contentID)
        #expect(panel.workspaceTabs.undoClose() == nil)
    }

    @Test func restoredFileRoutesFailClosedOutsideTheWorkspaceOrForWrongKinds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-files-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("App.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let validFilesRoute = CodexFilesWorkspaceTabAdapter.route(for: root)
        let validPreviewRoute = CodexFilePreviewWorkspaceTabAdapter.route(
            for: CodexWorkspaceFileReference(fileURL: file)
        )

        #expect(
            CodexFilesWorkspaceTabAdapter(
                restoring: validFilesRoute,
                within: root
            ) != nil
        )
        #expect(
            CodexFilePreviewWorkspaceTabAdapter(
                restoring: validPreviewRoute,
                within: root
            ) != nil
        )

        let outsideRoute = CodexFilePreviewWorkspaceTabAdapter.route(
            for: CodexWorkspaceFileReference(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("outside.swift")
            )
        )
        #expect(
            CodexFilePreviewWorkspaceTabAdapter(
                restoring: outsideRoute,
                within: root
            ) == nil
        )
        #expect(
            CodexFilesWorkspaceTabAdapter(
                restoring: validFilesRoute,
                within: file
            ) == nil
        )
    }

    @Test func transcriptFileReferenceOpensPreviewAndPersistsLineLocation() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let file = root.appendingPathComponent("App.swift").standardizedFileURL
        let panel = CodexWorkspacePanelState()
        let service = CodexWorkspaceTranscriptFileNavigationService(
            workspaceURL: root,
            fileExists: { $0 == file },
            openFile: { resolved in
                let id = panel.openFilePreview(fileURL: resolved.fileURL)
                if let line = resolved.reference.line {
                    panel.workspaceTabs.updateState(
                        CodexFilePreviewTabState(goToLine: line).tabState,
                        for: id
                    )
                }
            },
            revealFile: { _ in }
        )
        let resolved = try #require(
            service.resolve(CodexTranscriptFileReference(path: "App.swift", line: 12))
        )

        service.open(resolved)
        let id = try #require(panel.workspaceTabs.snapshot.topology.right.activeTabID)
        #expect(
            CodexFilePreviewTabState(
                tabState: try #require(panel.workspaceTabs.snapshot.instance(id: id)?.state)
            ).goToLine == 12
        )
    }
}
