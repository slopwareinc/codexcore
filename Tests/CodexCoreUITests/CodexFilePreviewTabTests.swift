import XCTest

@testable import CodexCoreUI

@MainActor
final class CodexFilePreviewTabTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testFileReferenceIdentityCombinesFileAndRef() {
        let working = CodexWorkspaceFileReference(fileURL: url("a.swift"))
        let atRef = CodexWorkspaceFileReference(fileURL: url("a.swift"), ref: "main")
        XCTAssertNotEqual(working.id, atRef.id, "same file at different refs must be distinct tabs")
        XCTAssertEqual(working.displayName, "a.swift")
        XCTAssertEqual(atRef.displayName, "a.swift@main")
    }

    func testOpeningFilePreviewCreatesAndSelectsWorkspaceTab() {
        let panel = CodexWorkspacePanelState()
        let id = panel.openFilePreview(fileURL: url("a.swift"))
        XCTAssertEqual(panel.workspaceTabs.snapshot.instances.count, 1)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .workspace(id))
        XCTAssertFalse(panel.workspaceTabs.snapshot.instance(id: id)?.isPinned ?? true)
    }

    func testReopeningSameFileReactivatesWithoutDuplicating() {
        let panel = CodexWorkspacePanelState()
        let first = panel.openFilePreview(fileURL: url("a.swift"))
        panel.workspaceTabs.interact(first)
        _ = panel.openFilePreview(fileURL: url("b.json"))
        let reopened = panel.openFilePreview(fileURL: url("a.swift"))

        XCTAssertEqual(first, reopened, "same file/ref returns the existing tab id")
        XCTAssertEqual(panel.workspaceTabs.snapshot.instances.count, 2)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .workspace(first))
    }

    func testSameFileDifferentRefOpensSeparateTabs() {
        let panel = CodexWorkspacePanelState()
        let working = panel.openFilePreview(fileURL: url("a.swift"))
        panel.workspaceTabs.interact(working)
        _ = panel.openFilePreview(fileURL: url("a.swift"), ref: "HEAD~1")
        XCTAssertEqual(panel.workspaceTabs.snapshot.instances.count, 2)
    }

    func testUnpinnedPreviewReplacesItsSlotAndInteractionPinsIt() throws {
        let panel = CodexWorkspacePanelState()
        let first = panel.openFilePreview(fileURL: url("a.swift"))
        let contentID = try XCTUnwrap(panel.workspaceTabs.snapshot.instance(id: first)?.contentID)

        let replacement = panel.openFilePreview(fileURL: url("b.json"))

        XCTAssertEqual(first, replacement)
        XCTAssertEqual(panel.workspaceTabs.snapshot.instance(id: replacement)?.contentID, contentID)
        XCTAssertEqual(panel.workspaceTabs.snapshot.instance(id: replacement)?.isPinned, false)

        panel.workspaceTabs.interact(replacement)
        let next = panel.openFilePreview(fileURL: url("c.py"))

        XCTAssertEqual(panel.workspaceTabs.snapshot.instance(id: replacement)?.isPinned, true)
        XCTAssertNotEqual(next, replacement)
        XCTAssertEqual(panel.workspaceTabs.restorationState.tabs.map(\.id), [replacement])
    }

    func testClosingActivePreviewFallsBackToAnotherTab() {
        let panel = CodexWorkspacePanelState()
        let a = panel.openFilePreview(fileURL: url("a.swift"))
        panel.workspaceTabs.interact(a)
        let b = panel.openFilePreview(fileURL: url("b.json"))
        panel.workspaceTabs.activate(a)

        panel.workspaceTabs.close(a)

        XCTAssertEqual(panel.workspaceTabs.snapshot.instances.count, 1)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .workspace(b))
    }

    func testPurgeClearsFileWorkspaceTabs() {
        let panel = CodexWorkspacePanelState()
        _ = panel.openFilePreview(fileURL: url("a.swift"))
        panel.purge()
        XCTAssertTrue(panel.workspaceTabs.snapshot.instances.isEmpty)
        XCTAssertNil(panel.workspaceTabs.snapshot.topology.right.activeTab)
    }
}
