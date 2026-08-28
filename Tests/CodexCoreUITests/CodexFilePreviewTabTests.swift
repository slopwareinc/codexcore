import XCTest

@testable import CodexCoreUI

@MainActor
final class CodexFilePreviewTabTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testSessionIdentityCombinesFileAndRef() {
        let working = CodexFilePreviewSession(fileURL: url("a.swift"))
        let atRef = CodexFilePreviewSession(fileURL: url("a.swift"), ref: "main")
        XCTAssertNotEqual(working.id, atRef.id, "same file at different refs must be distinct tabs")
        XCTAssertEqual(working.title, "a.swift")
        XCTAssertEqual(atRef.title, "a.swift@main")
    }

    func testOpeningFilePreviewCreatesAndSelectsTab() {
        let panel = CodexWorkspacePanelState()
        let id = panel.openFilePreview(fileURL: url("a.swift"))
        XCTAssertEqual(panel.filePreviewSessions.count, 1)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .legacy(id))
    }

    func testReopeningSameFileReactivatesWithoutDuplicating() {
        let panel = CodexWorkspacePanelState()
        let first = panel.openFilePreview(fileURL: url("a.swift"))
        panel.openFilePreview(fileURL: url("b.json"))
        let reopened = panel.openFilePreview(fileURL: url("a.swift"))

        XCTAssertEqual(first, reopened, "same file/ref returns the existing tab id")
        XCTAssertEqual(panel.filePreviewSessions.count, 2)
        XCTAssertEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .legacy(first))
    }

    func testSameFileDifferentRefOpensSeparateTabs() {
        let panel = CodexWorkspacePanelState()
        panel.openFilePreview(fileURL: url("a.swift"))
        panel.openFilePreview(fileURL: url("a.swift"), ref: "HEAD~1")
        XCTAssertEqual(panel.filePreviewSessions.count, 2)
    }

    func testClosingActivePreviewFallsBackToAnotherTab() {
        let panel = CodexWorkspacePanelState()
        let a = panel.openFilePreview(fileURL: url("a.swift"))
        panel.openFilePreview(fileURL: url("b.json"))
        panel.workspaceTabs.activateLegacy(a)

        panel.closeFilePreview(id: a)

        XCTAssertEqual(panel.filePreviewSessions.count, 1)
        XCTAssertNotNil(panel.workspaceTabs.snapshot.topology.right.activeTab)
        XCTAssertNotEqual(panel.workspaceTabs.snapshot.topology.right.activeTab, .legacy(a))
    }

    func testPurgeClearsFilePreviewSessions() {
        let panel = CodexWorkspacePanelState()
        panel.openFilePreview(fileURL: url("a.swift"))
        panel.purge()
        XCTAssertTrue(panel.filePreviewSessions.isEmpty)
        XCTAssertNil(panel.workspaceTabs.snapshot.topology.right.activeTab)
    }
}
