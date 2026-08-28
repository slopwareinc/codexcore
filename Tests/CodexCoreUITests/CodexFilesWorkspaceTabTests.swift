import Foundation
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexFilesWorkspaceTabTests {
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
